#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# ngate-user-scan.sh — Stage-5 Phase 1: discover per-user Nostr-binding posts
# ─────────────────────────────────────────────────────────────────────────────
#
# Sister of ngate-scan.sh. Where ngate-scan.sh hits Hive for "v4call-server"
# posts (per-server federation discovery), this script hits Hive for per-USER
# Nostr identity bindings and emits one candidate per line as compact JSON
# (NDJSON). It reads BOTH user-tier post formats:
#
#   1. LEGACY  — "nostr-announce" tagged posts (from v4call's nostr-announce.html),
#                carrying a [V4CALL-NOSTR-BINDING-V1] block. source="nostr-announce".
#   2. UNIFIED — "user-announce" tagged posts (from v4call's unified user-announce.html,
#                the current format since v4call v0.16.27), carrying a [NOSTR-V1]
#                block. source="user-announce".
#
# The two blocks differ in field names and in whether the Hive account is stated
# explicitly (see the two parse passes below). Output field names are normalised
# and mirror ngate-scan.sh (hive_account, nostr_pubkey, nostr_pubkey_hex,
# nostr_attestation_b64) so the downstream ngate-user-verify.sh + ngate-gate.sh +
# ngate-strfry-apply.sh consume both pipelines unchanged.
#
# Read-only. Does NOT verify the Nostr attestation (that's ngate-user-verify.sh,
# Stage-5 Phase 2), apply HP/token gating (ngate-gate.sh), or touch
# whitelist.json (ngate-strfry-apply.sh).
#
# USAGE:
#     ./ngate-user-scan.sh [--limit N]              # default 20, max 20 per tag
#     ./ngate-user-scan.sh --help
#
# DEPENDENCIES:
#     bash 4+, curl, jq, sed, awk
#
# OUTPUT (NDJSON, one candidate per line, fields all strings):
#     {"author": "...", "permlink": "...",
#      "hive_account": "...",
#      "nostr_pubkey": "...", "nostr_pubkey_hex": "...",
#      "nostr_attestation_b64": "...",
#      "challenge": "...", "declared": "...",
#      "source": "nostr-announce" | "user-announce"}
#
# Note: 'author' is the Hive account that authored the post; 'hive_account' is
# the binding's declared Hive account. For LEGACY posts it comes from the block's
# HIVE-ACCOUNT field; for UNIFIED posts the [NOSTR-V1] block has no such field, so
# hive_account is set to the post AUTHOR (a user announcing their own key). Either
# way they MUST match the attestation's v4call_hive_account tag for verification to
# pass downstream — this script does not enforce it (that's Phase 2's job; cleanly
# separated so this stays a pure parser).
#
# The 'source' field tags rows so a downstream apply step / cron log can tell the
# two discovery paths apart if needed. ngate-strfry-apply.sh ignores it — the
# combined whitelist remains flat.
#
# Errors and progress messages go to stderr. Stdout is clean NDJSON, safe to pipe.
#
# EXIT CODES:
#     0 = success (zero or more candidates printed)
#     1 = all Hive nodes failed for BOTH tags (no usable response)
#     2 = bad arguments
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ───── argument parsing ─────────────────────────────────────────────────────
LIMIT=20
while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit) LIMIT="${2:-}"; shift 2 ;;
    --help|-h) sed -n '2,/^# ────.*/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown arg: $1 (try --help)" >&2; exit 2 ;;
  esac
done
[[ "$LIMIT" =~ ^[0-9]+$ ]] || { echo "ngate-user-scan: --limit must be an integer" >&2; exit 2; }
(( LIMIT > 0 && LIMIT <= 20 )) || { echo "ngate-user-scan: --limit must be 1..20 (Hive node cap)" >&2; exit 2; }

# ───── dependency check ─────────────────────────────────────────────────────
for cmd in curl jq sed awk; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ngate-user-scan: missing dependency '$cmd'" >&2; exit 2; }
done

