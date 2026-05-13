# ─────────────────────────────────────────────────────────────────────
# nGate sidecar image — Phase 3.5
# ─────────────────────────────────────────────────────────────────────
# Runs the four ngate scripts on a self-paced loop alongside the relay
# + Caddy containers. Mounts:
#   - /app/scripts     (bind mount, source of all .sh + lib/*.js)
#   - /app/ngate.yaml  (operator config)
#   - /app/seed.toml   (operator-managed always-allowed pubkeys)
#   - /app/config.toml (relay's pubkey_whitelist — read AND write)
#   - /app/state.json  (machine-managed state — read AND write)
#   - /var/run/docker.sock (so the restart_command can talk to the host's
#     docker daemon and restart the nostr-relay sibling container)
#
# Build:    docker compose build ngate-sync
# Run:      docker compose up -d ngate-sync
# Logs:     docker compose logs -f ngate-sync
# Status:   docker compose exec ngate-sync /app/scripts/ngate-status.sh

FROM node:20-alpine

# Install runtime tools the bash scripts need.
# - bash: scripts assume bash, not /bin/sh
# - curl + jq: used everywhere
# - docker-cli: for the restart command (talks to host docker.sock)
# - tini: proper PID 1 for graceful SIGTERM handling
RUN apk add --no-cache bash curl jq docker-cli tini

# mikefarah/yq — single Go binary, more reliable than apk's Python-based one.
# Pinned version so behaviour is stable; bump when you want to update.
ADD --chmod=755 https://github.com/mikefarah/yq/releases/download/v4.40.5/yq_linux_amd64 /usr/local/bin/yq

WORKDIR /app

# Scripts come from the bind mount (so operator edits are picked up on
# `docker compose restart ngate-sync` without rebuilding). On first start
# the entrypoint runs `npm install` if node_modules/ is missing in the
# bind-mount target.
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/bin/bash", "-c", "\
  set -e; \
  if [ ! -d /app/scripts/node_modules/@hiveio ]; then \
    echo '[ngate-sync] installing @hiveio/dhive (first run)...'; \
    cd /app/scripts && npm install --omit=dev --silent; \
  fi; \
  exec /app/scripts/ngate-sync.sh \
"]
