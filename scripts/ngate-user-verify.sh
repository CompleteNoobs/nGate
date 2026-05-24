#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# ngate-user-verify.sh — Stage-5 Phase 2: verify nostr-announce bindings
# ─────────────────────────────────────────────────────────────────────────────
#
# Sister of ngate-verify.sh. Where ngate-verify.sh checks the three-way
# Hive-post + well-known + Nostr-attestation bind for v4call SERVERS,
# this script checks the two-way Hive-post + Nostr-attestation bind for
# individual USERS who published nostr-announce posts.
#
# A candidate passes verification IFF ALL of the following hold:
#   1. nostr_pubkey_hex and nostr_attestation_b64 are present.
#   2. The base64 attestation decodes to a JSON Nostr event.
#   3. event.pubkey == nostr_pubkey_hex (case-insensitive).
#   4. event.kind == 30078 (parameterized replaceable, our chosen kind).
#   5. event.tags['d'] == "v4call-nostr-binding".
#   6. event.tags['v4call_hive_account'] == post AUTHOR (case-insensitive).
#      This is the key bind: the post author had Hive posting authority
#      AND the matching nsec signed the attestation tagging that exact
#      Hive account. Either alone is forgeable; the pair is not.
#   7. event.tags['v4call_hive_account'] also matches the HIVE-ACCOUNT field
#      in the post body (catches copy-paste-someone-else's-binding mistakes
#      AND prevents an attacker posting their own attestation under
#      somebody else's Hive account with a body that names the victim).
#   8. The kind-30078 event verifies cryptographically (id + schnorr sig),
#      via the same lib/ngate-verify-nostr-event.mjs helper as ngate-verify.sh.
#
# This phase is read-only. It does NOT touch whitelist.json, run gating, or
# write any state. Pipe its output into ngate-gate.sh (Phase 3.3) — same
# downstream as the v4call-server pipeline.
#
# USAGE:
#     ./ngate-user-scan.sh | ./ngate-user-verify.sh
#     ./ngate-user-verify.sh < candidates.ndjson
#     ./ngate-user-verify.sh --help
#
# DEPENDENCIES:
#     bash 4+, jq, sed, node (with nostr-tools — `npm install` in this folder)
#
# EXIT CODES:
#     0 = success (zero or more verified candidates printed)
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
for cmd in jq sed node; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ngate-user-verify: missing dependency '$cmd'" >&2; exit 2; }
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOSTR_HELPER="$SCRIPT_DIR/lib/ngate-verify-nostr-event.mjs"
[[ -f "$NOSTR_HELPER" ]] || { echo "ngate-user-verify: helper not found at $NOSTR_HELPER" >&2; exit 2; }
if [[ ! -d "$SCRIPT_DIR/node_modules/nostr-tools" ]]; then
  echo "ngate-user-verify: nostr-tools not installed. Run: cd $SCRIPT_DIR && npm install" >&2
  exit 2
fi

# Must match the d-tag emitted by public/nostr-announce.html (ATTESTATION_D_TAG).
ATTESTATION_D_TAG="v4call-nostr-binding"
ATTESTATION_KIND=30078

log() { echo "ngate-user-verify: $*" >&2; }

# ───── per-candidate state ──────────────────────────────────────────────────
# Within-scan duplicate Nostr-hex detection — warn but don't auto-reject;
# the cryptographic attestation cross-check below is what actually decides.
# Same posture as ngate-verify.sh (a forger would need the legit user's nsec
# to produce a valid attestation under their account, so collisions are
# noise, not exploits).
declare -A seen_hex

