#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# ngate-apply.sh — Phase 3.4 of nGate: rewrite config.toml + (optionally) restart
# ─────────────────────────────────────────────────────────────────────────────
#
# Reads gated-candidate NDJSON from stdin (output of ngate-gate.sh), reads the
# operator's seed.toml, reads the current config.toml, computes the new
# pubkey_whitelist, and either:
#   - PRINTS what it would change (default = --dry-run mode), OR
#   - REWRITES config.toml between BEGIN/END markers and restarts the relay
#     container (--apply mode).
#
# This is the FIRST write-side script in nGate. Many safety rails:
#   1. Defaults to --dry-run; --apply must be explicit.
#   2. Defaults to --no-allow-removals; existing entries are never removed
#      unless the operator/cron has confirmed an upstream-clean run.
#   3. Atomic config.toml write via temp file + rename. No half-written file.
#   4. Restart cap: refuses to restart > NGATE_MAX_RESTARTS_PER_DAY in 24h.
#   5. Refuses to apply if upstream produced ZERO passing candidates AND any
#      existing entries would be removed (sanity bound — no nuking on bad day).
#   6. Per-key consecutive-failure tolerance: an entry must be missing
#      NGATE_MAX_CONSECUTIVE_MISSES runs in a row before it's eligible for
#      removal (default 3 = 3 cycles of absence).
#
# USAGE:
#     # Dry run — print diff, don't change anything
#     ./ngate-scan.sh | ./ngate-verify.sh | NGATE_MIN_HP=3 ./ngate-gate.sh \
#       | ./ngate-apply.sh
#
#     # Apply changes — only adds new entries by default
#     ./ngate-scan.sh | ./ngate-verify.sh | NGATE_MIN_HP=3 ./ngate-gate.sh \
#       | ./ngate-apply.sh --apply
#
#     # Apply changes AND allow removals (only after a CLEAN upstream run)
#     ./ngate-scan.sh | ./ngate-verify.sh | NGATE_MIN_HP=3 ./ngate-gate.sh \
#       | ./ngate-apply.sh --apply --allow-removals
#
#     # First-time setup — wraps existing [authorization] in markers
#     ./ngate-apply.sh --bootstrap
#
# ENVIRONMENT VARIABLES (all optional, sensible defaults):
#     NGATE_CONFIG_PATH           Path to relay's config.toml
#                                 (default: /opt/nostr-relay/config.toml)
#     NGATE_SEED_PATH             Path to operator-managed seed list
#                                 (default: /opt/nostr-relay/seed.toml)
#     NGATE_STATE_PATH            Path to ngate-state.json
#                                 (default: /opt/nostr-relay/ngate-state.json)
#     NGATE_RESTART_CMD           Command to restart the relay container
#                                 (default: "docker compose -f
#                                  /opt/nostr-relay/docker-compose.yml
#                                  restart nostr-relay")
#     NGATE_MAX_CONSECUTIVE_MISSES  How many cycles a key must be missing
#                                 before becoming eligible for removal.
#                                 (default: 3)
#     NGATE_MAX_RESTARTS_PER_DAY  Cap on relay restarts per 24 hours.
#                                 (default: 6)
#
# DEPENDENCIES:
#     bash 4+, jq, awk, sed, mktemp
#
# EXIT CODES:
#     0 = success (whether dry-run or apply)
#     1 = config.toml missing or markers absent (run --bootstrap)
#     2 = bad arguments / missing dependencies
#     3 = restart cap hit; config.toml left untouched, retry next cycle
#     4 = sanity check failed; refusing to apply (e.g. would remove every
#         non-seed entry on an empty-input run)
# ─────────────────────────────────────────────────────────────────────────────

set -eo pipefail
# (no -u: bash 4.x trips on `${#empty_assoc_array[@]}` under nounset)

# ───── arg parsing ──────────────────────────────────────────────────────────
DRY_RUN=true
ALLOW_REMOVALS=false
BOOTSTRAP=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) DRY_RUN=false; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --allow-removals) ALLOW_REMOVALS=true; shift ;;
    --no-allow-removals) ALLOW_REMOVALS=false; shift ;;
    --bootstrap) BOOTSTRAP=true; shift ;;
    --help|-h) sed -n '2,/^# ────.*/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown arg: $1 (try --help)" >&2; exit 2 ;;
  esac
done

