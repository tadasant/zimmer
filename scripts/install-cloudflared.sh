#!/usr/bin/env bash
# Run (or update) the OPTIONAL Cloudflare Tunnel connector on a host, and prove it is
# connected. Off unless the caller passes a token: with CLOUDFLARE_TUNNEL_TOKEN empty this
# changes nothing on the host.
#
# What it runs: `cloudflared tunnel run` for a REMOTELY-MANAGED tunnel (ingress rules live in
# the Cloudflare dashboard, not on the box), as the pinned cloudflare/cloudflared image with
# --network host and restart: unless-stopped -- the same shape as the host Caddy. It makes
# OUTBOUND connections only. The DigitalOcean firewall stays at zero public TCP ingress and
# nothing here touches it.
#
# The origin the tunnel's public hostname should point at is http://localhost:8080 --
# kamal-proxy, not Caddy. See docs/operate/deploying.md#optional-cloudflare-edge for why
# (short version: Caddy replaces X-Forwarded-For, kamal-proxy appends to it, and Rails'
# remote_ip needs the edge's entry to survive).
#
# Why a converge script rather than cloud-init or a Terraform variable:
#
#   1. cloud-init runs ONCE, at first boot, under `ignore_changes = [user_data]`, so it never
#      reaches a droplet that already exists -- which is every droplet that matters. Same
#      reasoning, and the same shape, as scripts/install-worker-watchdog.sh.
#   2. The token must NOT be in user_data. user_data is readable from the DigitalOcean
#      metadata service by every process on the box, agent sessions included, and a tunnel
#      token lets whoever holds it run a second connector for the same tunnel -- one that
#      Cloudflare load-balances real, already-authenticated requests onto. Delivered here, it
#      travels over SSH stdin into a root-owned directory that no app container mounts.
#
# Convergent: re-running with the same token and image is a no-op that leaves the running
# tunnel alone (a restart drops in-flight requests). A new token, or a bumped image pin
# below, recreates the container on the next deploy -- which is how an existing droplet is
# updated.
#
# Inputs (environment):
#   CLOUDFLARE_TUNNEL_TOKEN        the tunnel token from the Cloudflare dashboard. Empty = no-op.
#   ZIMMER_CLOUDFLARED_REMOVE=1    with an empty token, REMOVE the connector and its token
#                                  instead. The only way this script ever takes a tunnel down.
#   ZIMMER_CLOUDFLARED_SSH_EXTRA   extra ssh arguments, e.g. "-F <config>" -- same seam, same
#                                  rules, as ZIMMER_WATCHDOG_SSH_EXTRA in install-worker-watchdog.sh.
#   ZIMMER_CLOUDFLARED_WAIT        seconds to wait for a registered connection (default 90).
#   ZIMMER_CLOUDFLARED_DIR         host directory for the token (default /etc/zimmer/cloudflared).
#                                  Never a path an app container mounts.
#
# Usage: install-cloudflared.sh <tailnet-host-or-ip>
set -euo pipefail

HOST="${1:?usage: install-cloudflared.sh <tailnet-host-or-ip>}"

# PINNED, not latest. Bump the tag here and the next deploy recreates the connector on it.
IMAGE="cloudflare/cloudflared:2026.10.0"
NAME="zimmer-cloudflared"
# Outside /opt/zimmer on purpose: production bind-mounts subdirectories of /opt/zimmer into
# the app containers, and the token must never be one mount away from an agent session.
TOKEN_DIR="${ZIMMER_CLOUDFLARED_DIR:-/etc/zimmer/cloudflared}"
# The image runs as nonroot (65532:65532), so the token file belongs to that uid, mode 0400.
CLOUDFLARED_UID="65532"

TOKEN="${CLOUDFLARE_TUNNEL_TOKEN:-}"
REMOVE="${ZIMMER_CLOUDFLARED_REMOVE:-}"
WAIT="${ZIMMER_CLOUDFLARED_WAIT:-90}"

case "$WAIT" in
  '' | *[!0-9]*) echo "::error::ZIMMER_CLOUDFLARED_WAIT must be a whole number of seconds (got '${WAIT}')"; exit 2 ;;
esac

SSH_OPTS=()
if [ -n "${ZIMMER_CLOUDFLARED_SSH_EXTRA:-}" ]; then
  read -r -a SSH_OPTS <<<"${ZIMMER_CLOUDFLARED_SSH_EXTRA}"
fi
SSH_OPTS+=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=15
  -o ServerAliveInterval=10
  -o ServerAliveCountMax=3
)

