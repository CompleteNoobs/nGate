#!/usr/bin/env bash
# ngate-strfry-apply.sh — Stage-4 apply backend for strfry.
# Reads verified+gated NDJSON on stdin (same format ngate-apply.sh consumes),
# merges in seed.toml, atomically rewrites whitelist.json. NO restart needed —
# strfry's write-policy plugin re-reads the file live.
#
#   ... | ngate-gate.sh | ./ngate-strfry-apply.sh --apply
#
# Defaults to --dry-run (nGate convention: write-side scripts need explicit --apply).
set -eo pipefail

DRY_RUN=true
[[ "${1:-}" == "--apply" ]] && DRY_RUN=false

WL="${NGATE_WHITELIST_PATH:-/opt/nostr-relay/policy/whitelist.json}"
SEED="${NGATE_SEED_PATH:-/opt/nostr-relay/seed.toml}"

declare -A keep

# 1. seed.toml — always merged, never auto-removed (CLAUDE.md decision #6)
if [[ -f "$SEED" ]]; then
  while IFS= read -r raw; do
    line="${raw%%#*}"; line="$(echo "$line" | tr -d '[:space:]')"
    [[ -n "$line" ]] && keep["${line,,}"]=1
  done < "$SEED"
fi

# 2. verified+gated discovered keys from stdin NDJSON
while IFS= read -r ev; do
  [[ -z "$ev" ]] && continue
  hex=$(echo "$ev" | jq -r '.nostr_pubkey_hex // empty' 2>/dev/null || true)
  [[ -n "$hex" ]] && keep["${hex,,}"]=1
done

# 3. render sorted JSON array
new_json=$(printf '%s\n' "${!keep[@]}" | sort | jq -R . | jq -s .)

if [[ "$DRY_RUN" == "true" ]]; then
  echo "DRY RUN — would write $(echo "$new_json" | jq 'length') key(s) to $WL" >&2
  echo "$new_json"
  exit 0
fi

# atomic write — strfry's plugin re-reads on mtime change, no restart
tmp="$(mktemp)"
echo "$new_json" > "$tmp"
mv "$tmp" "$WL"
echo "✓ wrote $(echo "$new_json" | jq 'length') key(s) to $WL (no restart)" >&2