# ───── dependency check ─────────────────────────────────────────────────────
for cmd in jq awk sed mktemp; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ngate-apply: missing dependency '$cmd'" >&2; exit 2; }
done

# ───── env defaults ─────────────────────────────────────────────────────────
CONFIG_PATH="${NGATE_CONFIG_PATH:-/opt/nostr-relay/config.toml}"
SEED_PATH="${NGATE_SEED_PATH:-/opt/nostr-relay/seed.toml}"
STATE_PATH="${NGATE_STATE_PATH:-/opt/nostr-relay/ngate-state.json}"
RESTART_CMD="${NGATE_RESTART_CMD:-docker compose -f /opt/nostr-relay/docker-compose.yml restart nostr-relay}"
MAX_CONSECUTIVE_MISSES="${NGATE_MAX_CONSECUTIVE_MISSES:-3}"
MAX_RESTARTS_PER_DAY="${NGATE_MAX_RESTARTS_PER_DAY:-6}"

[[ "$MAX_CONSECUTIVE_MISSES" =~ ^[0-9]+$ ]] || { echo "ngate-apply: NGATE_MAX_CONSECUTIVE_MISSES must be integer" >&2; exit 2; }
[[ "$MAX_RESTARTS_PER_DAY" =~ ^[0-9]+$ ]]   || { echo "ngate-apply: NGATE_MAX_RESTARTS_PER_DAY must be integer" >&2; exit 2; }

log() { echo "ngate-apply: $*" >&2; }

# ───── markers used to delimit the nGate-managed block in config.toml ──────
BEGIN_MARKER="# === BEGIN NGATE-MANAGED — DO NOT EDIT BY HAND ==="
END_MARKER="# === END NGATE-MANAGED ==="

