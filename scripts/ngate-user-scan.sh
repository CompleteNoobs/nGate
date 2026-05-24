#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# ngate-user-scan.sh — Stage-5 Phase 1: discover nostr-announce user posts
# ─────────────────────────────────────────────────────────────────────────────
#
# Sister of ngate-scan.sh. Where ngate-scan.sh hits Hive for "v4call-server"
# posts (per-server federation discovery), this script hits Hive for
# "nostr-announce" posts (per-user Nostr identity bindings produced by
# v4call's nostr-announce.html tool).
#
# Parses each post's V4CALL-NOSTR-BINDING-V1 block and prints one candidate
# per line as compact JSON (NDJSON). Output field names mirror ngate-scan.sh
# (hive_account, nostr_pubkey, nostr_pubkey_hex, nostr_attestation_b64) so
# the downstream ngate-gate.sh + ngate-strfry-apply.sh can consume both
# pipelines unchanged.
#
# Read-only. Does NOT verify the Nostr attestation (that's ngate-user-verify.sh,
# Stage-5 Phase 2), apply HP/token gating (ngate-gate.sh), or touch
# whitelist.json (ngate-strfry-apply.sh).
#
# USAGE:
#     ./ngate-user-scan.sh [--limit N]              # default 20
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
#      "source": "nostr-announce"}
#
# Note: 'author' is the Hive account that authored the post; 'hive_account'
# is the value of the post body's HIVE-ACCOUNT field. They MUST match for
# verification to pass downstream — this script does not enforce it (that's
# Phase 2's job; cleanly separated so this stays a pure parser).
#
# The 'source' field tags rows so a downstream apply step / cron log can
# tell user-discovered keys apart from server-discovered ones if needed.
# The existing ngate-strfry-apply.sh ignores the field — combined whitelist
# remains flat.
#
# Errors and progress messages go to stderr. Stdout is clean NDJSON, safe
# to pipe.
#
# EXIT CODES:
#     0 = success (zero or more candidates printed)
#     1 = all Hive nodes failed (no usable response)
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

fetch_posts_from() {
  local node="$1"
  local body
  body=$(jq -nc \
    --argjson limit "$LIMIT" \
    '{jsonrpc:"2.0",
      method:"condenser_api.get_discussions_by_created",
      params:[{tag:"nostr-announce", limit:$limit}],
      id:1}')
  curl -sS --max-time 15 \
    -H 'Content-Type: application/json' \
    -d "$body" "$node"
}

posts_json=""
for node in "${HIVE_NODES[@]}"; do
  log "trying $node …"
  if ! resp=$(fetch_posts_from "$node" 2>/dev/null); then
    log "  unreachable (curl error)"
    continue
  fi
  # Diagnostic logging — same lesson as v4call's hivePost helper (v0.12 fix):
  # don't let a 200-OK with no result silently look like "0 posts found".
  if echo "$resp" | jq -e '.result | type == "array"' >/dev/null 2>&1; then
    count=$(echo "$resp" | jq '.result | length')
    log "  ok, $count posts"
    posts_json="$resp"
    break
  fi
  err=$(echo "$resp" | jq -r '.error.message // "(no result field)"' 2>/dev/null || echo "(non-JSON)")
  log "  no result array — $err"
done

[[ -z "$posts_json" ]] && { log "ALL nodes failed; aborting"; exit 1; }

# ───── per-candidate parsing ────────────────────────────────────────────────
# Strip leading whitespace so markdown-code-block indented announces (4
# leading spaces, which is what nostr-announce.html actually emits) parse
# the same as flat-text announces.
extract_block() {
  awk '/\[V4CALL-NOSTR-BINDING-V1\]/,/\[\/V4CALL-NOSTR-BINDING-V1\]/' \
    | sed 's/^[[:space:]]*//' \
    | tr -d '\r'
}

field_of() {
  local key="$1"
  sed -n "s/^${key}:[[:space:]]*//p" \
    | head -1 \
    | sed 's/[[:space:]]*$//'
}

echo "$posts_json" | jq -c '.result[] | {author, permlink, body}' | while IFS= read -r post; do
  author=$(echo "$post"   | jq -r '.author')
  permlink=$(echo "$post" | jq -r '.permlink')
  body=$(echo "$post"     | jq -r '.body')

  block=$(echo "$body" | extract_block)
  if [[ -z "$block" ]]; then
    log "skip @$author/$permlink — no V4CALL-NOSTR-BINDING-V1 block found"
    continue
  fi

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

  jq -nc \
    --arg author                "$author" \
    --arg permlink              "$permlink" \
    --arg hive_account          "$hive_account" \
    --arg nostr_pubkey          "$nostr_pubkey" \
    --arg nostr_pubkey_hex      "$nostr_pubkey_hex" \
    --arg nostr_attestation_b64 "$nostr_attestation_b64" \
    --arg challenge             "$challenge" \
    --arg declared              "$declared" \
    '{author:$author, permlink:$permlink,
      hive_account:$hive_account,
      nostr_pubkey:$nostr_pubkey, nostr_pubkey_hex:$nostr_pubkey_hex,
      nostr_attestation_b64:$nostr_attestation_b64,
      challenge:$challenge, declared:$declared,
      source:"nostr-announce"}'
done

log "scan complete"