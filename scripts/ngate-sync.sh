#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# ngate-sync.sh — Phase 3.5 of nGate: glue + cron-replacement loop
# ─────────────────────────────────────────────────────────────────────────────
#
# Reads ngate.yaml once at startup, translates the operator-friendly YAML into
# env vars, then runs the full chain (scan → verify → gate → apply) on a
# self-paced loop. Inspects PIPESTATUS after each cycle to automatically pass
# --allow-removals to ngate-apply only when every upstream phase exited 0.
#
# Designed to run as a Docker sidecar service alongside relay + caddy.
# Can also be run on a host or laptop with `--once` for one-shot testing.
#
# USAGE:
#     ./ngate-sync.sh                # loop forever (sidecar mode)
#     ./ngate-sync.sh --once         # run one cycle and exit
#     ./ngate-sync.sh --help
#
# ENVIRONMENT:
#     NGATE_YAML       Path to config (default: /app/ngate.yaml)
#
# DEPENDENCIES:
#     bash 4+, yq (mikefarah or kislyuk — both work), jq, curl, node, the
#     other four ngate-*.sh scripts in the same dir, the dhive npm helper.
#
# EXIT CODES:
#     0 = success (only reachable with --once, or after SIGTERM in loop mode)
#     2 = bad arguments / missing dependencies / missing config
# ─────────────────────────────────────────────────────────────────────────────

set -eo pipefail

# ───── arg parsing ──────────────────────────────────────────────────────────
RUN_ONCE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --once) RUN_ONCE=true; shift ;;
    --help|-h) sed -n '2,/^# ────.*/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown arg: $1 (try --help)" >&2; exit 2 ;;
  esac
done

# ───── dependency check ─────────────────────────────────────────────────────
for cmd in yq jq curl node bash awk sed; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ngate-sync: missing dependency '$cmd'" >&2; exit 2; }
done

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for sub in ngate-scan.sh ngate-verify.sh ngate-gate.sh ngate-apply.sh; do
  [[ -x "$SCRIPTS_DIR/$sub" ]] || { echo "ngate-sync: missing or non-executable $SCRIPTS_DIR/$sub" >&2; exit 2; }
done

CONFIG_FILE="${NGATE_YAML:-/app/ngate.yaml}"
[[ -f "$CONFIG_FILE" ]] || { echo "ngate-sync: config not found at $CONFIG_FILE (set NGATE_YAML)" >&2; exit 2; }

# ───── parse YAML → env-style locals ────────────────────────────────────────
# `yq -r EXPR FILE` works for both mikefarah/yq (Go) and kislyuk/yq (Python
# wrapping jq). Using `// default` for missing keys.
read_yaml() { yq -r "$1" "$CONFIG_FILE"; }

INSTANCE_NAME=$(read_yaml '.instance_name // "ngate"')
SCAN_INTERVAL=$(read_yaml '.scan_interval_seconds // 21600')

GATE_ACCOUNT=$(read_yaml '.gate.account // "escrow"')
MIN_HP=$(read_yaml '.gate.min_hp // 0')
INCLUDE_DELEGATED_HP=$(read_yaml '.gate.include_delegated_hp // false')
MIN_TOKEN_SYMBOL=$(read_yaml '.gate.min_token_symbol // ""')
MIN_TOKEN_AMOUNT=$(read_yaml '.gate.min_token_amount // 0')
INCLUDE_STAKED_TOKEN=$(read_yaml '.gate.include_staked_token // true')
GATE_MODE=$(read_yaml '.gate.mode // "or"')

MAX_CONSECUTIVE_FAILURES=$(read_yaml '.max_consecutive_failures // 3')
MAX_RESTARTS_PER_DAY=$(read_yaml '.max_restarts_per_day // 6')
VERBOSE=$(read_yaml '.verbose // false')
RESTART_CMD=$(read_yaml '.restart_command // "docker restart nostr-relay"')

CONFIG_PATH=$(read_yaml '.paths.config_toml // "/app/config.toml"')
SEED_PATH=$(read_yaml   '.paths.seed_toml   // "/app/seed.toml"')
STATE_PATH=$(read_yaml  '.paths.state_json  // "/app/state.json"')
LOG_FILE=$(read_yaml    '.paths.log_file    // "/app/ngate-sync.log"')

# Sanity: ensure log dir exists & file is writable
log_dir=$(dirname "$LOG_FILE")
mkdir -p "$log_dir" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || LOG_FILE=/dev/null