# `run` forwards this script's stdin (how the token gets there); `run_q` closes it.
# shellcheck disable=SC2029  # each caller passes a single remote command string on purpose.
run() { ssh "${SSH_OPTS[@]}" "root@${HOST}" "$@"; }
run_q() { ssh -n "${SSH_OPTS[@]}" "root@${HOST}" "$@"; }

if [ -z "$TOKEN" ]; then
  if [ "$REMOVE" = "1" ]; then
    echo "Removing the Cloudflare Tunnel connector from ${HOST}"
    run_q "docker rm -f ${NAME} >/dev/null 2>&1; rm -rf ${TOKEN_DIR}"
    echo "Removed. The tunnel's public hostname now has no connector and serves Cloudflare's 1033 error."
  else
    echo "CLOUDFLARE_TUNNEL_TOKEN is empty: the Cloudflare edge is not configured for ${HOST}; changing nothing."
    if run_q "docker inspect ${NAME} >/dev/null 2>&1"; then
      echo "::warning::${NAME} is running on ${HOST} but this deploy passed no token. Left as is; set ZIMMER_CLOUDFLARED_REMOVE=1 to take it down."
    fi
  fi
  exit 0
fi

# A tunnel token is base64 of a small JSON document. Refusing anything else keeps a pasted
# shell fragment or a stray newline out of the file cloudflared reads.
if ! [[ "$TOKEN" =~ ^[A-Za-z0-9+/_=-]+$ ]]; then
  echo "::error::CLOUDFLARE_TUNNEL_TOKEN does not look like a tunnel token (expected base64, no whitespace)"
  exit 2
fi

# The container carries a hash of (image, token) as a label: equal label + running means
# converged, and nothing is restarted. A hash, never the token -- `docker inspect` output
# ends up in deploy logs.
SPEC="$(printf '%s\n%s\n' "$IMAGE" "$TOKEN" | sha256sum | cut -c1-16)"

current="$(run_q "docker inspect -f '{{index .Config.Labels \"zimmer.cloudflared.spec\"}} {{.State.Running}}' ${NAME} 2>/dev/null || true")"

if [ "$current" = "${SPEC} true" ]; then
  echo "${NAME} on ${HOST} is already running ${IMAGE} with this token; leaving it alone."
else
  echo "Converging ${NAME} on ${HOST} to ${IMAGE} (was: ${current:-absent})"

  # Pull BEFORE removing the old container, so a registry hiccup fails the deploy with the
  # previous connector still serving instead of with no connector at all.
  run_q "docker pull -q ${IMAGE} >/dev/null"

  # Temp-and-move so cloudflared never reads half a token.
  printf '%s' "$TOKEN" | run "install -d -m 0755 ${TOKEN_DIR} && install -m 0400 -o ${CLOUDFLARED_UID} -g ${CLOUDFLARED_UID} /dev/stdin ${TOKEN_DIR}/.token.new && mv -f ${TOKEN_DIR}/.token.new ${TOKEN_DIR}/token"

  run_q "docker rm -f ${NAME} >/dev/null 2>&1 || true"
  run_q "docker run -d --name ${NAME} --restart unless-stopped --network host \
    --label zimmer.cloudflared.spec=${SPEC} \
    --log-opt max-size=10m --log-opt max-file=3 \
    -v ${TOKEN_DIR}:${TOKEN_DIR}:ro \
    ${IMAGE} tunnel run --token-file ${TOKEN_DIR}/token >/dev/null"
fi

# Prove it, every run: a connector that started but never registered is a tunnel that serves
# Cloudflare's 1033 error page, and a green deploy must not hide that. --since bounds the
# search to this container's lifetime, so an old success line cannot vouch for a new failure.
echo "Waiting up to ${WAIT}s for ${NAME} to register a tunnel connection"
deadline=$((SECONDS + WAIT))
while :; do
  started="$(run_q "docker inspect -f '{{.State.StartedAt}}' ${NAME}")"
  if run_q "docker logs --since '${started}' ${NAME} 2>&1 | grep -q 'Registered tunnel connection'"; then
    echo "${NAME} is connected:"
    run_q "docker logs --since '${started}' ${NAME} 2>&1 | grep 'Registered tunnel connection' | tail -4" || true
    exit 0
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "::error::${NAME} on ${HOST} registered no tunnel connection within ${WAIT}s"
    run_q "docker ps -a --filter name=${NAME} --format '{{.Names}}\t{{.Status}}'; docker logs --tail 30 ${NAME} 2>&1" || true
    exit 1
  fi
  sleep 5
done
