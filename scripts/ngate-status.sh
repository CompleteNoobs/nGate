#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# ngate-status.sh — quick "what's nGate doing?" summary for operators
# ─────────────────────────────────────────────────────────────────────────────
#
# Reads state.json + config.toml + ngate.yaml and prints a human-readable
# summary: last run, last apply, current whitelist size, restart history,
# per-key miss counts. Read-only. Safe to run any time.
#
# USAGE:
#     ./ngate-status.sh
#     ./ngate-status.sh --help
#
# ENVIRONMENT (same paths as ngate-sync.sh / ngate-apply.sh):
#     NGATE_YAML, NGATE_CONFIG_PATH, NGATE_SEED_PATH, NGATE_STATE_PATH
# ─────────────────────────────────────────────────────────────────────────────

set -eo pipefail

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) sed -n '2,/^# ────.*/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown arg: $1 (try --help)" >&2; exit 2 ;;
  esac
done

for cmd in jq awk; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ngate-status: missing dependency '$cmd'" >&2; exit 2; }
done

CONFIG_FILE="${NGATE_YAML:-/app/ngate.yaml}"
CONFIG_PATH="${NGATE_CONFIG_PATH:-/app/config.toml}"
SEED_PATH="${NGATE_SEED_PATH:-/app/seed.toml}"
STATE_PATH="${NGATE_STATE_PATH:-/app/state.json}"

# If yq is available and yaml exists, read instance_name from there
INSTANCE_NAME="ngate"
if command -v yq >/dev/null 2>&1 && [[ -f "$CONFIG_FILE" ]]; then
  INSTANCE_NAME=$(yq -r '.instance_name // "ngate"' "$CONFIG_FILE")
fi

printf '╔═══════════════════════════════════════════════════════════════════╗\n'
printf '║  nGate status — instance: %-39s ║\n' "$INSTANCE_NAME"
printf '╚═══════════════════════════════════════════════════════════════════╝\n'
echo

# ── state ──────────────────────────────────────────────────────────────────
if [[ -f "$STATE_PATH" ]]; then
  state=$(cat "$STATE_PATH")
  last_run=$(echo "$state"   | jq -r '.last_run   // "(never)"')
  last_apply=$(echo "$state" | jq -r '.last_apply // "(never)"')
  cand_count=$(echo "$state" | jq -r '.candidates // {} | length')
  restarts=$(echo "$state"   | jq -r '.restart_log // [] | length')

  printf '  Last run:        %s\n' "$last_run"
  printf '  Last apply:      %s\n' "$last_apply"
  printf '  Restarts (all):  %d\n' "$restarts"

  # Restarts in the last 24h
  threshold=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
              || date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
              || echo "")
  if [[ -n "$threshold" ]]; then
    restarts_24h=$(echo "$state" \
      | jq -r --arg t "$threshold" '.restart_log // [] | map(select(. > $t)) | length')
    printf '  Restarts (24h):  %d\n' "$restarts_24h"
  fi
  printf '  Tracked keys:    %d\n' "$cand_count"
else
  echo "  ⚠ no state.json at $STATE_PATH (nGate hasn't applied yet)"
fi
echo

# ── seed.toml ──────────────────────────────────────────────────────────────
echo "  Seed list ($SEED_PATH):"
if [[ -f "$SEED_PATH" ]]; then
  seed_count=$(grep -cE '^[[:space:]]*[0-9a-fA-F]{64}[[:space:]]*(#.*)?$' "$SEED_PATH" || true)
  printf '    %d operator-managed pubkey(s) (always allowed)\n' "$seed_count"
else
  echo "    (file not present)"
fi
echo

# ── current whitelist (between BEGIN/END markers) ──────────────────────────
echo "  Active whitelist ($CONFIG_PATH):"
if [[ -f "$CONFIG_PATH" ]]; then
  if grep -qF "# === BEGIN NGATE-MANAGED" "$CONFIG_PATH"; then
    in_count=$(awk '/BEGIN NGATE-MANAGED/,/END NGATE-MANAGED/' "$CONFIG_PATH" \
      | grep -cE '"[0-9a-f]{64}"' || true)
    printf '    %d pubkey(s) in nGate-managed block\n' "$in_count"
  else
    echo "    (not yet bootstrapped — run ngate-apply.sh --bootstrap)"
  fi
else
  echo "    (config.toml not present)"
fi
echo

# ── per-candidate breakdown ────────────────────────────────────────────────
if [[ -f "$STATE_PATH" ]]; then
  echo "  Per-key state (top 10 by consecutive_misses):"
  echo "$state" \
    | jq -r '.candidates // {} | to_entries
             | sort_by(-.value.consecutive_misses)
             | .[0:10]
             | .[]
             | "    " + (.value.consecutive_misses|tostring|.[0:2]|.+(" " * (3 - length))) + " miss(es)  "
                     + (.value.source[0:7]) + "  "
                     + .key[0:16] + "…  first_seen=" + .value.first_seen'
  echo
fi

echo "  (Run with NGATE_YAML / NGATE_STATE_PATH etc. to inspect a non-default instance.)"
