#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# ngate-gate.sh — Phase 3.3 of nGate: apply HP / token gate config
# ─────────────────────────────────────────────────────────────────────────────
#
# Reads NDJSON verified candidates from stdin (output of ngate-verify.sh),
# applies the gate config (read from environment variables), and emits only
# passing candidates to stdout — with extra "gate_pass" / "gate_passed_via" /
# "gate_hp" / "gate_token" metadata appended.
#
# A candidate passes IFF:
#   - HP gate disabled OR account's HP >= NGATE_MIN_HP
#   - AND/OR (per NGATE_GATE_MODE) token gate disabled OR account holds
#     >= NGATE_MIN_TOKEN_AMOUNT of NGATE_MIN_TOKEN_SYMBOL.
#
# When BOTH gates are enabled, NGATE_GATE_MODE picks the combination:
#   "or"  → either passes → in        (default)
#   "and" → both pass → in
#
# When neither gate is configured (default), every verified candidate passes
# through unchanged with a clear stderr warning. Useful for sanity testing.
#
# This phase is read-only — does not write config.toml or persist state.
#
# USAGE:
#     # All gates default: warns and passes everything through
#     ./ngate-scan.sh | ./ngate-verify.sh | ./ngate-gate.sh
#
#     # Real gate: 3+ HP on the escrow account
#     NGATE_MIN_HP=3 ./ngate-scan.sh | ./ngate-verify.sh | ./ngate-gate.sh
#
#     # Multiple gates, OR mode (default)
#     NGATE_MIN_HP=3 NGATE_MIN_TOKEN_SYMBOL=CNOOBS NGATE_MIN_TOKEN_AMOUNT=33 \
#       ./ngate-scan.sh | ./ngate-verify.sh | ./ngate-gate.sh
#
#     # Multiple gates, AND mode
#     NGATE_MIN_HP=3 NGATE_MIN_TOKEN_SYMBOL=CNOOBS NGATE_MIN_TOKEN_AMOUNT=33 \
#       NGATE_GATE_MODE=and \
#       ./ngate-scan.sh | ./ngate-verify.sh | ./ngate-gate.sh
#
# ENVIRONMENT VARIABLES (all optional):
#     NGATE_GATE_ACCOUNT          escrow | hive_account   (default: escrow)
#     NGATE_MIN_HP                positive number          (default: 0 = disabled)
#     NGATE_INCLUDE_DELEGATED_HP  true | false             (default: false)
#     NGATE_MIN_TOKEN_SYMBOL      e.g. CNOOBS              (default: empty = disabled)
#     NGATE_MIN_TOKEN_AMOUNT      positive number          (default: 0)
#     NGATE_INCLUDE_STAKED_TOKEN  true | false             (default: true)
#     NGATE_GATE_MODE             or | and                 (default: or)
#     NGATE_DEBUG                 1 | 0                    (default: 0; 1 = verbose math)
#
#   Split-account mode (Stage 3.7 Part A) — independent conditions on the
#   escrow account AND the hive_account. Auto-enabled when ANY of the six
#   NGATE_ESCROW_* / NGATE_HIVE_* vars is set; otherwise the flat
#   single-account behaviour above is used unchanged. Within each account,
#   its hp/token sub-gates combine via NGATE_GATE_MODE; the two account
#   results combine via NGATE_ACCOUNT_MODE.
#     NGATE_ACCOUNT_MODE            or | and               (default: and)
#     NGATE_ESCROW_MIN_HP           number                 (default: 0)
#     NGATE_ESCROW_MIN_TOKEN_SYMBOL e.g. CNOOBS            (default: empty)
#     NGATE_ESCROW_MIN_TOKEN_AMOUNT number                 (default: 0)
#     NGATE_HIVE_MIN_HP             number                 (default: 0)
#     NGATE_HIVE_MIN_TOKEN_SYMBOL   e.g. CNOOBS            (default: empty)
#     NGATE_HIVE_MIN_TOKEN_AMOUNT   number                 (default: 0)
#   An account with no sub-gate configured passes vacuously. With
#   NGATE_ACCOUNT_MODE=or that means everything passes — use 'and' or
#   configure both sides.
#   Example (escrow >=300 HP AND hive_account >=4 CNOOBS):
#     NGATE_ESCROW_MIN_HP=300 NGATE_HIVE_MIN_TOKEN_SYMBOL=CNOOBS \
#       NGATE_HIVE_MIN_TOKEN_AMOUNT=4 NGATE_ACCOUNT_MODE=and \
#       ./ngate-scan.sh | ./ngate-verify.sh | ./ngate-gate.sh
#
# DEPENDENCIES:
#     bash 4+, curl, jq, awk
#
# EXIT CODES:
#     0 = clean run (every candidate either passed or rejected definitively)
#     1 = no Hive node reachable for global properties (cannot compute HP at all)
#     2 = partial fetch errors during run — phase 3.4 should treat output
#         as non-authoritative and refuse to remove existing entries
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
for cmd in curl jq awk; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ngate-gate: missing dependency '$cmd'" >&2; exit 2; }
done

