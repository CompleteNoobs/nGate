# STATUS.md — nGate Current State

**As of 2026-05-13.** Snapshot of what's done, what's open, what's planned.
Read [CLAUDE.md](CLAUDE.md) first for project context.

## What's shipped

### nGate scripts (5/5 phases complete)

| Phase | Script | State | Notes |
|-------|--------|-------|-------|
| 3.1 — Discovery   | `scripts/ngate-scan.sh`   | ✅ ready | Reads Hive `v4call-server` posts, emits NDJSON candidates incl. `nostr_attestation_b64` |
| 3.2 — Verification | `scripts/ngate-verify.sh` + 2 Node helpers | ✅ ready | Verifies Hive sig + Nostr attestation + tag cross-checks. **Requires attestation when Nostr key declared.** |
| 3.3 — Gating      | `scripts/ngate-gate.sh`   | ✅ ready | HP / token thresholds, escrow- or hive_account-target, OR/AND mode |
| 3.4 — Rewriter    | `scripts/ngate-apply.sh`  | ✅ ready | `--dry-run` default, atomic config.toml writes, BEGIN/END markers, 3-strike miss tolerance, restart cap, sanity bound |
| 3.5 — Sync loop   | `scripts/ngate-sync.sh` + sidecar Dockerfile + `ngate.yaml.example` + `docker-compose.example.yml` | ✅ ready | YAML config, PIPESTATUS-aware `--allow-removals`, mikefarah/yq in Alpine image |
| (operator helper) | `scripts/ngate-status.sh` | ✅ ready | Read-only "what's nGate doing?" summary |

### Browser-side attestation pages (in `/home/noob/CAI/v4call/public/`)

| File | State | What it produces |
|------|-------|------------------|
| `nostr-gen.html` | ✅ fixed in another thread | Generates Nostr keypairs (was buggy; now uses nostr-tools instead of hand-rolled bigint math) |
| `server-sign.html` | ✅ ready (Option B canonical) | Signed `v4call-server.json` with `nostr_attestation` field |
| `rate-editor.html` | ✅ ready | `[V4CALL-RATES-V2]` body with embedded base64 attestation line |
| `server-announce.html` | ✅ ready (paste-card bug fixed 2026-05-13) | Hive `v4call-server` post body with embedded base64 attestation line, plus posting-key-paste fallback for in-page Hive broadcast via dhive |

### Documentation

| File | State |
|------|-------|
| `nGate-auto-whitelist.wiki` | ✅ 18 lessons across 5 phases (the main stage-3 walkthrough) |
| `v4call-server-data-flow.wiki` | ✅ side-quest reference (3 accounts + 1 domain confusion-clearing doc) |
| `nostr-relay-with-whitelist.wiki` | ✅ stage 1 (relay deploy guide) |
| `nostr-handson.wiki` + `nostr-handson.html` | ✅ stage 2 (Nostr protocol learning) |
| `walkthrough.wiki` | ✅ NEW — Ubuntu 24.04 deployment guide |
| `CLAUDE.md` / `STATUS.md` / `README.md` | ✅ NEW — project context |

## What's locked in (design decisions)

- ✅ Mutual cryptographic attestation, required from the start (no soft-warn for missing attestations).
- ✅ Option B for Hive canonical payload: signature covers 9-or-12 fields, **not** attestation.id. Backward-compat with v4call's existing federation verify code.
- ✅ ADD-only on partial upstream failure.
- ✅ 3-strike miss tolerance before removal (configurable via `NGATE_MAX_CONSECUTIVE_MISSES`).
- ✅ Restart cap (default 6/day) + sanity bound (refuse to empty whitelist on bad input).
- ✅ seed.toml for operator's always-allowed keys.
- ✅ BEGIN/END markers in config.toml for the nGate-managed zone.