# ─────────────────────────────────────────────────────────────────────────────
# BOOTSTRAP MODE — wrap existing [authorization] section in BEGIN/END markers
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$BOOTSTRAP" == "true" ]]; then
  if [[ ! -f "$CONFIG_PATH" ]]; then
    log "ERROR: config not found at $CONFIG_PATH"
    log "  Set NGATE_CONFIG_PATH to point at your nostr-rs-relay config.toml"
    exit 1
  fi
  if grep -qF "$BEGIN_MARKER" "$CONFIG_PATH"; then
    log "Already bootstrapped (markers present in $CONFIG_PATH). Nothing to do."
    exit 0
  fi
  if ! grep -qE '^[[:space:]]*\[authorization\]' "$CONFIG_PATH"; then
    log "ERROR: no [authorization] section found in $CONFIG_PATH"
    log "  Either add one (with pubkey_whitelist = [...]) and re-run,"
    log "  or paste the BEGIN/END marker block manually around your existing one."
    exit 1
  fi
  tmp=$(mktemp)
  # Tolerate leading whitespace on the [authorization] header AND on items
  # inside the block — some operators' config.toml files are indented (TOML
  # itself doesn't care). The rewritten managed block is normalised to
  # column-0 from this point forward.
  awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
    /^[[:space:]]*\[authorization\][[:space:]]*$/ {
      print begin
      print "[authorization]"
      in_auth=1
      next
    }
    in_auth && /^[[:space:]]*\[/ {
      print end
      print ""
      in_auth=0
    }
    {
      if (in_auth) sub(/^[[:space:]]+/, "")
      print
    }
    END {
      if (in_auth) print end
    }
  ' "$CONFIG_PATH" > "$tmp"
  mv "$tmp" "$CONFIG_PATH"
  log "✓ Bootstrapped — wrapped [authorization] in BEGIN/END markers."
  log "  ngate-apply now manages everything between those markers."
  log "  Operator-edited keys go in: $SEED_PATH"
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# NORMAL MODE — read inputs, compute diff, optionally apply
# ─────────────────────────────────────────────────────────────────────────────

# Sanity: config exists and is bootstrapped
if [[ ! -f "$CONFIG_PATH" ]]; then
  log "ERROR: config not found at $CONFIG_PATH"
  log "  Set NGATE_CONFIG_PATH or run from a box that has the relay deployed."
  exit 1
fi
if ! grep -qF "$BEGIN_MARKER" "$CONFIG_PATH" || ! grep -qF "$END_MARKER" "$CONFIG_PATH"; then
  log "ERROR: BEGIN/END markers not found in $CONFIG_PATH"
  log "  This config has not been bootstrapped for nGate yet."
  log "  Run: $0 --bootstrap"
  log "  (or add the markers manually around your [authorization] section)"
  exit 1
fi

# ───── read seed pubkeys ───────────────────────────────────────────────────
declare -A seed_pubkeys
if [[ -f "$SEED_PATH" ]]; then
  while IFS= read -r raw_line; do
    line="${raw_line%%#*}"           # strip comments
    line="$(echo "$line" | tr -d '[:space:]')"  # strip all whitespace
    [[ -z "$line" ]] && continue
    line_lc="$(echo "$line" | tr '[:upper:]' '[:lower:]')"
    if [[ ! "$line_lc" =~ ^[0-9a-f]{64}$ ]]; then
      log "WARN: skipping invalid line in $SEED_PATH: '$raw_line'"
      continue
    fi
    seed_pubkeys[$line_lc]=1
  done < "$SEED_PATH"
fi
log "seed: ${#seed_pubkeys[@]} pubkey(s) loaded from $SEED_PATH"

# ───── read existing whitelist from config.toml (between markers only) ─────
declare -A existing_whitelist
existing_block=$(awk -v b="$BEGIN_MARKER" -v e="$END_MARKER" '
  $0 == b { in_block=1; next }
  $0 == e { in_block=0 }
  in_block { print }
' "$CONFIG_PATH")

while IFS= read -r hex; do
  [[ -z "$hex" ]] && continue
  existing_whitelist[$hex]=1
done < <(echo "$existing_block" \
  | grep -oE '"[0-9a-f]{64}"' \
  | tr -d '"' \
  | sort -u)
log "current: ${#existing_whitelist[@]} pubkey(s) in $CONFIG_PATH whitelist"

# ───── read passing-this-run from stdin ────────────────────────────────────
declare -A passing_now
declare -A passing_meta
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  hex=$(echo "$line" | jq -r '.nostr_pubkey_hex // empty' 2>/dev/null || true)
  [[ -z "$hex" ]] && continue
  hex_lc="$(echo "$hex" | tr '[:upper:]' '[:lower:]')"
  [[ ! "$hex_lc" =~ ^[0-9a-f]{64}$ ]] && continue
  passing_now[$hex_lc]=1
  passing_meta[$hex_lc]="$line"
done
log "stdin: ${#passing_now[@]} candidate(s) passed gate this run"

# ───── load state.json ─────────────────────────────────────────────────────
if [[ -f "$STATE_PATH" ]]; then
  state="$(cat "$STATE_PATH")"
else
  state='{"last_run":"","last_apply":"","restart_log":[],"candidates":{}}'
  log "state: starting fresh (no $STATE_PATH yet)"
fi

now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Helper: get current consecutive_misses for a hex from state
get_misses() {
  local hex="$1"
  echo "$state" | jq -r --arg h "$hex" '.candidates[$h].consecutive_misses // 0'
}
get_first_seen() {
  local hex="$1"
  echo "$state" | jq -r --arg h "$hex" '.candidates[$h].first_seen // ""'
}

# ───── compute new whitelist ───────────────────────────────────────────────
declare -A new_whitelist
declare -A new_state_candidates_json
declare -A action_for     # hex -> "ADD" | "KEEP" | "TOLERATE" | "REMOVE" | "SEED"
declare -A misses_for     # hex -> consecutive misses count after this run

# 1. Always include seed pubkeys (never removed by discovery logic)
for hex in "${!seed_pubkeys[@]}"; do
  new_whitelist[$hex]=1
  action_for[$hex]="SEED"
  misses_for[$hex]=0
done

# 2. Process passing-this-run candidates
for hex in "${!passing_now[@]}"; do
  new_whitelist[$hex]=1
  if [[ "${action_for[$hex]:-}" == "SEED" ]]; then
    : # seed override stays
  elif [[ -n "${existing_whitelist[$hex]:-}" ]]; then
    action_for[$hex]="KEEP"
  else
    action_for[$hex]="ADD"
  fi
  misses_for[$hex]=0
done

# 3. Process existing entries that are NOT passing this run
for hex in "${!existing_whitelist[@]}"; do
  [[ -n "${seed_pubkeys[$hex]:-}" ]]   && continue   # already handled
  [[ -n "${passing_now[$hex]:-}" ]]    && continue   # already handled

  prev_misses="$(get_misses "$hex")"
  cur_misses=$((prev_misses + 1))
  misses_for[$hex]="$cur_misses"

  if (( cur_misses < MAX_CONSECUTIVE_MISSES )); then
    new_whitelist[$hex]=1
    action_for[$hex]="TOLERATE"
  else
    if [[ "$ALLOW_REMOVALS" == "true" ]]; then
      action_for[$hex]="REMOVE"
      # not added to new_whitelist
    else
      new_whitelist[$hex]=1
      action_for[$hex]="TOLERATE"
      log "would remove $hex (missed $cur_misses) but --allow-removals=false"
    fi
  fi
done

# Sanity bound: if upstream produced 0 candidates AND we'd remove everything
# non-seed, refuse to apply (this looks like an upstream outage misclassified
# as clean).
non_seed_existing=0
for hex in "${!existing_whitelist[@]}"; do
  [[ -z "${seed_pubkeys[$hex]:-}" ]] && non_seed_existing=$((non_seed_existing + 1))
done
non_seed_new=0
for hex in "${!new_whitelist[@]}"; do
  [[ -z "${seed_pubkeys[$hex]:-}" ]] && non_seed_new=$((non_seed_new + 1))
done

if [[ "$DRY_RUN" == "false" ]] \
   && (( ${#passing_now[@]} == 0 )) \
   && (( non_seed_existing > 0 )) \
   && (( non_seed_new == 0 )); then
  log "ERROR: refusing to apply — zero candidates passed gate AND every non-seed entry would be removed"
  log "  This looks like an upstream outage. Re-run when the chain is healthy."
  log "  (Override: pass --no-allow-removals or run with NGATE_MAX_CONSECUTIVE_MISSES higher.)"
  exit 4
fi

# ───── build state.json snapshot for this run ──────────────────────────────
new_state='{}'
new_state=$(echo "$new_state" | jq --arg now "$now_iso" '. + {last_run: $now}')

# Carry forward last_apply and restart_log unchanged for now (updated below if --apply)
last_apply="$(echo "$state" | jq -r '.last_apply // ""')"
restart_log="$(echo "$state" | jq -c '.restart_log // []')"
new_state=$(echo "$new_state" | jq --arg la "$last_apply" '. + {last_apply: $la}')
new_state=$(echo "$new_state" | jq --argjson rl "$restart_log" '. + {restart_log: $rl}')

# Build candidates map
candidates_json='{}'
for hex in "${!new_whitelist[@]}"; do
  m="${misses_for[$hex]:-0}"
  fs="$(get_first_seen "$hex")"
  [[ -z "$fs" ]] && fs="$now_iso"
  ls="$now_iso"
  source="discovery"
  [[ "${action_for[$hex]}" == "SEED" ]] && source="seed"
  candidates_json=$(echo "$candidates_json" | jq -c \
    --arg h "$hex" \
    --arg fs "$fs" \
    --arg ls "$ls" \
    --argjson m "$m" \
    --arg src "$source" \
    '. + {($h): {first_seen: $fs, last_seen: $ls, consecutive_misses: $m, source: $src}}')
done
# Also keep entries we're about to REMOVE in state, with their incremented count
for hex in "${!action_for[@]}"; do
  [[ "${action_for[$hex]}" != "REMOVE" ]] && continue
  m="${misses_for[$hex]:-0}"
  fs="$(get_first_seen "$hex")"
  [[ -z "$fs" ]] && fs="$now_iso"
  candidates_json=$(echo "$candidates_json" | jq -c \
    --arg h "$hex" \
    --arg fs "$fs" \
    --argjson m "$m" \
    '. + {($h): {first_seen: $fs, last_seen: "", consecutive_misses: $m, source: "removed"}}')
done
new_state=$(echo "$new_state" | jq --argjson c "$candidates_json" '. + {candidates: $c}')

# ───── print summary ───────────────────────────────────────────────────────
n_add=0; n_keep=0; n_tolerate=0; n_remove=0; n_seed=0
for hex in "${!action_for[@]}"; do
  case "${action_for[$hex]}" in
    ADD)      n_add=$((n_add+1));      log "  ADD       $hex" ;;
    KEEP)     n_keep=$((n_keep+1)) ;;
    TOLERATE) n_tolerate=$((n_tolerate+1)); log "  TOLERATE  $hex (missed ${misses_for[$hex]}/$MAX_CONSECUTIVE_MISSES)" ;;
    REMOVE)   n_remove=$((n_remove+1));     log "  REMOVE    $hex (missed ${misses_for[$hex]} >= $MAX_CONSECUTIVE_MISSES)" ;;
    SEED)     n_seed=$((n_seed+1)) ;;
  esac