# ───── env var defaults + validation ────────────────────────────────────────
GATE_ACCOUNT="${NGATE_GATE_ACCOUNT:-escrow}"
MIN_HP="${NGATE_MIN_HP:-0}"
INCLUDE_DELEGATED_HP="${NGATE_INCLUDE_DELEGATED_HP:-false}"
MIN_TOKEN_SYMBOL="${NGATE_MIN_TOKEN_SYMBOL:-}"
MIN_TOKEN_AMOUNT="${NGATE_MIN_TOKEN_AMOUNT:-0}"
INCLUDE_STAKED_TOKEN="${NGATE_INCLUDE_STAKED_TOKEN:-true}"
GATE_MODE="${NGATE_GATE_MODE:-or}"
DEBUG="${NGATE_DEBUG:-0}"

# ── Split-account mode (Stage 3.7 Part A) ───────────────────────────────────
# Independent sub-conditions on the escrow account AND the hive_account,
# combined by NGATE_ACCOUNT_MODE. Triggered when ANY of the six split vars is
# set; otherwise the original single-account flat behaviour (NGATE_GATE_ACCOUNT
# + NGATE_MIN_*) is used unchanged. Within each account, its own hp/token
# sub-gates combine via the existing NGATE_GATE_MODE.
ESCROW_MIN_HP="${NGATE_ESCROW_MIN_HP:-0}"
ESCROW_MIN_TOKEN_SYMBOL="${NGATE_ESCROW_MIN_TOKEN_SYMBOL:-}"
ESCROW_MIN_TOKEN_AMOUNT="${NGATE_ESCROW_MIN_TOKEN_AMOUNT:-0}"
HIVE_MIN_HP="${NGATE_HIVE_MIN_HP:-0}"
HIVE_MIN_TOKEN_SYMBOL="${NGATE_HIVE_MIN_TOKEN_SYMBOL:-}"
HIVE_MIN_TOKEN_AMOUNT="${NGATE_HIVE_MIN_TOKEN_AMOUNT:-0}"
ACCOUNT_MODE="${NGATE_ACCOUNT_MODE:-and}"

SPLIT_MODE=0
if [[ -n "${NGATE_ESCROW_MIN_HP:-}" || -n "${NGATE_ESCROW_MIN_TOKEN_SYMBOL:-}" \
   || -n "${NGATE_ESCROW_MIN_TOKEN_AMOUNT:-}" || -n "${NGATE_HIVE_MIN_HP:-}" \
   || -n "${NGATE_HIVE_MIN_TOKEN_SYMBOL:-}" || -n "${NGATE_HIVE_MIN_TOKEN_AMOUNT:-}" ]]; then
  SPLIT_MODE=1
fi