See [CLAUDE.md](CLAUDE.md#locked-in-design-decisions-read-before-changing-anything) for full rationale on each.

## Known bugs / open issues

### Re-sign + re-announce pending for existing operators

All three v4call-server announces currently on Hive (cnoobs, v4call,
hive-book) were either:
- Pre-Nostr (no attestation at all), OR
- Signed under the OLD canonical payload extension (Option A — included
  attestation.id in the Hive sig)

After the Option B revert, the user needs to re-sign + re-announce each
operator before nGate-verify will accept them. **In flight.** Once done,
the scan|verify chain should produce three green OKs.

### Re-deploy to live relays pending

The fixed nostr-rs-relay sidecar setup (with the nGate scripts) hasn't been
deployed to the live nostr.hive-book.com or nostr.v4call.com yet.
**User is about to upload to GitHub and pull on the Ubuntu server.** The
walkthrough.wiki covers this.

## Pending operator action (the user's queue)

1. **Re-sign** each operator's `v4call-server.json` in the updated
   server-sign.html (post Option B).
2. **Re-deploy** the new well-known to each operator's HTTPS server.
3. **Re-announce** on Hive via server-announce.html (paste the signed JSON
   → load fields → broadcast via Keychain OR the new posting-key fallback).
4. **Deploy nGate sidecar** to nostr.hive-book.com (and later
   nostr.v4call.com) following the walkthrough.wiki.
5. **First live `ngate-sync` run** — watch logs, confirm three OKs.

## Next session priorities (when the user comes back)

In rough priority:

1. **Live deployment verification** — once nGate is running on the real
   nostr.hive-book.com sidecar, watch a 24-hour cycle, fix anything weird.
2. **Wiki / data-flow doc updates** — reflect Option B + the attestation
   flow + the new posting-key fallback in server-announce. Currently the
   wikis describe the EXTENDED canonical (Option A); needs reconciliation.
3. **Stage 3.6 refinements** (after live deployment is stable):
   - NIP-11 publication ("I am an nGated relay").
   - Hot YAML reload via SIGHUP (avoid sidecar restart on config change).
   - HTTP health endpoint at `:7070/status` for Prometheus / monitoring.
   - Rejection log Nostr events — nGate publishes its own kind-30000-range
     "rejected because X" events for transparency.
4. **Stage 3.7 — Economic subscription / per-account-pair gate** (designed
   2026-05-15, not built — see design block below). User wants this before
   committing to Stage 4 strfry.
5. **Stage 4** — strfry migration. Live policy plugin replaces
   config.toml-rewrite-and-restart loop. The nGate phase scripts carry
   over almost unchanged; only the apply phase swaps backend.
5. **Stage 5** — user-tier nGate. Same architecture, different scan target
   (v4call-rates instead of v4call-server) and d-tag scope
   (`v4call-user-cross-attestation`).

## Stage 3.7 design — Economic subscription / per-account-pair gate

**Status: designed 2026-05-15, NOT built. Captured before strfry pivot.**

User request: richer gating than today's single-account snapshot. Two parts.

### Part A — independent conditions on escrow AND hive_account ✅ BUILT 2026-05-15

Today `ngate-gate.sh` evaluates ONE account (`gate.account: escrow|hive_account`)
with HP/token thresholds combined by `mode: or|and`. The verify phase already
resolves BOTH accounts onto each candidate. Generalise the gate to evaluate
*independent sub-conditions per account* then combine, e.g.:
`escrow: min_hp 300` **AND** `hive_account: fee_paid`. Natural extension of the
existing `mode` logic; low architectural risk. New `ngate.yaml` shape would
nest conditions under `escrow:` / `hive_account:` keys instead of a single
flat `gate:` block (keep the flat form working for back-compat).

### Part B — prorated subscription fee / burn gate (moderate; token sub-case risky)

Model: a candidate's `hive_account` qualifies if it has paid an ongoing fee to
a configured payment account (e.g. `v4call` collecting $1 HBD/month), prorated:
$0.30 HBD -> ~10 days of whitelist. Also support burn-to-`@null` (sum what the
account sent to null). Must support custom tokens (CNOOBS), not just HBD.

Design decisions / constraints surfaced in the 2026-05-15 discussion:

- **Memo convention is mandatory.** Payments must carry an identifying memo
  (relay domain or candidate npub) so a payment can be attributed to a
  candidate, and so one payment account can serve multiple relays. Without it,
  attribution is impossible. Needs spec'ing (e.g. `ngate:<domain>` or the hex
  pubkey in the transfer memo).
- **Recompute from chain each cycle - do NOT cache entitlement.** Keep nGate's
  "Hive is source of truth, recompute" philosophy. Expiry =
  `last_payment_time + (total_paid / daily_rate)`. Surviving a wiped state.json
  matters more than the extra RC of a history scan per cycle.
- **HBD/HIVE (layer-1): reliable.** `account_history_api` gives trustworthy
  incoming-transfer history for the payment account (and for `@null` burns,
  the sender's outgoing history filtered to `to=null`).
- **Custom tokens: the genuine risk.** A token *subscription* needs cumulative
  *sent* history. This is exactly the Hive-Engine `transferHistory` API that
  v4call's locked-in design decision #5 abandoned as unreliable (v4call uses
  balance snapshots instead). Two realistic paths:
  - (a) ship HBD/HIVE fee first; flag token-fee "best-effort / may regress".
  - (b) for tokens, gate on a *held balance* ("hold >= X CNOOBS") rather than
    *cumulative paid* - reliable, but it's a stake gate, not a recurring fee
    (no proration; different economics). Arguably the safer token model;
    worth pitching to the user as the token variant.
- **Burn-to-null** is the same code path with recipient `@null`; identical
  layer-1-fine / token-risky split.
- **Scope:** this breaks the stateless point-in-time model of `ngate-gate.sh`
  (introduces time-based expiry + a history scan). Bigger than the Stage 3.6
  refinements - justified as its own stage. The history scan is a new external
  RPC surface; apply the existing multi-node-fallback + log-every-RPC-error
  conventions (CLAUDE.md coding conventions) to it.