done

log "summary: add=$n_add keep=$n_keep tolerate=$n_tolerate remove=$n_remove seed=$n_seed → new whitelist size = ${#new_whitelist[@]}"

changed=false
if [[ "$n_add" -gt 0 || "$n_remove" -gt 0 ]]; then
  changed=true
fi

if [[ "$DRY_RUN" == "true" ]]; then
  log "DRY RUN — no files changed. Add --apply to write."
  exit 0
fi

if [[ "$changed" == "false" ]]; then
  log "no changes — config.toml left untouched, no restart needed"
  # still update last_run timestamp + miss counts
  echo "$new_state" | jq . > "$STATE_PATH.tmp" && mv "$STATE_PATH.tmp" "$STATE_PATH"
  exit 0
fi

# ───── restart cap check ───────────────────────────────────────────────────
threshold=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || date -u +%Y-%m-%dT%H:%M:%SZ)
restarts_24h=$(echo "$state" \
  | jq -r --arg t "$threshold" '.restart_log // [] | map(select(. > $t)) | length')

if (( restarts_24h >= MAX_RESTARTS_PER_DAY )); then
  log "ERROR: restart cap hit ($restarts_24h/$MAX_RESTARTS_PER_DAY in last 24h)"
  log "  Refusing to restart. config.toml NOT modified this cycle."
  log "  Will retry on next cycle when older entries fall outside the 24h window."
  exit 3
