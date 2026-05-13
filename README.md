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
