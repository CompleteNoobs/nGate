# CLAUDE.md — nGate Project Context

> Brief for an AI assistant picking this project up cold. Read this first, then
> [STATUS.md](STATUS.md) for current state, then [walkthrough.wiki](walkthrough.wiki)
> for deployment specifics.

## What nGate is

**nGate** is an automated gate for a Nostr relay's `pubkey_whitelist`, driven
by `v4call-server` posts on the Hive blockchain. It scans Hive every N hours,
extracts candidate Nostr pubkeys from announce posts, verifies cryptographic
proofs (Hive signature + Nostr attestation), applies on-chain economic gating
(HP / token holdings), and rewrites the relay's `config.toml` accordingly. The
relay restarts only when the whitelist actually changes.

The mission: turn "whitelist a Nostr relay" from "operator hand-edits 3 hex
strings in a config file" into "operators announce themselves on Hive with
cryptographic proof, the relay picks them up automatically subject to
configurable economic conditions." Federation-discovery infrastructure for
v4call's planned Nostr layer, but built as a standalone primitive that's
useful for any Nostr-relay operator who wants an on-chain gate.

## The v4call ecosystem context

v4call is a decentralised paid video/voice/text platform on Hive that the user
runs alongside this work. nGate is the federation-discovery side of v4call's
upcoming Nostr layer (planned v0.18.5+). The full picture:

- **v4call server** (Node.js, in `/home/noob/CAI/v4call/`) — the actual call
  server. Has rates, escrow, federation handshakes, etc.