fi

# ───── render new managed block ─────────────────────────────────────────────
mapfile -t sorted_hexes < <(printf '%s\n' "${!new_whitelist[@]}" | sort)
new_block=$(
  printf '[authorization]\n'
  printf '# Managed by ngate-apply.sh — last write: %s\n' "$now_iso"
  printf 'pubkey_whitelist = [\n'
  for hex in "${sorted_hexes[@]}"; do
    printf '  "%s",\n' "$hex"
  done
  printf ']\n'
)

# ───── splice into config.toml atomically ──────────────────────────────────
tmp=$(mktemp)
awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" -v block="$new_block" '
  $0 == begin { print; print block; in_block=1; next }
  $0 == end   { in_block=0; print; next }
  !in_block   { print }
' "$CONFIG_PATH" > "$tmp"

# Sanity check the output
if ! grep -qF "$BEGIN_MARKER" "$tmp" || ! grep -qF "$END_MARKER" "$tmp"; then
  log "ERROR: rewrite broke marker structure; aborting (original config preserved)"
  rm -f "$tmp"
  exit 4
fi
new_count=$(awk -v b="$BEGIN_MARKER" -v e="$END_MARKER" '
  $0 == b { in_block=1; next }
  $0 == e { in_block=0 }
  in_block { print }
' "$tmp" | grep -cE '"[0-9a-f]{64}"' || true)
if (( new_count != ${#new_whitelist[@]} )); then
  log "ERROR: rewrite count mismatch (expected ${#new_whitelist[@]}, got $new_count); aborting"
  rm -f "$tmp"
  exit 4
fi

mv "$tmp" "$CONFIG_PATH"
log "✓ wrote new whitelist (${#new_whitelist[@]} entries) to $CONFIG_PATH"

# ───── restart relay container ─────────────────────────────────────────────
log "restarting relay: $RESTART_CMD"
if eval "$RESTART_CMD" >/dev/null 2>&1; then
  log "✓ restart succeeded"
  new_restart_log=$(echo "$restart_log" | jq -c --arg now "$now_iso" '. + [$now]')
  new_state=$(echo "$new_state" \
    | jq --arg now "$now_iso" '. + {last_apply: $now}' \
    | jq --argjson rl "$new_restart_log" '. + {restart_log: $rl}')
else
  log "WARN: restart command failed — config.toml is updated but relay may be running stale"
  log "  Inspect manually: $RESTART_CMD"
fi

# ───── persist state.json ──────────────────────────────────────────────────
echo "$new_state" | jq . > "$STATE_PATH.tmp" && mv "$STATE_PATH.tmp" "$STATE_PATH"
log "✓ state saved to $STATE_PATH"