while IFS= read -r line; do
  [[ -z "$line" ]] && continue

  author=$(echo "$line"                | jq -r '.author // ""')
  permlink=$(echo "$line"              | jq -r '.permlink // ""')
  hive_account=$(echo "$line"          | jq -r '.hive_account // ""')
  nostr_pubkey=$(echo "$line"          | jq -r '.nostr_pubkey // ""')
  nostr_pubkey_hex=$(echo "$line"      | jq -r '.nostr_pubkey_hex // ""')
  nostr_attestation_b64=$(echo "$line" | jq -r '.nostr_attestation_b64 // ""')

  ident="@$author/$permlink"

  # 1. Required fields
  if [[ -z "$nostr_pubkey_hex" || -z "$nostr_attestation_b64" ]]; then
    log "skip $ident — missing nostr_pubkey_hex or nostr_attestation_b64"
    continue
  fi
  if [[ -z "$hive_account" ]]; then
    log "REJECT $ident — no HIVE-ACCOUNT in post body"
    continue
  fi

  # Case-normalise the hex for downstream comparisons (Nostr convention is
  # lowercase; defensive in case a stray uppercase slipped through).
  hex_lc="${nostr_pubkey_hex,,}"

  # 2. Within-scan duplicate hex — warn only, attestation decides.
  if [[ -n "${seen_hex[$hex_lc]:-}" && "${seen_hex[$hex_lc]}" != "$author" ]]; then
    log "WARN $ident — nostr hex ${hex_lc:0:16}… also claimed by @${seen_hex[$hex_lc]} this scan; attestation cross-check decides"
  fi
  seen_hex[$hex_lc]="$author"

  # 3. Decode base64 → JSON
  attest=$(echo "$nostr_attestation_b64" | base64 -d 2>/dev/null | jq -c . 2>/dev/null || echo "")
  if [[ -z "$attest" ]]; then
    log "REJECT $ident — nostr_attestation_b64 is not valid base64 or not valid JSON after decode"
    continue
  fi

  # 4. Kind check
  ev_kind=$(echo "$attest" | jq -r '.kind // empty')
  if [[ "$ev_kind" != "$ATTESTATION_KIND" ]]; then
    log "REJECT $ident — attestation kind is '$ev_kind', expected $ATTESTATION_KIND"
    continue
  fi

  # 5. Pubkey on the event must match the declared nostr_pubkey_hex
  ev_pubkey=$(echo "$attest" | jq -r '.pubkey // ""')
  if [[ "${ev_pubkey,,}" != "$hex_lc" ]]; then
    log "REJECT $ident — attestation pubkey (${ev_pubkey:0:16}…) ≠ declared nostr_pubkey_hex (${hex_lc:0:16}…)"
    continue
  fi

  # 6. Tag cross-checks: d, v4call_hive_account
  d_tag=$(echo "$attest"    | jq -r '[.tags[]? | select(.[0]=="d") | .[1]] | first // ""')
  hive_tag=$(echo "$attest" | jq -r '[.tags[]? | select(.[0]=="v4call_hive_account") | .[1]] | first // ""')

  if [[ "$d_tag" != "$ATTESTATION_D_TAG" ]]; then
    log "REJECT $ident — attestation d-tag is '$d_tag', expected '$ATTESTATION_D_TAG'"
    continue
  fi
  # 6a. Tag must match the POST AUTHOR — this is the trust root (only the
  #     Hive account that controls the posting key for @author could have
  #     produced this Hive post in the first place; combining that with a
  #     Nostr-signed attestation naming @author binds the two identities).
  if [[ "${hive_tag,,}" != "${author,,}" ]]; then
    log "REJECT $ident — attestation v4call_hive_account tag ($hive_tag) ≠ post author ($author)"
    continue
  fi
  # 6b. Tag must ALSO match the HIVE-ACCOUNT field in the post body — catches
  #     mistakes (or attempts) to publish under one Hive account a binding
  #     whose body claims a different account.
  if [[ "${hive_tag,,}" != "${hive_account,,}" ]]; then
    log "REJECT $ident — attestation v4call_hive_account tag ($hive_tag) ≠ body HIVE-ACCOUNT field ($hive_account)"
    continue
  fi

  # 7. Cryptographic verification of the kind-30078 event (id + schnorr sig).
  if ! nostr_result=$(echo "$attest" | node "$NOSTR_HELPER" 2>/dev/null); then
    log "REJECT $ident — Nostr verify helper crashed"
    continue
  fi
  if [[ "$nostr_result" != "true" ]]; then
    log "REJECT $ident — Nostr attestation event DID NOT verify (id mismatch or bad sig)"
    continue
  fi

  # 8. All checks passed — emit the row with verification metadata appended.
  # Keep .hive_account / .nostr_pubkey_hex as the downstream gate + apply
  # already expect; add .verified / .attested / .verified_at for ledger.
  echo "$line" | jq -c \
    --arg verified_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson attestation "$attest" \
    '. + {verified: true, attested: true, verified_at: $verified_at,
          nostr_attestation: $attestation}'
  log "OK $ident — Hive author + Nostr attestation bound, hex ${hex_lc:0:16}…"
done

log "verify complete"