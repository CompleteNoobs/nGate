# nGate

Automated whitelist gate for a Nostr relay, driven by Hive blockchain announces.

nGate scans Hive every N hours for `v4call-server` posts, cryptographically
verifies the announcer (Hive signature + Nostr key attestation), applies
operator-defined economic gating (HP / token holdings), and updates the
relay's `pubkey_whitelist` accordingly. Built as a Docker sidecar that runs
alongside [nostr-rs-relay](https://github.com/scsibug/nostr-rs-relay).

The mission: turn a Nostr relay's whitelist from "operator hand-edits 3 hex
strings" into "operators announce themselves on Hive with cryptographic proof
of ownership, the relay picks them up automatically subject to the operator's
chosen economic conditions."

## Quick start (for a new contributor)

1. Read [CLAUDE.md](CLAUDE.md) — project context + locked-in design decisions.
2. Read [STATUS.md](STATUS.md) — what's shipped, what's open, what's next.
3. Skim [nGate-auto-whitelist.wiki](nGate-auto-whitelist.wiki) — 18-lesson
   walkthrough of how each phase works, with smoke tests.
4. For deployment to a fresh Ubuntu 24.04 server (the most common path),
   follow [walkthrough.wiki](walkthrough.wiki).

## Quick start (for an operator with a running relay)

You already have nostr-rs-relay running from the
[stage-1 wiki](nostr-relay-with-whitelist.wiki). Add nGate:

```sh
# On the relay box, in /opt/nostr-relay/
cd /opt/nostr-relay

# Clone the nGate repo
git clone https://github.com/CompleteNoobs/nGate scripts-src
cp -r scripts-src/scripts ./scripts
cp    scripts-src/ngate.yaml.example ./ngate.yaml
cp    scripts-src/docker-compose.example.yml /tmp/  # use as reference

# Install dependencies inside scripts/
cd scripts && npm install && cd ..

# Bootstrap your existing config.toml (wraps [authorization] in markers)
./scripts/ngate-apply.sh --bootstrap

# Add your own pubkey to the seed list so you don't lock yourself out
echo "YOUR_OWN_HEX_PUBKEY" > seed.toml

# Customise the config
vi ngate.yaml   # set instance_name, gate.min_hp, etc.

# Dry-run the chain to confirm before going live
./scripts/ngate-scan.sh 2>/dev/null \
  | ./scripts/ngate-verify.sh 2>/dev/null \
  | ./scripts/ngate-gate.sh 2>/dev/null \
  | ./scripts/ngate-apply.sh     # --dry-run default
```

If the dry-run output looks right, add the sidecar service to your
existing `docker-compose.yml` (see `docker-compose.example.yml`) and:

```sh
docker compose build ngate-sync
docker compose up -d ngate-sync
docker compose logs -f ngate-sync
```

Full deployment walkthrough: [walkthrough.wiki](walkthrough.wiki).

## Configuration reference — every flag, what it does

> If you don't run this every day it's easy to forget the basics. This is the
> complete list. Two ways to configure: **env vars** on the relevant pipeline
> stage (for manual runs / testing), or the **ngate.yaml** file (for the
> sidecar loop). They map 1:1 — the YAML keys just feed the same env vars.

### Where flags attach in the pipeline

The pipeline is four stages. **A flag only works on the stage that reads it.**
This is the #1 footgun:

```
ngate-scan.sh  →  ngate-verify.sh  →  ngate-gate.sh  →  ngate-apply.sh
  --limit N         (no flags)        ALL gate vars      --apply etc.
```

`NGATE_MIN_HP=3 ./ngate-scan.sh | ./ngate-verify.sh | ./ngate-gate.sh` does
**NOT** work — the var attaches to `scan`, not `gate`. Put gate vars
immediately before `./ngate-gate.sh`:

```sh
./ngate-scan.sh | ./ngate-verify.sh \
  | NGATE_MIN_HP=3 ./ngate-gate.sh \
  | ./ngate-apply.sh
```

(In `ngate.yaml` / sidecar mode this is handled for you — `ngate-sync.sh`
puts each var on the right stage.)

### Stage 1 — `ngate-scan.sh` (Hive discovery)

| Flag | Values | Default | What it does |
|------|--------|---------|--------------|
| `--limit N` | 1–20 | 20 | How many recent `v4call-server` Hive posts to scan. Capped at 20 (Hive node hard limit on `get_discussions_by_created`). |

### Stage 3 — `ngate-gate.sh` (the economic gate)

This is where almost all the knobs are. There are **two modes**:

#### Mode A — flat single-account (the original, default)

Gates on **one** account (escrow OR hive_account) with an HP check and/or a
token check.

| Env var | YAML key (`gate.`) | Values | Default | What it does |
|---------|--------------------|--------|---------|--------------|
| `NGATE_GATE_ACCOUNT` | `account` | `escrow` \| `hive_account` | `escrow` | Which account on each announce to check. `escrow` = the operational escrow account (solvency proxy); `hive_account` = the announce-signing Hive account. |
| `NGATE_MIN_HP` | `min_hp` | number | `0` | Minimum Hive Power. `0` = HP gate **disabled**. |
| `NGATE_INCLUDE_DELEGATED_HP` | `include_delegated_hp` | `true` \| `false` | `false` | `false` = owned HP only (whale can't rent privileges via delegation). `true` = owned **+ received/delegated-in** HP. Delegated-*out* is never subtracted (you still own it). |
| `NGATE_MIN_TOKEN_SYMBOL` | `min_token_symbol` | e.g. `CNOOBS` | empty | Hive-Engine token to check. Empty = token gate **disabled**. Must be exact uppercase symbol. |
| `NGATE_MIN_TOKEN_AMOUNT` | `min_token_amount` | number | `0` | Minimum balance of that token. |
| `NGATE_INCLUDE_STAKED_TOKEN` | `include_staked_token` | `true` \| `false` | `true` | `true` = liquid balance **+ staked** counts. `false` = liquid only. |
| `NGATE_GATE_MODE` | `mode` | `or` \| `and` | `or` | Only matters when **both** HP and token gates are set. `or` = pass either. `and` = must pass both. |
| `NGATE_DEBUG` | (via `verbose: true`) | `1` \| `0` | `0` | `1` = print per-account HP/token math on stderr. |

If neither HP nor token gate is set → **every verified candidate passes**
(with a `WARN` on stderr). Useful for testing the scan/verify chain alone.

#### Mode B — split-account (Stage 3.7 Part A)

Evaluate **independent conditions on the escrow account AND the
hive_account**, then combine. **Auto-enabled** the moment you set *any* of the
six split vars below — you don't toggle it explicitly.

| Env var | YAML key | Values | Default | What it does |
|---------|----------|--------|---------|--------------|
| `NGATE_ACCOUNT_MODE` | `gate.account_mode` | `or` \| `and` | `and` | How the **escrow result** and the **hive_account result** combine. |
| `NGATE_ESCROW_MIN_HP` | `gate.escrow.min_hp` | number | `0` | Min HP on the escrow account. `0` = no HP sub-gate for escrow. |
| `NGATE_ESCROW_MIN_TOKEN_SYMBOL` | `gate.escrow.min_token_symbol` | e.g. `CNOOBS` | empty | Token to check on escrow. Empty = no token sub-gate for escrow. |
| `NGATE_ESCROW_MIN_TOKEN_AMOUNT` | `gate.escrow.min_token_amount` | number | `0` | Min balance of that token on escrow. |
| `NGATE_HIVE_MIN_HP` | `gate.hive_account.min_hp` | number | `0` | Min HP on the hive_account. |
| `NGATE_HIVE_MIN_TOKEN_SYMBOL` | `gate.hive_account.min_token_symbol` | e.g. `CNOOBS` | empty | Token to check on hive_account. |
| `NGATE_HIVE_MIN_TOKEN_AMOUNT` | `gate.hive_account.min_token_amount` | number | `0` | Min balance of that token on hive_account. |

Shared with Mode A, still apply in split mode:

- `NGATE_INCLUDE_DELEGATED_HP` — **global** (applies to *both* the escrow and
  hive HP checks; there is no per-account version).
- `NGATE_INCLUDE_STAKED_TOKEN` — global, same as above.
- `NGATE_GATE_MODE` — here it's the **intra-account** combine (how HP vs token
  combine *within* one account). `NGATE_ACCOUNT_MODE` is the **inter-account**
  combine. Two different knobs.

**Vacuous-pass warning:** an account with no sub-gate configured passes
automatically. With `NGATE_ACCOUNT_MODE=or` that means *everything passes* (one
empty side is always true). Use `and`, or configure both sides, when using
`or`. The script logs a `WARN` if it detects this.

### Stage 4 — `ngate-apply.sh` (writes config.toml + restarts relay)

| Flag / env | YAML key | Default | What it does |
|------------|----------|---------|--------------|
| `--dry-run` | — | **default** | Print what *would* change. Touches nothing. |
| `--apply` | — | off | Actually rewrite config.toml + restart relay if the whitelist changed. |
| `--allow-removals` | — | off | Permit removing entries that no longer pass. Without it, **add-only** (transient Hive outage can't nuke your whitelist). `ngate-sync.sh` adds this automatically only when every upstream stage exited clean. |
| `--bootstrap` | — | — | One-time: wrap your existing `[authorization]` block in the `BEGIN/END NGATE-MANAGED` markers. Run once on a fresh relay config.toml. |
| `NGATE_CONFIG_PATH` | `paths.config_toml` | `/opt/nostr-relay/config.toml` | Relay config to rewrite. |
| `NGATE_SEED_PATH` | `paths.seed_toml` | `/opt/nostr-relay/seed.toml` | Operator's always-allowed pubkeys (one hex/line, `#` comments). **Never auto-removed. Put your own key here before first `--apply` or you can lock yourself out.** |
| `NGATE_STATE_PATH` | `paths.state_json` | `/opt/nostr-relay/ngate-state.json` | Miss-counter state across runs. **Manual pipeline default is `ngate-state.json`; if your `ngate.yaml` points `paths.state_json` somewhere else they diverge** — keep them the same file. |
| `NGATE_RESTART_CMD` | `restart_command` | `docker compose -f /opt/nostr-relay/docker-compose.yml restart nostr-relay` | How to restart the relay after a whitelist change. |
| `NGATE_MAX_CONSECUTIVE_MISSES` | `max_consecutive_failures` | `3` | A whitelisted key must be MISSING this many clean cycles before removal. At 6h cycles, `3` ≈ 18h grace. |
| `NGATE_MAX_RESTARTS_PER_DAY` | `max_restarts_per_day` | `6` | Cap on relay restarts/24h. config.toml still updates; only the restart is capped. |

`ngate-apply.sh` exit codes: `0` ok · `1` config.toml missing/markers absent
(run `--bootstrap`) · `2` bad args · `3` restart cap hit · `4` sanity bound
(refused to empty the whitelist on suspicious input).

### Worked example — the split-account command, line by line

```sh
./scripts/ngate-scan.sh | ./scripts/ngate-verify.sh \
  | NGATE_ESCROW_MIN_HP=300 \           # escrow account must hold >=300 HP
    NGATE_INCLUDE_DELEGATED_HP=true \   # count delegated-in HP toward that 300
    NGATE_HIVE_MIN_TOKEN_SYMBOL=CNOOBS \# hive_account must hold the CNOOBS token
    NGATE_HIVE_MIN_TOKEN_AMOUNT=4 \     # at least 4 CNOOBS
    NGATE_ACCOUNT_MODE=and \            # BOTH sides must pass (escrow AND hive)
    ./scripts/ngate-gate.sh \
  | ./scripts/ngate-apply.sh --apply --allow-removals
```

Reads: *"Whitelist an announce only if its escrow account holds ≥300 HP
(delegated-in HP counts) **and** its Hive account holds ≥4 CNOOBS."* Setting
any `NGATE_ESCROW_*`/`NGATE_HIVE_*` var is what flips it into split mode; the
flat `NGATE_GATE_ACCOUNT`/`NGATE_MIN_*` vars are ignored while in split mode.

Same thing in `ngate.yaml`:

```yaml
gate:
  include_delegated_hp: true
  account_mode: and
  escrow:
    min_hp: 300
  hive_account:
    min_token_symbol: CNOOBS
    min_token_amount: 4
```

### More everyday recipes

```sh
# Just see who's announcing (no gate) — sanity-check scan+verify
./scripts/ngate-scan.sh | ./scripts/ngate-verify.sh | ./scripts/ngate-gate.sh

# Flat: escrow must hold >=300 HP, nothing else
... | NGATE_MIN_HP=300 ./scripts/ngate-gate.sh | ...

# Flat: hive_account must hold >=4 CNOOBS (switch which account)
... | NGATE_GATE_ACCOUNT=hive_account NGATE_MIN_TOKEN_SYMBOL=CNOOBS \
      NGATE_MIN_TOKEN_AMOUNT=4 ./scripts/ngate-gate.sh | ...

# Flat: pass if EITHER >=300 HP OR >=4 CNOOBS (same account)
... | NGATE_MIN_HP=300 NGATE_MIN_TOKEN_SYMBOL=CNOOBS \
      NGATE_MIN_TOKEN_AMOUNT=4 NGATE_GATE_MODE=or ./scripts/ngate-gate.sh | ...

# Preview only — never writes (default), explicit for clarity
... | ./scripts/ngate-gate.sh | ./scripts/ngate-apply.sh --dry-run

# Go live, allow removing entries that no longer qualify
... | ./scripts/ngate-gate.sh | ./scripts/ngate-apply.sh --apply --allow-removals
```

**Tip:** the first `ngate-gate: config:` line on stderr always echoes the mode
and thresholds in effect — check it to confirm the flags landed where you
meant. Split mode prints `config: SPLIT-ACCOUNT mode ...`; flat mode prints
`config: account=... mode=...`. If you set split vars but see the flat line,
you're running an old copy of `ngate-gate.sh` (redeploy).

## What this repo contains

```
nGate/
├── CLAUDE.md, STATUS.md, README.md     ← project context + state + this file
├── walkthrough.wiki                    ← Ubuntu 24.04 deployment guide
├── nGate-auto-whitelist.wiki           ← architecture walkthrough (18 lessons)
├── v4call-server-data-flow.wiki        ← "which value goes in which field?" reference
├── ngate.yaml.example                  ← operator config template
├── docker-compose.example.yml          ← 3-service stack (relay + caddy + ngate-sync)
├── nostr-relay-with-whitelist.wiki     ← stage 1 (relay deploy guide)
├── nostr-handson.html / .wiki          ← stage 2 (Nostr protocol learning tool)
├── NOSTR-DESIGN.md / -NOTES.md         ← original design rationale
└── scripts/
    ├── ngate-scan.sh                   ← phase 3.1: Hive → candidates (NDJSON)
    ├── ngate-verify.sh                 ← phase 3.2: well-known + Hive sig + Nostr attestation
    ├── ngate-gate.sh                   ← phase 3.3: HP / token gate
    ├── ngate-apply.sh                  ← phase 3.4: config.toml rewriter + restart
    ├── ngate-sync.sh                   ← phase 3.5: self-paced loop wrapper
    ├── ngate-status.sh                 ← operator helper
    ├── Dockerfile                      ← sidecar image
    ├── package.json                    ← node deps (dhive + nostr-tools)
    └── lib/
        ├── ngate-verify-sig.js         ← Hive ECDSA helper (CJS)
        └── ngate-verify-nostr-event.mjs ← Nostr schnorr helper (ESM)
```

## Dependencies

### To run the scripts on a Linux box

- bash 4+
- curl, jq, sed, awk (standard on Ubuntu)
- Node 18+ (`apt install nodejs npm`)
- `cd scripts && npm install` (installs @hiveio/dhive + nostr-tools)
- For phase 3.5 sidecar: Docker + docker-compose-plugin + mikefarah/yq
  (auto-installed into the sidecar image)

Quick check:
```sh
for c in bash curl jq sed awk node; do
  command -v $c >/dev/null && echo "✓ $c" || echo "✗ $c MISSING"
done
```

### Browser pages it depends on

The pages that *produce* the JSONs nGate consumes live in the v4call repo
at `public/`. They're independent operator tools, browser-only crypto, never
talk to nGate directly:

- `nostr-gen.html` — generate Nostr keypairs (browser-only, never leaves
  the page)
- `server-sign.html` — sign `.well-known/v4call-server.json` (Hive sig +
  Nostr attestation)
- `server-announce.html` — publish the `v4call-server` Hive post (with
  Keychain OR posting-key paste fallback)
- `rate-editor.html` — user-tier rates posts (with attestation)

These ship with v4call, not nGate. The nGate scripts read what they produce
without caring how they were generated.

## License

MIT, same as v4call.

## Author / project

Part of the [v4call](https://github.com/CompleteNoobs/v4call) ecosystem.
Project home: https://completenoobs.com — operator-friendly walkthroughs
for federated Hive infrastructure.
