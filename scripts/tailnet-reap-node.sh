#!/usr/bin/env bash
# Delete every Tailscale device whose OS hostname matches $1 (e.g. "zimmer-staging").
#
# Why: the deploy destroys + recreates the droplet on each run (ephemeral tfstate).
# The destroyed droplet's tailnet node lingers holding the name, so the fresh droplet
# registers as "<name>-1", "<name>-2", ... and the stable MagicDNS name drifts.
# Deleting the stale node(s) first lets the new droplet reclaim the clean name.
#
# No-op (exit 0) when TS_API_CLIENT_ID / TS_API_CLIENT_SECRET are unset, so deploys
# keep working before the Tailscale OAuth client is configured. Requires an OAuth
# client with the "devices" scope (read + write).
set -euo pipefail

HOST="${1:?usage: tailnet-reap-node.sh <hostname>}"

if [ -z "${TS_API_CLIENT_ID:-}" ] || [ -z "${TS_API_CLIENT_SECRET:-}" ]; then
  echo "TS_API_CLIENT_ID/SECRET unset; skipping stale tailnet-node cleanup for '${HOST}'."
  echo "(Set a Tailscale OAuth client with the 'devices' scope to keep MagicDNS names stable.)"
  exit 0
fi

# `|| true`: a failed token exchange (invalid/expired creds) must NOT abort the step
# under `set -e` -- the empty-token check below turns it into a graceful skip.
TOKEN=$(curl -fsS "https://api.tailscale.com/api/v2/oauth/token" \
  -d "client_id=${TS_API_CLIENT_ID}" \
  -d "client_secret=${TS_API_CLIENT_SECRET}" 2>/dev/null | jq -r '.access_token // empty') || true
if [ -z "${TOKEN}" ]; then
  echo "::warning::Tailscale OAuth token exchange failed; skipping stale-node cleanup for '${HOST}'."
  exit 0
fi

ids=$(curl -fsS -H "Authorization: Bearer ${TOKEN}" \
  "https://api.tailscale.com/api/v2/tailnet/-/devices" 2>/dev/null \
  | jq -r --arg h "${HOST}" '.devices[]? | select(.hostname == $h) | .id') || true

if [ -z "${ids}" ]; then
  echo "No existing tailnet node named '${HOST}'."
  exit 0
fi

for id in ${ids}; do
  echo "deleting stale tailnet node ${id} (${HOST})"
  curl -fsS -X DELETE -H "Authorization: Bearer ${TOKEN}" \
    "https://api.tailscale.com/api/v2/device/${id}" >/dev/null \
    || echo "::warning::failed to delete tailnet node ${id}"
done
