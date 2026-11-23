#!/usr/bin/env bash
# Fail the job, naming the real cause, when the runner did not get onto the tailnet.
#
#   Run:  bash .github/scripts/tailnet-verify-joined.sh   (right after tailscale/github-action)
#
# Why: tailscale/github-action@v3 retries `tailscale up` five times and ends its loop on a
# `sleep`, so a rejected auth key still leaves the step green. In run 44922555470 every
# attempt logged `invalid key: API key does not exist`, and the job only failed ten minutes
# later, in a step that blamed the droplet ("zimmer-staging never came online on the
# tailnet"). This checks the runner's own login state instead: BackendState must be
# Running. Anything else -- NeedsLogin above all -- is the runner's credential, not the
# droplet, and the error says so.
#
# Env:
#   TS_VERIFY_ATTEMPTS   polls, 2s apart, before giving up (default 15)
set -euo pipefail

attempts="${TS_VERIFY_ATTEMPTS:-15}"
case "$attempts" in
  ''|*[!0-9]*|0) echo "::error::TS_VERIFY_ATTEMPTS must be a positive whole number, got '$attempts'"; exit 2 ;;
esac

state="unknown"
for i in $(seq 1 "$attempts"); do
  json=$(tailscale status --json 2>/dev/null || true)
  state=$(jq -r '.BackendState // "unknown"' <<<"$json" 2>/dev/null || echo unknown)
  if [ "$state" = "Running" ]; then
    self=$(jq -r '"\(.Self.HostName // "?") \(.Self.TailscaleIPs[0] // "?") tags=\((.Self.Tags // []) | join(","))"' <<<"$json")
    echo "✅ runner is on the tailnet: $self"
    exit 0
  fi
  [ "$i" -lt "$attempts" ] && sleep 2
done

case "$state" in
  NeedsLogin)
    cause="the runner never authenticated: Tailscale rejected its auth key (see the Tailscale step's log, e.g. 'invalid key: API key does not exist'). The droplet is not the problem. Check the TS_CI_OAUTH_CLIENT_ID / TS_CI_OAUTH_CLIENT_SECRET secrets, or the TS_CI_AUTHKEY fallback if the mint step warned it was used." ;;
  NeedsMachineAuth)
    cause="the runner joined but its node is waiting for admin approval: the auth key was not pre-authorized." ;;
  *)
    cause="tailscaled reports BackendState '$state' rather than Running." ;;
esac
echo "::error title=Runner is not on the tailnet::$cause"
tailscale status 2>&1 | sed 's/^/  /' || true
exit 1
