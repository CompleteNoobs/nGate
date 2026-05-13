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
| `server-announce.html` | ⚠ has a known bug — see below | Hive `v4call-server` post body with embedded base64 attestation line, plus posting-key-paste fallback for in-page Hive broadcast via dhive |

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

### 🐛 server-announce attestation-validator triggering when shouldn't

**Symptom**: After pasting a signed `v4call-server.json` into the purple
"PASTE SIGNED v4call-server.json" card and clicking Load fields, the
publish step still throws:

```
Nostr key declared but no attestation loaded.
Paste your signed v4call-server.json at the top, OR clear all Nostr fields
to announce without Nostr-discovery.
```

**Where**: `/home/noob/CAI/v4call/public/server-announce.html`, in
`validate()` — the `(f.nostr_npub || f.nostr_hex) && !f.nostr_attestation`
check is firing despite `loadedAttestation` having been populated by
`loadFromJson()`.

**Likely cause** (not yet investigated): scoping or timing — `collect()`
reads `loadedAttestation` from module scope; `loadFromJson()` sets it; but
something in between (maybe `updatePreview` running first, or a state-reset
on an unrelated input event) clears it before `postToHive` / `postWithKey`
fires.

**User's call**: "do not edit server-announce.html" for now. Tracked here
for future fix. Operator can work around by using the manual Copy/Download
fallback or by ensuring the paste-card's Load fields button is clicked
immediately before clicking Post.

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

1. **Fix the server-announce attestation-validator bug** — first thing
   when user is ready, since it blocks the broadcast step today.
2. **Live deployment verification** — once nGate is running on the real
   nostr.hive-book.com sidecar, watch a 24-hour cycle, fix anything weird.
3. **Wiki / data-flow doc updates** — reflect Option B + the attestation
   flow + the new posting-key fallback in server-announce. Currently the
   wikis describe the EXTENDED canonical (Option A); needs reconciliation.
4. **Stage 3.6 refinements** (after live deployment is stable):
   - NIP-11 publication ("I am an nGated relay").
   - Hot YAML reload via SIGHUP (avoid sidecar restart on config change).
   - HTTP health endpoint at `:7070/status` for Prometheus / monitoring.
   - Rejection log Nostr events — nGate publishes its own kind-30000-range
     "rejected because X" events for transparency.
5. **Stage 4** — strfry migration. Live policy plugin replaces
   config.toml-rewrite-and-restart loop. The nGate phase scripts carry
   over almost unchanged; only the apply phase swaps backend.
6. **Stage 5** — user-tier nGate. Same architecture, different scan target
   (v4call-rates instead of v4call-server) and d-tag scope
   (`v4call-user-cross-attestation`).

## Recent meaningful changes (last few sessions)

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