New `ngate.yaml` fields (sketch, not final): `payment_account`,
`fee_amount`, `fee_period_days`, `fee_currency`, `memo_pattern`,
`allow_burn`, `burn_min`, plus per-account condition nesting from Part A.

Open questions before building: exact memo grammar; overpayment / multiple
partial payments (sum vs. last-wins); whether escrow-HP + hive_account-fee is
AND-only or operator-configurable; token model (a) vs (b).

## Recent meaningful changes (last few sessions)

- **2026-05-17**: README.md gained a full "Configuration reference — every
  flag, what it does" section: pipeline-stage flag placement, complete env
  var / YAML tables for scan + gate (flat Mode A + split Mode B) + apply,
  the split-account command annotated line-by-line, everyday recipes, and
  the "check the `config:` stderr line / redeploy if you see flat" tip.
  Written for the operator who doesn't run this daily.
- **2026-05-15**: Stage 3.7 **Part A shipped** — split-account gate. New
  `eval_account()` helper + split branch in `ngate-gate.sh`; env vars
  `NGATE_ACCOUNT_MODE` + `NGATE_{ESCROW,HIVE}_MIN_{HP,TOKEN_SYMBOL,TOKEN_AMOUNT}`.
  Auto-triggers when any split var is set; flat single-account path
  unchanged (verified identical output). Threaded through `ngate-sync.sh`
  (nested `gate.escrow.*` / `gate.hive_account.*` / `gate.account_mode`
  YAML) + documented in `ngate.yaml.example`. Live-tested against
  @v4call/@hive-book: AND-pass, AND-reject, OR-pass, flat back-compat all
  correct. Part B (prorated fee / burn) still NOT built — deferred per
  user. Next: strfry (Stage 4).
- **2026-05-15**: Added "Host-mode silent no-op" gotcha to CLAUDE.md
  (the 4-hour `/app/...` path + swallowed-stderr debugging session).

- **2026-05-13**: server-announce.html attestation-validator bug fixed —
  the paste-card load path now correctly persists `loadedAttestation` for
  the validate/post step. Operator paste → load → broadcast flow works
  end-to-end without falling back to the manual Copy/Download path.
- **2026-05-13**: Option B applied — server-sign.html's `buildPayload` no
  longer appends `nostr_attestation.id` to the Hive canonical. ngate-verify
  was already at SHORT canonical; alignment restored.
- **2026-05-13**: Added posting-key fallback to server-announce.html (dhive
  in-page broadcast for when Keychain is buggy/missing).
- **2026-05-13**: nGate-verify enforcement shipped — requires + validates
  the Nostr attestation when nostr_pubkey_hex declared. Drops the now-
  redundant within-scan collision rejection (cryptographic attestation
  makes it unnecessary; logged as WARN only).
- **2026-05-13**: Added `nostr-tools` to scripts/package.json. New ESM
  helper `lib/ngate-verify-nostr-event.mjs` for Nostr event verification.
- **2026-05-13**: ngate-scan extracts the `NOSTR-ATTESTATION:` line from
  Hive post bodies; emits `nostr_attestation_b64` in candidate NDJSON.
- **2026-05-13**: server-announce.html got the PASTE SIGNED JSON card —
  operator pastes their server-sign output, fields auto-populate,
  attestation is verified + embedded in the Hive post body as base64 line.
- **2026-05-12**: rate-editor.html got the attestation flow (kind-30078
  with `v4call-user-cross-attestation` d-tag scope).
- **2026-05-12**: server-sign.html got the attestation flow (NIP-07
  preferred, nsec paste fallback).
- **2026-05-11**: Phase 3.5 (ngate-sync.sh + Dockerfile + ngate-status.sh +
  ngate.yaml.example) shipped.

## Quick sanity tests

Run from `/home/noob/CAI/nGate`:

```sh
# Phase 3.1 alone — read-only, hits Hive
./scripts/ngate-scan.sh --limit 5

# Phases 3.1 + 3.2 — currently REJECTS the live operators because they
# haven't been re-signed for Option B yet. After re-sign + re-announce,
# these should all pass.
./scripts/ngate-scan.sh 2>/dev/null | ./scripts/ngate-verify.sh 2>&1 | grep -E "OK|REJECT|skip"

# Full chain with HP+token gate
./scripts/ngate-scan.sh 2>/dev/null \
  | ./scripts/ngate-verify.sh 2>/dev/null \
  | NGATE_GATE_ACCOUNT=hive_account NGATE_MIN_TOKEN_SYMBOL=CNOOBS NGATE_MIN_TOKEN_AMOUNT=0.1 \
    ./scripts/ngate-gate.sh \
  | ./scripts/ngate-apply.sh   # --dry-run by default; add --apply to actually write
```

## Repo state

About to be uploaded to GitHub (separate repo from the v4call repo at
`/home/noob/CAI/v4call/`). nGate becomes its own project. The browser pages
in `v4call/public/` stay with the v4call repo (they're v4call operator
tools that generate JSONs nGate happens to consume).