die() { echo "ngate-gate: $*" >&2; exit 2; }
[[ "$GATE_ACCOUNT" =~ ^(escrow|hive_account)$ ]] || die "NGATE_GATE_ACCOUNT must be 'escrow' or 'hive_account', got '$GATE_ACCOUNT'"
[[ "$MIN_HP" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "NGATE_MIN_HP must be a non-negative number, got '$MIN_HP'"
[[ "$INCLUDE_DELEGATED_HP" =~ ^(true|false)$ ]] || die "NGATE_INCLUDE_DELEGATED_HP must be true|false"
[[ "$MIN_TOKEN_AMOUNT" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "NGATE_MIN_TOKEN_AMOUNT must be a non-negative number"
[[ -z "$MIN_TOKEN_SYMBOL" || "$MIN_TOKEN_SYMBOL" =~ ^[A-Z][A-Z0-9.]*$ ]] || die "NGATE_MIN_TOKEN_SYMBOL must be uppercase letters/digits/dots"
[[ "$INCLUDE_STAKED_TOKEN" =~ ^(true|false)$ ]] || die "NGATE_INCLUDE_STAKED_TOKEN must be true|false"
[[ "$GATE_MODE" =~ ^(or|and)$ ]] || die "NGATE_GATE_MODE must be 'or' or 'and'"

if (( SPLIT_MODE )); then
  [[ "$ESCROW_MIN_HP" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "NGATE_ESCROW_MIN_HP must be a non-negative number"
  [[ "$ESCROW_MIN_TOKEN_AMOUNT" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "NGATE_ESCROW_MIN_TOKEN_AMOUNT must be a non-negative number"
  [[ -z "$ESCROW_MIN_TOKEN_SYMBOL" || "$ESCROW_MIN_TOKEN_SYMBOL" =~ ^[A-Z][A-Z0-9.]*$ ]] || die "NGATE_ESCROW_MIN_TOKEN_SYMBOL must be uppercase letters/digits/dots"
  [[ "$HIVE_MIN_HP" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "NGATE_HIVE_MIN_HP must be a non-negative number"
  [[ "$HIVE_MIN_TOKEN_AMOUNT" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "NGATE_HIVE_MIN_TOKEN_AMOUNT must be a non-negative number"
  [[ -z "$HIVE_MIN_TOKEN_SYMBOL" || "$HIVE_MIN_TOKEN_SYMBOL" =~ ^[A-Z][A-Z0-9.]*$ ]] || die "NGATE_HIVE_MIN_TOKEN_SYMBOL must be uppercase letters/digits/dots"
  [[ "$ACCOUNT_MODE" =~ ^(or|and)$ ]] || die "NGATE_ACCOUNT_MODE must be 'or' or 'and'"
fi

# ───── derived flags ────────────────────────────────────────────────────────
hp_enabled=$(awk -v v="$MIN_HP" 'BEGIN { print (v+0 > 0) ? 1 : 0 }')
if [[ -n "$MIN_TOKEN_SYMBOL" ]] && awk -v v="$MIN_TOKEN_AMOUNT" 'BEGIN { exit !(v+0 > 0) }'; then
  token_enabled=1
else
  token_enabled=0
fi

log() { echo "ngate-gate: $*" >&2; }
dbg() { (( DEBUG )) && echo "ngate-gate [debug]: $*" >&2; return 0; }

# ───── intro / config summary ───────────────────────────────────────────────
if (( SPLIT_MODE )); then
  log "config: SPLIT-ACCOUNT mode account_mode=$ACCOUNT_MODE intra_mode=$GATE_MODE delegated=$INCLUDE_DELEGATED_HP staked=$INCLUDE_STAKED_TOKEN"
  log "config:   escrow -> hp>=$ESCROW_MIN_HP token=${ESCROW_MIN_TOKEN_SYMBOL:-none}>=$ESCROW_MIN_TOKEN_AMOUNT"
  log "config:   hive   -> hp>=$HIVE_MIN_HP token=${HIVE_MIN_TOKEN_SYMBOL:-none}>=$HIVE_MIN_TOKEN_AMOUNT"
  esc_empty=0; hiv_empty=0
  [[ "$ESCROW_MIN_HP" =~ ^0(\.0+)?$ && -z "$ESCROW_MIN_TOKEN_SYMBOL" ]] && esc_empty=1
  [[ "$HIVE_MIN_HP"   =~ ^0(\.0+)?$ && -z "$HIVE_MIN_TOKEN_SYMBOL"   ]] && hiv_empty=1
  if [[ "$ACCOUNT_MODE" == "or" ]] && (( esc_empty || hiv_empty )); then
    log "WARN: account_mode=or with one side having NO sub-gate -> that side passes vacuously -> everything passes. Use 'and' or configure both sides."
  fi
else
  log "config: account=$GATE_ACCOUNT mode=$GATE_MODE hp_enabled=$hp_enabled (>=$MIN_HP, delegated=$INCLUDE_DELEGATED_HP) token_enabled=$token_enabled ($MIN_TOKEN_SYMBOL>=$MIN_TOKEN_AMOUNT, staked=$INCLUDE_STAKED_TOKEN)"
  if (( hp_enabled == 0 && token_enabled == 0 )); then
    log "WARN: no gates configured — every verified candidate will pass through"
  fi
fi

# ───── Hive RPC + Hive-Engine endpoints ─────────────────────────────────────
HIVE_NODES=(
  "https://api.hive.blog"
  "https://api.deathwing.me"
  "https://hive-api.arcange.eu"
  "https://api.openhive.network"
)
HIVE_ENGINE_URLS=(
  "https://api.hive-engine.com/rpc/contracts"
  "https://herpc.dtools.dev/contracts"
  "https://engine.deathwing.me/contracts"
)

hive_rpc() {
  local method="$1" params="$2" body resp
  body=$(jq -nc --arg m "$method" --argjson p "$params" \
    '{jsonrpc:"2.0", method:$m, params:$p, id:1}')
  for node in "${HIVE_NODES[@]}"; do
    if resp=$(curl -sS --max-time 10 -H 'Content-Type: application/json' -d "$body" "$node" 2>/dev/null); then
      if echo "$resp" | jq -e '.result' >/dev/null 2>&1; then
        echo "$resp"
        return 0
      fi
    fi
  done
  return 1
}

hive_engine_rpc() {
  local method="$1" params="$2" body resp
  body=$(jq -nc --arg m "$method" --argjson p "$params" \
    '{jsonrpc:"2.0", id:1, method:$m, params:$p}')
  for url in "${HIVE_ENGINE_URLS[@]}"; do
    if resp=$(curl -sS --max-time 10 -H 'Content-Type: application/json' -d "$body" "$url" 2>/dev/null); then
      if echo "$resp" | jq -e '. | has("result")' >/dev/null 2>&1; then
        echo "$resp"
        return 0
      fi
    fi
  done
  return 1
}

# ───── HP calculation ───────────────────────────────────────────────────────
# HP = vesting_shares × hive_per_vest, where hive_per_vest =
#      total_vesting_fund_hive / total_vesting_shares (calc once, cached).
# If NGATE_INCLUDE_DELEGATED_HP=true, also count received_vesting_shares.
# delegated_vesting_shares are NOT subtracted — the account still owns them.
hive_per_vest=""

ensure_hive_per_vest() {
  [[ -n "$hive_per_vest" ]] && return 0
  local resp fund shares
  if ! resp=$(hive_rpc "condenser_api.get_dynamic_global_properties" "[]"); then
    return 1
  fi
  fund=$(echo "$resp"   | jq -r '.result.total_vesting_fund_hive')
  shares=$(echo "$resp" | jq -r '.result.total_vesting_shares')
  hive_per_vest=$(awk -v f="$fund" -v s="$shares" 'BEGIN { printf "%.12f", (f+0) / (s+0) }')
  dbg "hive_per_vest = $hive_per_vest (fund=$fund shares=$shares)"
}

declare -A hp_cache
fetch_hp() {
  local account="$1" resp v r
  if [[ -n "${hp_cache[$account]:-}" ]]; then
    echo "${hp_cache[$account]}"
    return 0
  fi
  ensure_hive_per_vest || return 1
  if ! resp=$(hive_rpc "condenser_api.get_accounts" "[[\"$account\"]]"); then
    return 1
  fi
  if ! echo "$resp" | jq -e '.result | length > 0' >/dev/null 2>&1; then
    dbg "fetch_hp $account — account does not exist on Hive"
    hp_cache[$account]="0"
    echo "0"
    return 0
  fi
  v=$(echo "$resp" | jq -r '.result[0].vesting_shares' | awk '{print $1+0}')
  if [[ "$INCLUDE_DELEGATED_HP" == "true" ]]; then
    r=$(echo "$resp" | jq -r '.result[0].received_vesting_shares' | awk '{print $1+0}')
    v=$(awk -v a="$v" -v b="$r" 'BEGIN { printf "%.6f", a+b }')
  fi
  local hp
  hp=$(awk -v v="$v" -v hpv="$hive_per_vest" 'BEGIN { printf "%.3f", v * hpv }')
  hp_cache[$account]="$hp"
  dbg "fetch_hp $account → $hp HP (vests=$v)"
  echo "$hp"
}

# ───── Token balance ────────────────────────────────────────────────────────
# Hive-Engine: balance + (optionally) stake for one (account, symbol) pair.
declare -A token_cache
fetch_token_balance() {
  local account="$1" symbol="$2" key="$1:$2"
  if [[ -n "${token_cache[$key]:-}" ]]; then
    echo "${token_cache[$key]}"
    return 0
  fi
  local params resp bal stake total
  params=$(jq -nc --arg acc "$account" --arg sym "$symbol" \
    '{contract:"tokens", table:"balances", query:{account:$acc, symbol:$sym}}')
  if ! resp=$(hive_engine_rpc "findOne" "$params"); then
    return 1
  fi
  if echo "$resp" | jq -e '.result == null' >/dev/null 2>&1; then
    dbg "fetch_token_balance $account/$symbol — no balance row (treating as 0)"
    token_cache[$key]="0"
    echo "0"
    return 0
  fi
  bal=$(echo "$resp"   | jq -r '.result.balance // "0"')
  stake=$(echo "$resp" | jq -r '.result.stake // "0"')
  if [[ "$INCLUDE_STAKED_TOKEN" == "true" ]]; then
    total=$(awk -v a="$bal" -v b="$stake" 'BEGIN { printf "%.8f", (a+0) + (b+0) }')
  else
    total="$bal"
  fi
  token_cache[$key]="$total"
  dbg "fetch_token_balance $account/$symbol → $total (bal=$bal stake=$stake)"
  echo "$total"
}

# ───── numeric compare helpers ──────────────────────────────────────────────
ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !((a+0) >= (b+0)) }'; }

# ───── single-account evaluator (split-account mode) ────────────────────────
# Args: account min_hp token_symbol token_amount
# Sets globals: R_HP_EN R_TOK_EN R_HP_PASS R_HP_VAL R_TOK_PASS R_TOK_VAL
# Returns: 0 = pass, 1 = fail, 2 = transient RPC error
# An account with NO sub-gate configured passes vacuously (return 0). Intra-
# account hp/token combine reuses GATE_MODE (NGATE_GATE_MODE).
eval_account() {
  local acct="$1" mhp="$2" tsym="$3" tamt="$4" p
  R_HP_EN=$(awk -v v="$mhp" 'BEGIN { print (v+0 > 0) ? 1 : 0 }')
  if [[ -n "$tsym" ]] && awk -v v="$tamt" 'BEGIN { exit !(v+0 > 0) }'; then
    R_TOK_EN=1
  else
    R_TOK_EN=0
  fi
  R_HP_PASS="false"; R_HP_VAL=""
  R_TOK_PASS="false"; R_TOK_VAL=""

  if (( R_HP_EN )); then
    if R_HP_VAL=$(fetch_hp "$acct"); then
      ge "$R_HP_VAL" "$mhp" && R_HP_PASS="true" || R_HP_PASS="false"
    else
      return 2
    fi
  fi
  if (( R_TOK_EN )); then
    if R_TOK_VAL=$(fetch_token_balance "$acct" "$tsym"); then
      ge "$R_TOK_VAL" "$tamt" && R_TOK_PASS="true" || R_TOK_PASS="false"
    else
      return 2
    fi
  fi

  if (( R_HP_EN && R_TOK_EN )); then
    if [[ "$GATE_MODE" == "or" ]]; then
      [[ "$R_HP_PASS" == "true" || "$R_TOK_PASS" == "true" ]] && p="true" || p="false"
    else
      [[ "$R_HP_PASS" == "true" && "$R_TOK_PASS" == "true" ]] && p="true" || p="false"
    fi
  elif (( R_HP_EN )); then
    p="$R_HP_PASS"
  elif (( R_TOK_EN )); then
    p="$R_TOK_PASS"
  else
    p="true"   # no sub-gate for this account -> vacuously passes
  fi
  [[ "$p" == "true" ]] && return 0 || return 1
}

# ───── per-candidate processing ─────────────────────────────────────────────
total=0
passed=0
rejected=0
errors=0

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  total=$((total + 1))

  hive_account=$(echo "$line" | jq -r '.hive_account // ""')
  domain=$(echo "$line"       | jq -r '.domain // ""')
  escrow_acct=$(echo "$line"  | jq -r '.escrow // ""')
  ident="@$hive_account/$domain"

  # ── split-account mode (Stage 3.7 Part A) ────────────────────────────────
  if (( SPLIT_MODE )); then
    [[ -z "$escrow_acct" ]] && { log "REJECT $ident — no escrow account in candidate (split mode)"; rejected=$((rejected+1)); continue; }

    e_rc=0
    eval_account "$escrow_acct" "$ESCROW_MIN_HP" "$ESCROW_MIN_TOKEN_SYMBOL" "$ESCROW_MIN_TOKEN_AMOUNT" || e_rc=$?
    e_hp_en=$R_HP_EN; e_tok_en=$R_TOK_EN; e_hp_v=$R_HP_VAL; e_tok_v=$R_TOK_VAL; e_hp_p=$R_HP_PASS; e_tok_p=$R_TOK_PASS
    if (( e_rc == 2 )); then
      log "ERROR $ident (escrow @$escrow_acct) — RPC failure; not passing"
      errors=$((errors+1)); rejected=$((rejected+1)); continue
    fi
    [[ $e_rc -eq 0 ]] && e_pass="true" || e_pass="false"

    h_rc=0
    eval_account "$hive_account" "$HIVE_MIN_HP" "$HIVE_MIN_TOKEN_SYMBOL" "$HIVE_MIN_TOKEN_AMOUNT" || h_rc=$?
    h_hp_en=$R_HP_EN; h_tok_en=$R_TOK_EN; h_hp_v=$R_HP_VAL; h_tok_v=$R_TOK_VAL; h_hp_p=$R_HP_PASS; h_tok_p=$R_TOK_PASS
    if (( h_rc == 2 )); then
      log "ERROR $ident (hive @$hive_account) — RPC failure; not passing"
      errors=$((errors+1)); rejected=$((rejected+1)); continue
    fi
    [[ $h_rc -eq 0 ]] && h_pass="true" || h_pass="false"

    if [[ "$ACCOUNT_MODE" == "or" ]]; then
      [[ "$e_pass" == "true" || "$h_pass" == "true" ]] && pass="true" || pass="false"
    else
      [[ "$e_pass" == "true" && "$h_pass" == "true" ]] && pass="true" || pass="false"
    fi

    e_det="escrow@$escrow_acct["
    (( e_hp_en )) && e_det+="hp=$e_hp_v/$ESCROW_MIN_HP:$e_hp_p "
    (( e_tok_en )) && e_det+="$ESCROW_MIN_TOKEN_SYMBOL=$e_tok_v/$ESCROW_MIN_TOKEN_AMOUNT:$e_tok_p "
    (( e_hp_en==0 && e_tok_en==0 )) && e_det+="nogate "
    e_det="${e_det% }]=$e_pass"
    h_det="hive@$hive_account["
    (( h_hp_en )) && h_det+="hp=$h_hp_v/$HIVE_MIN_HP:$h_hp_p "
    (( h_tok_en )) && h_det+="$HIVE_MIN_TOKEN_SYMBOL=$h_tok_v/$HIVE_MIN_TOKEN_AMOUNT:$h_tok_p "
    (( h_hp_en==0 && h_tok_en==0 )) && h_det+="nogate "
    h_det="${h_det% }]=$h_pass"

    if [[ "$pass" != "true" ]]; then
      log "REJECT $ident (split $ACCOUNT_MODE) — $e_det $h_det"
      rejected=$((rejected+1)); continue
    fi

    pv='[]'
    [[ "$e_hp_p"  == "true" ]] && pv=$(echo "$pv" | jq -c '. + ["escrow:hp"]')
    [[ "$e_tok_p" == "true" ]] && pv=$(echo "$pv" | jq -c '. + ["escrow:token"]')
    [[ "$h_hp_p"  == "true" ]] && pv=$(echo "$pv" | jq -c '. + ["hive:hp"]')
    [[ "$h_tok_p" == "true" ]] && pv=$(echo "$pv" | jq -c '. + ["hive:token"]')

    echo "$line" | jq -c \
      --argjson gate_passed_via "$pv" \
      --arg gate_mode "split-$ACCOUNT_MODE" \
      --arg e_hp "$e_hp_v" --arg e_tok "$e_tok_v" --arg e_tok_sym "$ESCROW_MIN_TOKEN_SYMBOL" \
      --arg h_hp "$h_hp_v" --arg h_tok "$h_tok_v" --arg h_tok_sym "$HIVE_MIN_TOKEN_SYMBOL" \
      '. + {
        gate_pass: true,
        gate_account: "escrow+hive",
        gate_mode: $gate_mode,
        gate_passed_via: $gate_passed_via,
        gate_split: {
          escrow: { hp: ($e_hp | tonumber? // null), token: ($e_tok | tonumber? // null), token_symbol: $e_tok_sym },
          hive:   { hp: ($h_hp | tonumber? // null), token: ($h_tok | tonumber? // null), token_symbol: $h_tok_sym }
        }
      }'

    passed=$((passed+1))
    log "OK $ident (split $ACCOUNT_MODE) — $e_det $h_det"
    continue
  fi

  # which account to gate on
  if [[ "$GATE_ACCOUNT" == "escrow" ]]; then
    gate_acct="$escrow_acct"
    [[ -z "$gate_acct" ]] && { log "REJECT $ident — no escrow account in candidate"; rejected=$((rejected+1)); continue; }
  else
    gate_acct="$hive_account"
  fi
  ident_full="$ident (gate→@$gate_acct)"

  hp_pass="false"
  hp_value=""
  token_pass="false"
  token_value=""

  if (( hp_enabled )); then
    if hp_value=$(fetch_hp "$gate_acct"); then
      ge "$hp_value" "$MIN_HP" && hp_pass="true" || hp_pass="false"
    else
      log "ERROR $ident_full — HP fetch failed (transient Hive RPC); not passing"
      errors=$((errors+1))
      rejected=$((rejected+1))
      continue
    fi
  fi

  if (( token_enabled )); then
    if token_value=$(fetch_token_balance "$gate_acct" "$MIN_TOKEN_SYMBOL"); then
      ge "$token_value" "$MIN_TOKEN_AMOUNT" && token_pass="true" || token_pass="false"
    else
      log "ERROR $ident_full — token fetch failed (transient Hive-Engine RPC); not passing"
      errors=$((errors+1))
      rejected=$((rejected+1))
      continue
    fi
  fi

  # Combine
  if (( hp_enabled && token_enabled )); then
    if [[ "$GATE_MODE" == "or" ]]; then
      [[ "$hp_pass" == "true" || "$token_pass" == "true" ]] && pass="true" || pass="false"
    else
      [[ "$hp_pass" == "true" && "$token_pass" == "true" ]] && pass="true" || pass="false"
    fi
  elif (( hp_enabled )); then
    pass="$hp_pass"
  elif (( token_enabled )); then
    pass="$token_pass"
  else
    pass="true"   # no gates → everyone passes
  fi

  if [[ "$pass" != "true" ]]; then
    msg="REJECT $ident_full — gate failed (mode=$GATE_MODE)"
    (( hp_enabled ))    && msg+=" hp=$hp_value/$MIN_HP=$hp_pass"
    (( token_enabled )) && msg+=" $MIN_TOKEN_SYMBOL=$token_value/$MIN_TOKEN_AMOUNT=$token_pass"
    log "$msg"
    rejected=$((rejected+1))
    continue
  fi

  # Build passed_via JSON array
  passed_via='[]'
  [[ "$hp_pass"    == "true" ]] && passed_via=$(echo "$passed_via" | jq -c '. + ["hp"]')
  [[ "$token_pass" == "true" ]] && passed_via=$(echo "$passed_via" | jq -c '. + ["token"]')
  (( hp_enabled == 0 && token_enabled == 0 )) && passed_via='["nogate"]'

  # Emit augmented candidate
  echo "$line" | jq -c \
    --arg gate_account     "$gate_acct" \
    --arg gate_mode        "$GATE_MODE" \
    --argjson gate_passed_via "$passed_via" \
    --arg gate_hp          "$hp_value" \
    --arg gate_token       "$token_value" \
    --arg gate_token_symbol "$MIN_TOKEN_SYMBOL" \
    '. + {
      gate_pass: true,
      gate_account: $gate_account,
      gate_mode: $gate_mode,
      gate_passed_via: $gate_passed_via,
      gate_hp: ($gate_hp | tonumber? // null),
      gate_token: ($gate_token | tonumber? // null),
      gate_token_symbol: $gate_token_symbol
    }'

  passed=$((passed+1))
  msg="OK $ident_full — passed via $(echo "$passed_via" | jq -r '. | join("+")')"
  (( hp_enabled ))    && msg+=" hp=$hp_value"
  (( token_enabled )) && msg+=" $MIN_TOKEN_SYMBOL=$token_value"
  log "$msg"
done

log "complete — total=$total passed=$passed rejected=$rejected errors=$errors"

if (( errors > 0 )); then
  exit 2
fi
