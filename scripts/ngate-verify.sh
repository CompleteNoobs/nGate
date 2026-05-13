#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# ngate-verify.sh — Phase 3.2 of nGate: verify discovered candidates
# ─────────────────────────────────────────────────────────────────────────────
#
# Reads NDJSON candidates from stdin (output of ngate-scan.sh) and emits only
# verified candidates to stdout (NDJSON), with extra "verified": true and
# "posting_pubkey" / "verified_at" metadata.
#
# A candidate passes verification IFF ALL of the following hold:
#   1. It declares a non-empty nostr_pubkey_hex (skip silently otherwise — the
#      candidate predates the Nostr fields; not an error, just not eligible).
#   2. Its verify_url is reachable and returns valid v4call-server.json.
#   3. The well-known's signature is valid against the Hive account's posting
#      pubkey (fetched from Hive RPC, multi-node fallback).
#   4. If the well-known includes a nostr_hex, it matches the post's claim
#      (defense in depth; mismatch is treated as a forgery indicator and
#      both sides are rejected).
#   5. No within-scan collision: no other candidate in this stream claims the
#      same nostr_pubkey_hex (collision = forgery indicator → reject all).
#
# This phase is read-only. It does NOT touch config.toml, run gating, or
# write any state. Pipe its output into ngate-gate.sh (phase 3.3) when ready.
#
# USAGE:
#     ./ngate-scan.sh | ./ngate-verify.sh
#     ./ngate-verify.sh < candidates.ndjson
#     ./ngate-verify.sh --help
#
# DEPENDENCIES:
#     bash 4+, curl, jq, sed, awk, node (with @hiveio/dhive — `npm install`
#     in this folder)
#
# EXIT CODES:
#     0 = success (zero or more verified candidates printed)
#     1 = no Hive node reachable for pubkey lookup (hard failure)
#     2 = bad arguments / missing dependencies
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ───── arg parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) sed -n '2,/^# ────.*/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown arg: $1 (try --help)" >&2; exit 2 ;;
  esac
done

# ───── dependency check ─────────────────────────────────────────────────────
for cmd in curl jq sed awk node; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ngate-verify: missing dependency '$cmd'" >&2; exit 2; }
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIG_HELPER="$SCRIPT_DIR/lib/ngate-verify-sig.js"
NOSTR_HELPER="$SCRIPT_DIR/lib/ngate-verify-nostr-event.mjs"
[[ -f "$SIG_HELPER" ]]   || { echo "ngate-verify: helper not found at $SIG_HELPER" >&2; exit 2; }
[[ -f "$NOSTR_HELPER" ]] || { echo "ngate-verify: helper not found at $NOSTR_HELPER" >&2; exit 2; }

# Make sure the npm deps are installed
if [[ ! -d "$SCRIPT_DIR/node_modules/@hiveio/dhive" ]]; then
  echo "ngate-verify: @hiveio/dhive not installed. Run: cd $SCRIPT_DIR && npm install" >&2
  exit 2
fi
if [[ ! -d "$SCRIPT_DIR/node_modules/nostr-tools" ]]; then
  echo "ngate-verify: nostr-tools not installed. Run: cd $SCRIPT_DIR && npm install" >&2
  exit 2
fi

ATTESTATION_D_TAG="v4call-server-cross-attestation"

# ───── Hive RPC nodes (same fallback chain as ngate-scan) ───────────────────
HIVE_NODES=(
  "https://api.hive.blog"
  "https://api.deathwing.me"
  "https://hive-api.arcange.eu"
  "https://api.openhive.network"
)

log() { echo "ngate-verify: $*" >&2; }

# ───── fetch posting pubkey for a Hive account (multi-node fallback) ────────
fetch_posting_pubkey() {
  local account="$1"
  local body resp pk
  body=$(jq -nc --arg acc "$account" \
    '{jsonrpc:"2.0", method:"condenser_api.get_accounts", params:[[$acc]], id:1}')
  for node in "${HIVE_NODES[@]}"; do
    if resp=$(curl -sS --max-time 10 -H 'Content-Type: application/json' -d "$body" "$node" 2>/dev/null); then
      pk=$(echo "$resp" | jq -r '.result[0].posting.key_auths[0][0] // empty' 2>/dev/null || true)
      if [[ -n "$pk" && "$pk" != "null" ]]; then
        echo "$pk"
        return 0
      fi
    fi
  done
  return 1
}

