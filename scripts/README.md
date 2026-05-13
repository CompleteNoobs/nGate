# nGate scripts

This folder holds the bash scripts that make up nGate — the auto-whitelist gate
for a Nostr relay, driven by Hive `v4call-server` posts.

See **[nGate-auto-whitelist.wiki](../nGate-auto-whitelist.wiki)** for the full
walkthrough. The scripts in this folder are meant to be read alongside the
wiki — each phase = one script + one lesson.

## Phase status

| Phase | Script | Status | Read-only? |
|-------|--------|--------|------------|
| 3.1 — discovery   | `ngate-scan.sh`   | ✅ ready | yes |
| 3.2 — verification | `ngate-verify.sh` + `lib/ngate-verify-sig.js` | ✅ ready | yes |
| 3.3 — gating      | `ngate-gate.sh`   | ✅ ready | yes |
| 3.4 — rewriter    | `ngate-apply.sh`  | ✅ ready | no (defaults to `--dry-run`) |
| 3.5 — sync loop   | `ngate-sync.sh` + `ngate-status.sh` + `Dockerfile` + `../ngate.yaml.example` | ✅ ready | runs the full chain on a self-paced loop |

## Quick start

```sh
# Phase 3.1 alone (read-only Hive discovery, NDJSON to stdout)
./ngate-scan.sh                    # default: 20 candidates from Hive
./ngate-scan.sh --limit 5          # smaller sample
./ngate-scan.sh --help             # full usage

# Phase 3.1 + 3.2 chain (discovery + signature verification)
./ngate-scan.sh | ./ngate-verify.sh

# Pretty-print, drop progress logs
./ngate-scan.sh 2>/dev/null | ./ngate-verify.sh 2>/dev/null | jq .
```

Stdout is NDJSON (one JSON object per line). Stderr is human-readable progress
and error messages. Pipeable end-to-end.

## Dependencies

| Phase | Needs |
|-------|-------|
| 3.1 | `bash 4+`, `curl`, `jq`, `sed`, `awk` |
| 3.2 | all of 3.1 + `node` + `@hiveio/dhive` (run `npm install` here once) |
| 3.3 | all of 3.1 (no new deps) |
| 3.4 | all of 3.1 + `mktemp` |
| 3.5 | all of 3.1–3.4 + `yq` (kislyuk or mikefarah). Inside Docker: also `docker-cli` + `tini` |

Check shell-side dependencies:

```sh
for c in bash curl jq sed awk node; do command -v $c >/dev/null && echo "✓ $c" || echo "✗ $c MISSING"; done
```

Install the Node helper's npm dep:

```sh
cd nGate/scripts
npm install
```

macOS users may need `brew install jq node`. On Ubuntu 24.04: `sudo apt install -y nodejs npm jq`.
Inside the eventual `ngate-sync` sidecar container we'll install everything explicitly — Alpine
ships none of it by default.

## Convention

Every script:
- reads stdin or a config file, never asks for interactive input
- writes data to stdout, progress / errors to stderr
- exits 0 on success, 1 on hard failure, 2 on bad arguments
- supports `--help`
- write-side scripts default to `--dry-run` and require `--apply` to actually change state

Pure Unix-pipe-friendly. `./ngate-scan.sh | ./ngate-verify.sh | ./ngate-gate.sh | ./ngate-apply.sh` is the eventual full chain.