# ───── Hive RPC nodes (same fallback chain as ngate-scan.sh) ────────────────
HIVE_NODES=(
  "https://api.hive.blog"
  "https://api.deathwing.me"
  "https://hive-api.arcange.eu"
  "https://api.openhive.network"
)

log() { echo "ngate-user-scan: $*" >&2; }

# Fetch get_discussions_by_created for a Hive TAG, rotating through the node
# fallback chain. Echoes the full RPC response JSON on stdout; returns 1 if every
# node failed. Diagnostic logging mirrors v4call's hivePost helper (v0.12 fix):
# never let a 200-OK-with-no-result look like "0 posts found".
fetch_for_tag() {
  local tag="$1"
  local body resp count err
  body=$(jq -nc \
    --argjson limit "$LIMIT" \
    --arg tag "$tag" \
    '{jsonrpc:"2.0",
      method:"condenser_api.get_discussions_by_created",
      params:[{tag:$tag, limit:$limit}],
      id:1}')
  for node in "${HIVE_NODES[@]}"; do
    log "[$tag] trying $node …"
    if ! resp=$(curl -sS --max-time 15 -H 'Content-Type: application/json' -d "$body" "$node" 2>/dev/null); then
      log "  unreachable (curl error)"
      continue
    fi
    if echo "$resp" | jq -e '.result | type == "array"' >/dev/null 2>&1; then
      count=$(echo "$resp" | jq '.result | length')
      log "  ok, $count posts"
      echo "$resp"
      return 0
    fi
    err=$(echo "$resp" | jq -r '.error.message // "(no result field)"' 2>/dev/null || echo "(non-JSON)")
    log "  no result array — $err"
  done
  return 1
}

# Pull a single "KEY: value" field out of an already-extracted block.
field_of() {
  local key="$1"
  sed -n "s/^${key}:[[:space:]]*//p" \
    | head -1 \
    | sed 's/[[:space:]]*$//'
}

# Emit one normalised candidate row. Shared by both parse passes so the output
# contract is identical regardless of source.
emit_candidate() {
  jq -nc \
    --arg author                "$1" \
    --arg permlink              "$2" \
    --arg hive_account          "$3" \
    --arg nostr_pubkey          "$4" \
    --arg nostr_pubkey_hex      "$5" \
    --arg nostr_attestation_b64 "$6" \
    --arg challenge             "$7" \
    --arg declared              "$8" \
    --arg source                "$9" \
    '{author:$author, permlink:$permlink,
      hive_account:$hive_account,
      nostr_pubkey:$nostr_pubkey, nostr_pubkey_hex:$nostr_pubkey_hex,
      nostr_attestation_b64:$nostr_attestation_b64,
      challenge:$challenge, declared:$declared,
      source:$source}'
}

# ───── Pass 1: LEGACY nostr-announce posts ([V4CALL-NOSTR-BINDING-V1]) ───────
# Strip leading whitespace so markdown-code-block indented announces (4 leading
# spaces, which is what nostr-announce.html emits) parse like flat-text ones.
extract_legacy_block() {
  awk '/\[V4CALL-NOSTR-BINDING-V1\]/,/\[\/V4CALL-NOSTR-BINDING-V1\]/' \
    | sed 's/^[[:space:]]*//' \
    | tr -d '\r'
}
process_legacy() {
  local posts_json="$1"
  echo "$posts_json" | jq -c '.result[] | {author, permlink, body}' | while IFS= read -r post; do
    local author permlink body block
    author=$(echo "$post"   | jq -r '.author')
    permlink=$(echo "$post" | jq -r '.permlink')
    body=$(echo "$post"     | jq -r '.body')

    block=$(echo "$body" | extract_legacy_block)
    if [[ -z "$block" ]]; then
      log "skip @$author/$permlink — no V4CALL-NOSTR-BINDING-V1 block found"
      continue
    fi

    local hive_account nostr_pubkey nostr_pubkey_hex nostr_attestation_b64 challenge declared
    hive_account=$(echo "$block"          | field_of HIVE-ACCOUNT)
    nostr_pubkey=$(echo "$block"          | field_of NOSTR-PUBKEY)
    nostr_pubkey_hex=$(echo "$block"      | field_of NOSTR-PUBKEY-HEX)
    nostr_attestation_b64=$(echo "$block" | field_of NOSTR-ATTESTATION)
    challenge=$(echo "$block"             | field_of CHALLENGE)
    declared=$(echo "$block"              | field_of DECLARED)

    if [[ -z "$hive_account" || -z "$nostr_pubkey_hex" || -z "$nostr_attestation_b64" ]]; then
      log "skip @$author/$permlink — missing required field (HIVE-ACCOUNT, NOSTR-PUBKEY-HEX, NOSTR-ATTESTATION)"
      continue
    fi

    emit_candidate "$author" "$permlink" "$hive_account" "$nostr_pubkey" \
      "$nostr_pubkey_hex" "$nostr_attestation_b64" "$challenge" "$declared" "nostr-announce"
  done
}