# ───── reconstruct canonical payload (matches server-sign.html buildPayload) ─
# Order: claim|domain|hive_account|escrow|fee_account|federation_ws
#        |issued|expires|nonce
# Optional Nostr trailer (only if any of nostr_npub/nostr_hex/nostr_relays present):
#        |nostr_npub|nostr_hex|nostr_relays_csv
reconstruct_payload() {
  jq -r '
    ([.claim, .domain, .hive_account, .escrow, .fee_account, .federation_ws,
      .issued, (.expires // ""), .nonce]
     +
     (if   ((.nostr_npub // "") != "")
        or ((.nostr_hex  // "") != "")
        or (((.nostr_relays // []) | map(select(. != "")) | length) > 0)
      then [(.nostr_npub // ""),
            (.nostr_hex  // ""),
            ((.nostr_relays // []) | map(select(. != "")) | join(","))]
      else []
      end)
    ) | join("|")
  '
}

# ───── per-candidate state (in-memory, this scan only) ──────────────────────
declare -A pubkey_cache       # hive_account → posting pubkey (cached lookups)
declare -A claimed_hex        # nostr_hex → first hive_account that claimed it
declare -A collision_hex      # nostr_hex → 1 if collision detected this scan

# ───── stream-process each candidate from stdin ─────────────────────────────
# Note: previous versions did a two-pass collision-detection (same Nostr hex
# claimed by two different Hive accounts → reject both). That's now obsolete:
# cryptographic attestation makes forgery infeasible (the forger would need
# the legit operator's Nostr private key to produce a valid attestation), and
# the tag cross-check (v4call_hive_account + v4call_domain) detects any
# attempt to reuse a legit operator's attestation under a different Hive
# account. Collision is logged as a warning but doesn't reject — both
# candidates go through the full validation chain; cryptography decides.
declare -A seen_hex
while IFS= read -r line; do
  [[ -z "$line" ]] && continue

  domain=$(echo "$line"                | jq -r '.domain')
  hive_account=$(echo "$line"          | jq -r '.hive_account')
  verify_url=$(echo "$line"            | jq -r '.verify_url')
  nostr_pubkey_hex=$(echo "$line"      | jq -r '.nostr_pubkey_hex // ""')
  nostr_attestation_b64=$(echo "$line" | jq -r '.nostr_attestation_b64 // ""')
  permlink=$(echo "$line"              | jq -r '.permlink // ""')

  ident="@$hive_account/$domain"

  # 1. Skip silently if no Nostr key claim (pre-Nostr announces; not an error)
  if [[ -z "$nostr_pubkey_hex" ]]; then
    log "skip $ident — no nostr_pubkey_hex (pre-Nostr announce; not an error)"
    continue
  fi

  # 2. Within-scan hex collision — warn but don't reject. Attestation will sort it out.
  if [[ -n "${seen_hex[$nostr_pubkey_hex]:-}" && "${seen_hex[$nostr_pubkey_hex]}" != "$hive_account" ]]; then
    log "WARN $ident — Nostr hex ${nostr_pubkey_hex:0:16}… also claimed by @${seen_hex[$nostr_pubkey_hex]} this scan; attestation cross-check decides"
  fi
  seen_hex[$nostr_pubkey_hex]="$hive_account"

  # 3. Fetch the well-known
  if ! wk=$(curl -sS --max-time 10 -L "$verify_url" 2>/dev/null); then
    log "REJECT $ident — could not fetch $verify_url"
    continue
  fi
  if ! echo "$wk" | jq -e '.claim and .signature and .hive_account and .nonce' >/dev/null 2>&1; then
    log "REJECT $ident — well-known missing required fields (claim/signature/hive_account/nonce)"
    continue
  fi

  # 4. Sanity: well-known's claim string + hive_account match
  wk_claim=$(echo "$wk" | jq -r '.claim')
  wk_acct=$(echo "$wk"  | jq -r '.hive_account')
  if [[ "$wk_claim" != "v4call-server-ownership" ]]; then
    log "REJECT $ident — wrong claim string ('$wk_claim')"
    continue
  fi
  if [[ "$wk_acct" != "$hive_account" ]]; then
    log "REJECT $ident — well-known hive_account ($wk_acct) ≠ post's HIVE-ACCOUNT ($hive_account)"
    continue
  fi

  # 5. Defense in depth: well-known's nostr_hex must match post's
  wk_nostr_hex=$(echo "$wk" | jq -r '.nostr_hex // ""')
  if [[ -n "$wk_nostr_hex" && "$wk_nostr_hex" != "$nostr_pubkey_hex" ]]; then
    log "REJECT $ident — well-known nostr_hex differs from post (post=$nostr_pubkey_hex, wk=$wk_nostr_hex)"
    continue
  fi

  # 6. Optional expiry
  wk_expires=$(echo "$wk" | jq -r '.expires // ""')
  if [[ -n "$wk_expires" ]]; then
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if [[ "$now" > "$wk_expires" ]]; then
      log "REJECT $ident — well-known expired at $wk_expires"
      continue
    fi
  fi

  # 7. Reconstruct canonical payload + look up posting pubkey
  payload=$(echo "$wk" | reconstruct_payload)
  if [[ -z "${pubkey_cache[$hive_account]:-}" ]]; then
    if pk=$(fetch_posting_pubkey "$hive_account"); then
      pubkey_cache[$hive_account]="$pk"
    else
      log "REJECT $ident — could not fetch posting pubkey from any Hive node"
      continue
    fi
  fi
  pubkey="${pubkey_cache[$hive_account]}"

  # 8. Verify Hive signature
  signature=$(echo "$wk" | jq -r '.signature')
  verify_input=$(jq -nc \
    --arg payload   "$payload" \
    --arg signature "$signature" \
    --arg pubkey    "$pubkey" \
    '{payload:$payload, signature:$signature, pubkey:$pubkey}')
  if ! result=$(echo "$verify_input" | node "$SIG_HELPER" 2>/dev/null); then
    log "REJECT $ident — Hive signature helper crashed"
    continue
  fi
  if [[ "$result" != "true" ]]; then
    log "REJECT $ident — Hive signature DID NOT verify against posting pubkey"
    continue
  fi

  # ───── 9. Nostr attestation enforcement (REQUIRED when Nostr key declared) ──
  # Get attestation from well-known (cryptographically bound to Hive sig via
  # canonical payload) AND from post body base64 (must agree if both present).
  wk_attest=$(echo "$wk" | jq -c '.nostr_attestation // empty')
  post_attest=""
  if [[ -n "$nostr_attestation_b64" ]]; then
    post_attest=$(echo "$nostr_attestation_b64" | base64 -d 2>/dev/null | jq -c . 2>/dev/null || echo "")
  fi

  if [[ -z "$wk_attest" && -z "$post_attest" ]]; then
    log "REJECT $ident — no nostr_attestation in well-known OR post (required when nostr_pubkey_hex declared)"
    continue
  fi

  # If both surfaces have one, they must agree byte-for-byte
  if [[ -n "$wk_attest" && -n "$post_attest" ]]; then
    if [[ "$wk_attest" != "$post_attest" ]]; then
      log "REJECT $ident — well-known nostr_attestation differs from post's base64 (forgery indicator)"
      continue
    fi
  fi
  attest="${wk_attest:-$post_attest}"

  # 9a. Attestation pubkey matches the declared nostr_hex
  ev_pubkey=$(echo "$attest" | jq -r '.pubkey // ""')
  if [[ "${ev_pubkey,,}" != "${nostr_pubkey_hex,,}" ]]; then
    log "REJECT $ident — attestation pubkey (${ev_pubkey:0:16}…) ≠ declared nostr_pubkey_hex (${nostr_pubkey_hex:0:16}…)"
    continue
  fi

  # 9b. Cross-check tags against the surrounding post/well-known
  d_tag=$(echo "$attest"      | jq -r '[.tags[] | select(.[0]=="d") | .[1]] | first // ""')
  hive_tag=$(echo "$attest"   | jq -r '[.tags[] | select(.[0]=="v4call_hive_account") | .[1]] | first // ""')
  domain_tag=$(echo "$attest" | jq -r '[.tags[] | select(.[0]=="v4call_domain") | .[1]] | first // ""')

  if [[ "$d_tag" != "$ATTESTATION_D_TAG" ]]; then
    log "REJECT $ident — attestation d-tag is '$d_tag', expected '$ATTESTATION_D_TAG'"
    continue
  fi
  if [[ "$hive_tag" != "$hive_account" ]]; then
    log "REJECT $ident — attestation v4call_hive_account tag ($hive_tag) ≠ post's HIVE-ACCOUNT ($hive_account)"
    continue
  fi
  if [[ "$domain_tag" != "$domain" ]]; then
    log "REJECT $ident — attestation v4call_domain tag ($domain_tag) ≠ post's DOMAIN ($domain)"
    continue
  fi

  # 9c. Cryptographic verification of the kind-30078 event
  if ! nostr_result=$(echo "$attest" | node "$NOSTR_HELPER" 2>/dev/null); then
    log "REJECT $ident — Nostr verify helper crashed"
    continue
  fi
  if [[ "$nostr_result" != "true" ]]; then
    log "REJECT $ident — Nostr attestation event DID NOT verify (id mismatch or bad sig)"
    continue
  fi

  # ───── 10. All checks passed — emit verified candidate with metadata ───────
  echo "$line" | jq -c \
    --arg verified_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg pubkey "$pubkey" \
    --argjson attestation "$attest" \
    '. + {verified: true, attested: true, verified_at: $verified_at,
          posting_pubkey: $pubkey, nostr_attestation: $attestation}'
  log "OK $ident — Hive sig + Nostr attestation valid (triple-bound), hex ${nostr_pubkey_hex:0:16}…"
done

log "verify complete"