- **Browser pages** (in `/home/noob/CAI/v4call/public/`):
  - `nostr-gen.html` — generates Nostr keypairs (browser-only, never leaves
    the page). **Had a bigint math bug that produced wrong npubs for some
    privkeys; fixed in a separate thread by replacing the hand-rolled
    secp256k1 with nostr-tools.**
  - `server-sign.html` — signs `/.well-known/v4call-server.json` with Hive
    posting key + embeds a kind-30078 Nostr attestation. **Canonical payload
    was extended to include attestation.id, then reverted to Option B
    (excludes it) for backward-compat with v4call's existing federation
    handshake code — see "Locked-in design decisions" below.**
  - `server-announce.html` — publishes the `v4call-server` directory post on
    Hive. Paste-signed-JSON workflow extracts fields + attestation from a
    server-sign output. **Currently has a bug ("Nostr key declared but no
    attestation loaded" misfiring even when the paste card was used) — see
    STATUS.md.**
  - `rate-editor.html` — generates `[V4CALL-RATES-V2]` body for user-tier
    rates posts. Embeds a kind-30078 Nostr attestation (different d-tag from
    server-tier).
- **The Hive blockchain** — source of truth for: who's running a v4call server
  (`v4call-server` tag), who's a v4call user (`v4call-rates` title), what's
  signed by which Hive account (consensus signature on every post + the
  signed v4call-server.json file).
- **nGate** (this dir) — bridges Hive announces → Nostr relay whitelist.

## Architecture

Five phases pipelined with stdin/stdout NDJSON:

```
HIVE (truth)                              NOSTR RELAY (enforces)
   │                                              ▲
   │ ngate-scan.sh                                │ ngate-apply.sh writes
   ▼                                              │ config.toml + restarts
[candidates JSON]                              [config.toml whitelist]
   │                                              ▲
   │ ngate-verify.sh                              │
   ▼                                              │
[verified+attested]                               │
   │                                              │
   │ ngate-gate.sh (env-var thresholds)           │
   ▼                                              │
[passed gate]                                     │
   │                                              │
   └─► ngate-apply.sh ────────────────────────────┘

Plus: ngate-sync.sh wraps all four in a self-paced loop (sidecar mode).
       ngate-status.sh = read-only operator helper.
```

Each phase is one bash script. Crypto operations shell out to small Node
helpers (Hive ECDSA via `@hiveio/dhive`, Nostr schnorr via `nostr-tools`).

## File map

```
nGate/
├── CLAUDE.md                        ← you are here
├── STATUS.md                        ← current state + open work
├── README.md                        ← human quick-start
├── walkthrough.wiki                 ← deployment to fresh Ubuntu 24.04 box
├── nGate-auto-whitelist.wiki        ← original stage-3 walkthrough (18 lessons across phases)
├── v4call-server-data-flow.wiki     ← side-quest: which value goes in which field
├── ngate.yaml.example               ← operator config template
├── docker-compose.example.yml       ← 3-service stack (relay + caddy + ngate-sync)
├── nostr-relay-with-whitelist.wiki  ← stage 1 (relay deploy guide)
├── nostr-handson.html               ← stage 2 (bare-metal Nostr learning tool)
├── nostr-handson.wiki               ← stage 2 walkthrough
├── NOSTR-DESIGN.md                  ← original Nostr design notes (high-level)
├── NOSTR-DESIGN-NOTES.md            ← further design rationale
└── scripts/
    ├── README.md                    ← phase-status table + quick-start commands
    ├── ngate-scan.sh                ← phase 3.1: Hive → candidates
    ├── ngate-verify.sh              ← phase 3.2: well-known + Hive sig + Nostr attestation
    ├── ngate-gate.sh                ← phase 3.3: HP/token gate
    ├── ngate-apply.sh               ← phase 3.4: config.toml rewriter + restart
    ├── ngate-sync.sh                ← phase 3.5: loop wrapper
    ├── ngate-status.sh              ← operator status helper
    ├── Dockerfile                   ← sidecar image
    ├── package.json                 ← npm deps (dhive + nostr-tools)
    ├── .gitignore                   ← keeps node_modules/ out of git
    └── lib/
        ├── ngate-verify-sig.js      ← Hive ECDSA verifier (Node, CJS)
        └── ngate-verify-nostr-event.mjs ← Nostr event verifier (Node, ESM)
```

## Tech stack

- **bash 4+** — all orchestration scripts
- **jq** — JSON manipulation, NDJSON pipelines
- **curl** — Hive RPC + Hive-Engine RPC
- **awk + sed** — parsing post bodies
- **Node 18+** (CJS + ESM) — for crypto helpers (Hive via @hiveio/dhive, Nostr
  via nostr-tools — same version 2.7.2 as the browser pages use via esm.sh)
- **mikefarah/yq** — YAML parsing in `ngate-sync.sh` (sidecar pulls this from
  GitHub release; on dev laptops the apt `yq` package — Python-based wrapping
  jq — also works since the queries we use are simple `.field // default`)
- **Docker + docker-compose** — sidecar deployment alongside relay + Caddy
- **nostr-rs-relay** — the relay nGate writes to. Hot-reload not supported, so
  config.toml writes are paired with `docker restart nostr-relay`. (Future
  stage 4: migrate to strfry for live policy plugin gating without restarts.)

## Coding conventions

Adopted across all 5 nGate scripts:
- **Reads stdin / writes stdout NDJSON** (one JSON object per line). Stderr
  for human-readable progress / errors. Pipe-friendly composability.
- **Defaults to read-only** — write-side scripts (only `ngate-apply.sh`)
  default to `--dry-run`; need explicit `--apply` to touch anything.
- **Exit codes**: 0 = success, 1 = hard failure, 2 = bad args / missing deps,
  3 = restart cap hit, 4 = sanity bound triggered.
- **Multi-node fallback for every external RPC call** — Hive RPC rotates
  through 4 nodes (`api.hive.blog`, `api.deathwing.me`, `hive-api.arcange.eu`,
  `api.openhive.network`). Hive-Engine RPC rotates through 3.
- **Diagnostic logging** — every external call logs HTTP status and JSON-RPC
  errors on stderr. Lesson from v4call's v0.12 fix: never silently swallow
  RPC errors.
- **Caching is in-memory per script run** — no cross-run persistence (yet).
  State.json from phase 3.4 tracks miss counters across runs but not RPC
  response caches.

## Locked-in design decisions (read before changing anything)

1. **Mutual cryptographic attestation, required from the start.**
   - Hive signature on the well-known proves: this Hive account controls
     this domain.
   - Nostr signature on the embedded `nostr_attestation` (kind 30078) proves:
     this Nostr key holder consents to being bound to that Hive
     account+domain.
   - Tag cross-check during verify (`v4call_hive_account` and `v4call_domain`
     tags on the attestation must match the well-known's fields) closes the
     loop. Forger needs BOTH the Hive posting key AND the Nostr private
     key — not feasible.
   - **No legacy / unattested compat** — any post that declares a Nostr key
     but lacks a valid attestation is rejected. User explicitly chose this
     over a soft-warn path: "we are in dev stages, no need for legacy compat,
     bake security in from the start."

2. **Option B for the Hive canonical payload.**
   - The Hive signature covers the 9-field (no-Nostr) or 12-field (Nostr
     trailer: npub, hex, relays_csv) payload — **NOT** the attestation.id.
   - Reason: backward-compat with v4call's existing federation handshake
     code in `/home/noob/CAI/v4call/server.js`. Extending the canonical
     payload to include attestation.id breaks v4call's verify.
   - Security is preserved because the attestation is self-verifying via
     its own NIP-01 id + schnorr sig, AND the tag cross-check binds it to
     the surrounding fields. The only attack class lost: same-key version-
     swap, which isn't a meaningful attack (same identity either way).

3. **ADD-only on partial failure.**
   - If any phase in the pipeline exits non-zero (e.g. Hive RPC partially
     unreachable), `ngate-sync` does NOT pass `--allow-removals` to
     `ngate-apply`. Existing whitelist entries are preserved; only new
     additions are processed. Prevents transient outages from nuking the
     federation.

4. **3-strike miss tolerance before removal.**
   - A whitelisted entry must be MISSING for `NGATE_MAX_CONSECUTIVE_MISSES`
     (default 3) consecutive clean cycles before becoming eligible for
     removal. With the default 6-hour scan interval, this means ~18 hours
     of absence before kick. Cushions Hive post churn.

5. **Restart cap (default 6/day) + sanity bound.**
   - `ngate-apply` refuses to restart the relay container more than
     `NGATE_MAX_RESTARTS_PER_DAY` times in 24h. Config.toml is still
     written; just no restart.
   - Sanity bound: refuses to apply if upstream produced ZERO passing
     candidates AND every non-seed entry would be removed. Catches
     misclassified outages.

6. **seed.toml for operator's always-allowed keys.**
   - Operator-managed file (`/opt/nostr-relay/seed.toml`), one hex pubkey
     per line, `#` for comments. Never auto-removed by nGate. Critical:
     **add the operator's own key here before first `--apply` or you'll
     lock yourself out** if the operator's identity isn't yet on a
     v4call-server post.

7. **BEGIN/END markers in config.toml.**
   - `ngate-apply` only modifies lines between the literal comment markers
     `# === BEGIN NGATE-MANAGED — DO NOT EDIT BY HAND ===` and
     `# === END NGATE-MANAGED ===`. Operator's other config (relay name,
     port, retention, etc.) stays untouched.
   - **First-time setup**: run `ngate-apply.sh --bootstrap` against an
     existing nostr-rs-relay config.toml to wrap its `[authorization]`
     section in those markers.

8. **Convergence across relays, not synchronisation.**
   - Each nGate instance runs independently. Two relays with their own
     nGate sidecars eventually agree on the whitelist (both reading the
     same Hive chain), but there's no relay-to-relay gossip. Stagger their
     scan times for faster federation-wide pickup.

## Known gotchas

- **bash `set -u` trips on empty associative arrays** in bash 4.x. The
  current scripts use `set -eo pipefail` (no `-u`). Don't add `-u` without
  testing.
- **TOML parser tolerates leading whitespace** on section headers; bash
  regexes don't unless explicitly written. `ngate-apply.sh --bootstrap`
  handles this by using `^[[:space:]]*\[authorization\]`.
- **UID mismatch on bind-mounted SQLite DB** is the #1 fresh-deploy gotcha
  for nostr-rs-relay (not nGate per se). Container runs as `appuser`
  (non-root); `./data/` dir on host is root-owned by default. Fix:
  `chmod -R 777 /opt/nostr-relay/data` (acceptable for a single-purpose
  box of public events). See stage 1 wiki Step 13 for the full story.
- **Env-var placement in pipelines**:
  `MIN_HP=3 ./scan.sh | ./verify.sh | ./gate.sh` does NOT do what you
  expect — `MIN_HP=3` attaches to scan, not gate. Either put env-vars on
  the specific command (`./scan.sh | ./verify.sh | NGATE_MIN_HP=3 ./gate.sh`)
  or use `export` first.
- **nostr-tools v2 is ESM-only** when used in Node — the helper at
  `lib/ngate-verify-nostr-event.mjs` uses `.mjs` extension so Node treats it
  as ESM regardless of `package.json` `"type"` field. Don't rename to `.js`
  without also adding `"type": "module"` or wrapping in `import()`.
- **server-announce attestation bug** — see STATUS.md for details. Triggers
  even when the paste card successfully loaded the attestation; user wants
  it noted but not fixed yet (they're focusing on other things first).

## What to NOT do

- **Don't extend the Hive canonical payload to include attestation.id again** —
  that's Option A which we reverted. Breaks v4call's existing federation
  verify code.
- **Don't add a soft-warn path for missing attestations** — required from
  the start, per locked-in decision #1.
- **Don't blow away seed.toml on apply** — only the BEGIN/END managed block
  gets rewritten; seed.toml stays operator-managed.
- **Don't hand-edit config.toml between the BEGIN/END markers** — nGate
  overwrites that region on next sync. Use seed.toml for manual additions.
- **Don't split helper scripts into a `bin/` directory or rename them** —
  the file layout is referenced by docker-compose.example.yml bind-mounts.

## What's still ahead

(Track current status in [STATUS.md](STATUS.md).)

- **Stage 3.6** — small refinements: NIP-11 publication, hot YAML reload,
  HTTP health endpoint.
- **Stage 4** — strfry migration. Live policy plugin replaces the
  config.toml-rewrite-and-restart loop.
- **Stage 5** — user-tier nGate. Same architecture, scans v4call-rates
  instead of v4call-server, different d-tag scope. Separate relay tier from
  federation-tier.
- **Stage 6+** — v4call uses nGate-published Nostr events as primary
  federation discovery (Hive posts remain as cryptographic anchor).

## Stylistic notes for the assistant

- **Mediawiki-flavoured wikis** — the existing wikis use mediawiki syntax
  (`==headers==`, `[[links]]`, `{|wikitables|}`). Match that style if you
  add new wikis.
- **Verbose comments in scripts** — every script has a comment block at top
  explaining usage, dependencies, exit codes. Maintain this when adding
  features.
- **No emoji in code or wiki body** unless the user explicitly asked (they
  asked for them in operator-facing UI buttons like "🔑 Sign Nostr
  Attestation"; otherwise keep prose plain).
- **Test against real Hive data**, not just synthetic — the user has live
  posts at @cnoobs, @v4call, @hive-book. Smoke-testing pipelines against
  these is part of every feature build.
- **Don't proactively refactor** — the user prefers incremental, testable
  edits over rewrites.