# ───── Pass 2: UNIFIED user-announce posts ([NOSTR-V1]) ─────────────────────
# v4call v0.16.27+ replaced the standalone nostr-announce post with one unified
# "user-announce" post carrying versioned per-app blocks. The Nostr binding lives
# in a [NOSTR-V1] block whose fields are UNPREFIXED (NPUB / HEX / RELAYS /
# ATTESTATION) and which carries NO explicit Hive account — the post AUTHOR is the
# account (a user announcing their own key). Everything downstream is identical.
extract_nostr_v1_block() {
  awk '/\[NOSTR-V1\]/,/\[\/NOSTR-V1\]/' \
    | sed 's/^[[:space:]]*//' \
    | tr -d '\r'
}
process_userann() {
  local posts_json="$1"
  echo "$posts_json" | jq -c '.result[] | {author, permlink, body}' | while IFS= read -r post; do
    local author permlink body block
    author=$(echo "$post"   | jq -r '.author')
    permlink=$(echo "$post" | jq -r '.permlink')
    body=$(echo "$post"     | jq -r '.body')

    block=$(echo "$body" | extract_nostr_v1_block)
    if [[ -z "$block" ]]; then
      log "skip @$author/$permlink — no [NOSTR-V1] block (user-announce without a Nostr binding)"
      continue
    fi

    local nostr_pubkey nostr_pubkey_hex nostr_attestation_b64 hive_account
    nostr_pubkey=$(echo "$block"          | field_of NPUB)
    nostr_pubkey_hex=$(echo "$block"      | field_of HEX)
    nostr_attestation_b64=$(echo "$block" | field_of ATTESTATION)
    hive_account="$author"   # [NOSTR-V1] omits HIVE-ACCOUNT; author IS the account

    if [[ -z "$nostr_pubkey_hex" || -z "$nostr_attestation_b64" ]]; then
      log "skip @$author/$permlink — [NOSTR-V1] missing HEX or ATTESTATION (no Nostr binding / not signed yet)"
      continue
    fi

    # challenge/declared aren't part of the [NOSTR-V1] block — emit empty.
    emit_candidate "$author" "$permlink" "$hive_account" "$nostr_pubkey" \
      "$nostr_pubkey_hex" "$nostr_attestation_b64" "" "" "user-announce"
  done
}

# ───── run both passes ──────────────────────────────────────────────────────
got_any=0
if legacy_posts=$(fetch_for_tag "nostr-announce"); then
  process_legacy "$legacy_posts"
  got_any=1
else
  log "[nostr-announce] all nodes failed — skipping legacy pass"
fi

if userann_posts=$(fetch_for_tag "user-announce"); then
  process_userann "$userann_posts"
  got_any=1
else
  log "[user-announce] all nodes failed — skipping unified pass"
fi

[[ "$got_any" -eq 1 ]] || { log "ALL nodes failed for BOTH tags; aborting"; exit 1; }

log "scan complete"
