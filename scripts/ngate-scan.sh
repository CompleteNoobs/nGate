#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# ngate-scan.sh — Phase 3.1 of nGate: discover v4call-server posts on Hive
# ─────────────────────────────────────────────────────────────────────────────
#
# Hits Hive RPC nodes for the latest posts tagged "v4call-server", parses each
# post's V4CALL-SERVER-V1 block, and prints one candidate per line as compact
# JSON (NDJSON — easy to pipe to jq or to the next phase).
#
# This phase is read-only. It does NOT verify well-known signatures (3.2),
# check Hive balances (3.3), or touch the relay's config.toml (3.4).
#
# USAGE:
#     ./ngate-scan.sh [--limit N]              # default 20
#     ./ngate-scan.sh --help
#
# DEPENDENCIES:
#     bash 4+, curl, jq, sed, awk
#
# OUTPUT (NDJSON, one candidate per line, fields all strings):
#     {"author": "...", "permlink": "...", "domain": "...",
#      "hive_account": "...", "escrow": "...", "fee_account": "...",
#      "federation_ws": "...", "verify_url": "...", "software": "...",
#      "protocol": "...", "nostr_pubkey": "...", "nostr_pubkey_hex": "...",
#      "declared": "..."}
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
[[ "$LIMIT" =~ ^[0-9]+$ ]] || { echo "ngate-scan: --limit must be an integer" >&2; exit 2; }
(( LIMIT > 0 && LIMIT <= 20 )) || { echo "ngate-scan: --limit must be 1..20 (Hive node cap)" >&2; exit 2; }

# ───── dependency check ─────────────────────────────────────────────────────
for cmd in curl jq sed awk; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ngate-scan: missing dependency '$cmd'" >&2; exit 2; }
done

# ───── Hive RPC nodes (multi-node fallback, copied from v4call's pattern) ──
HIVE_NODES=(
  "https://api.hive.blog"
  "https://api.deathwing.me"
  "https://hive-api.arcange.eu"
  "https://api.openhive.network"
)

log() { echo "ngate-scan: $*" >&2; }

# ───── fetch posts from one Hive node ───────────────────────────────────────
fetch_posts_from() {
  local node="$1"
  local body
  body=$(jq -nc \
    --argjson limit "$LIMIT" \
    '{jsonrpc:"2.0",
      method:"condenser_api.get_discussions_by_created",
      params:[{tag:"v4call-server", limit:$limit}],
      id:1}')
  curl -sS --max-time 15 \
    -H 'Content-Type: application/json' \
    -d "$body" "$node"
}

# ───── try each Hive node until one returns a valid result array ────────────
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
# Strip leading whitespace from each line of the V4CALL-SERVER-V1 block so
# markdown-code-block indented announces (4 leading spaces) parse the same
# as flat-text announces.
extract_block() {
  awk '/\[V4CALL-SERVER-V1\]/,/\[\/V4CALL-SERVER-V1\]/' \
    | sed 's/^[[:space:]]*//' \
    | tr -d '\r'
}

# Pull a single field out of an already-extracted block.
# field "DOMAIN" → "call.completenoobs.com"
field_of() {
  local key="$1"
  sed -n "s/^${key}:[[:space:]]*//p" \
    | head -1 \
    | sed 's/[[:space:]]*$//'
}

emit_count=0
echo "$posts_json" | jq -c '.result[] | {author, permlink, body}' | while IFS= read -r post; do
  author=$(echo "$post"   | jq -r '.author')
  permlink=$(echo "$post" | jq -r '.permlink')
  body=$(echo "$post"     | jq -r '.body')

  block=$(echo "$body" | extract_block)
  if [[ -z "$block" ]]; then
    log "skip @$author/$permlink — no V4CALL-SERVER-V1 block found"
    continue
  fi

  # Read each known field
  domain=$(echo "$block"           | field_of DOMAIN)
  hive_account=$(echo "$block"     | field_of HIVE-ACCOUNT)
  escrow=$(echo "$block"           | field_of ESCROW)
  fee_account=$(echo "$block"      | field_of FEE-ACCOUNT)
  fed_ws=$(echo "$block"           | field_of FEDERATION-WS)
  verify_url=$(echo "$block"       | field_of VERIFY-URL)
  software=$(echo "$block"         | field_of SOFTWARE)
  protocol=$(echo "$block"         | field_of PROTOCOL)
  nostr_pubkey=$(echo "$block"        | field_of NOSTR-PUBKEY)
  nostr_pubkey_hex=$(echo "$block"    | field_of NOSTR-PUBKEY-HEX)
  nostr_attestation_b64=$(echo "$block" | field_of NOSTR-ATTESTATION)
  declared=$(echo "$block"            | field_of DECLARED)

  if [[ -z "$domain" || -z "$hive_account" ]]; then
    log "skip @$author/$permlink — missing DOMAIN or HIVE-ACCOUNT"
    continue
  fi

  jq -nc \
    --arg author                "$author" \
    --arg permlink              "$permlink" \
    --arg domain                "$domain" \
    --arg hive_account          "$hive_account" \
    --arg escrow                "$escrow" \
    --arg fee_account           "$fee_account" \
    --arg federation_ws         "$fed_ws" \
    --arg verify_url            "$verify_url" \
    --arg software              "$software" \
    --arg protocol              "$protocol" \
    --arg nostr_pubkey          "$nostr_pubkey" \
    --arg nostr_pubkey_hex      "$nostr_pubkey_hex" \
    --arg nostr_attestation_b64 "$nostr_attestation_b64" \
    --arg declared              "$declared" \
    '{author:$author, permlink:$permlink,
      domain:$domain, hive_account:$hive_account,
      escrow:$escrow, fee_account:$fee_account,
      federation_ws:$federation_ws, verify_url:$verify_url,
      software:$software, protocol:$protocol,
      nostr_pubkey:$nostr_pubkey, nostr_pubkey_hex:$nostr_pubkey_hex,
      nostr_attestation_b64:$nostr_attestation_b64,
      declared:$declared}'
  emit_count=$((emit_count + 1))
done

# Note: emit_count won't survive the subshell (`while` in a pipe), so we don't
# print a final summary here. The per-line output IS the summary.
log "scan complete"