# ───── logging ──────────────────────────────────────────────────────────────
log() {
  local line="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [$INSTANCE_NAME] $*"
  echo "$line"
  [[ "$LOG_FILE" != /dev/null ]] && echo "$line" >> "$LOG_FILE"
}

# ───── graceful shutdown ────────────────────────────────────────────────────
trap 'log "received signal — exiting"; exit 0' SIGTERM SIGINT

# ───── single cycle ─────────────────────────────────────────────────────────
run_cycle() {
  log "─── cycle starting ───"

  local tmp_gated
  tmp_gated=$(mktemp)

  # Run the read-only chain. PIPESTATUS array tells us if any phase had errors.
  set +e
  "$SCRIPTS_DIR/ngate-scan.sh" 2>>"$LOG_FILE" \
    | "$SCRIPTS_DIR/ngate-verify.sh" 2>>"$LOG_FILE" \
    | NGATE_GATE_ACCOUNT="$GATE_ACCOUNT" \
      NGATE_MIN_HP="$MIN_HP" \
      NGATE_INCLUDE_DELEGATED_HP="$INCLUDE_DELEGATED_HP" \
      NGATE_MIN_TOKEN_SYMBOL="$MIN_TOKEN_SYMBOL" \
      NGATE_MIN_TOKEN_AMOUNT="$MIN_TOKEN_AMOUNT" \
      NGATE_INCLUDE_STAKED_TOKEN="$INCLUDE_STAKED_TOKEN" \
      NGATE_GATE_MODE="$GATE_MODE" \
      NGATE_DEBUG="$( [[ "$VERBOSE" == "true" ]] && echo 1 || echo 0 )" \
      "$SCRIPTS_DIR/ngate-gate.sh" 2>>"$LOG_FILE" > "$tmp_gated"
  local pipestatus=("${PIPESTATUS[@]}")
  set -e

  local scan_exit=${pipestatus[0]:-?}
  local verify_exit=${pipestatus[1]:-?}
  local gate_exit=${pipestatus[2]:-?}

  local upstream_clean=true
  if [[ "$scan_exit" -ne 0 || "$verify_exit" -ne 0 || "$gate_exit" -ne 0 ]]; then
    upstream_clean=false
    log "upstream errors (scan=$scan_exit verify=$verify_exit gate=$gate_exit) — ADD-only this cycle"
  fi

  # Apply: write-side. Toggle --allow-removals based on upstream cleanliness.
  local apply_args=(--apply)
  if $upstream_clean; then
    apply_args+=(--allow-removals)
  fi

  set +e
  cat "$tmp_gated" \
    | NGATE_CONFIG_PATH="$CONFIG_PATH" \
      NGATE_SEED_PATH="$SEED_PATH" \
      NGATE_STATE_PATH="$STATE_PATH" \
      NGATE_RESTART_CMD="$RESTART_CMD" \
      NGATE_MAX_CONSECUTIVE_MISSES="$MAX_CONSECUTIVE_FAILURES" \
      NGATE_MAX_RESTARTS_PER_DAY="$MAX_RESTARTS_PER_DAY" \
      "$SCRIPTS_DIR/ngate-apply.sh" "${apply_args[@]}" 2>>"$LOG_FILE"
  local apply_exit=$?
  set -e

  rm -f "$tmp_gated"

  case "$apply_exit" in
    0) log "─── cycle complete (apply ok) ───" ;;
    3) log "─── cycle complete (apply: restart cap hit; config left untouched) ───" ;;
    4) log "─── cycle complete (apply: sanity bound triggered; no changes) ───" ;;
    *) log "─── cycle complete (apply exit=$apply_exit — check log) ───" ;;
  esac
}

# ───── main ─────────────────────────────────────────────────────────────────
log "starting ngate-sync instance=$INSTANCE_NAME interval=${SCAN_INTERVAL}s gate=$GATE_ACCOUNT/min_hp=$MIN_HP/token=${MIN_TOKEN_SYMBOL:-none}>=${MIN_TOKEN_AMOUNT}/mode=$GATE_MODE delegated=$INCLUDE_DELEGATED_HP"
run_cycle

if [[ "$RUN_ONCE" == "true" ]]; then
  log "--once specified — exiting"
  exit 0
fi

while true; do
  log "sleeping ${SCAN_INTERVAL}s until next cycle"
  sleep "$SCAN_INTERVAL" &
  wait $!
  run_cycle
done
