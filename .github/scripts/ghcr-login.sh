#!/usr/bin/env bash
# Log in to a container registry, retrying a transient failure instead of failing the run.
#
# release-image.yml already treats registry I/O as flaky for the PUSH half -- three build
# attempts with an escalating backoff between them -- but the login that precedes it was
# single-shot, so one bad handshake against the same registry took the whole release down:
#
#   Error response from daemon: Get "https://ghcr.io/v2/": Get "https://ghcr.io/token?...":
#   net/http: TLS handshake timeout
#
# Nothing was wrong with the commit, the image, or the credentials. This closes that
# asymmetry: the same registry, the same class of transient failure, retried in both places.
#
# The retry is BLIND, for the reason await-ghcr.sh spells out: the GHCR trouble that keeps
# breaking this workflow has already worn several HTTP shapes (403 on a blob, 404 on a
# manifest, 403 on a push HEAD, and now a TLS timeout with no HTTP status at all), so gating
# on an error signature would trade a rare wasted retry for a missed one. A login is cheap;
# a missed release is not.
#
# What is NOT retried is a credential that was never supplied -- an empty password is a
# configuration fault, not a hiccup, and three attempts at it only delay the diagnosis.
set -uo pipefail

REGISTRY="${REGISTRY:-ghcr.io}"
: "${REGISTRY_USERNAME:?REGISTRY_USERNAME must be set}"
: "${REGISTRY_PASSWORD:?REGISTRY_PASSWORD must be set (an empty token cannot be retried into working)}"

# Whitespace-separated waits BETWEEN attempts, so the attempt count is one more than the
# number of backoffs. Defaults mirror the push chain's 90s/240s: the escalation is there
# because a GHCR secondary rate limit is account-wide and has outlasted a single 90s wait,
# and it is only ever paid on a run that is already failing.
read -r -a BACKOFFS <<<"${LOGIN_BACKOFF_SECONDS:-90 240}"
TOTAL=$(( ${#BACKOFFS[@]} + 1 ))

# Registry output is untrusted text; a line starting with `::` would otherwise be parsed as
# a workflow command. Fence it, the same way await-ghcr.sh does.
FENCE="ghcr-login-$$"

attempt=1
while :; do
  # --password-stdin so the token never reaches a command line or the process table. The
  # daemon's own error text is captured rather than streamed, so it can be fenced below.
  if output=$(printf '%s' "$REGISTRY_PASSWORD" |
      docker login "$REGISTRY" --username "$REGISTRY_USERNAME" --password-stdin 2>&1); then
    echo "Logged in to ${REGISTRY} as ${REGISTRY_USERNAME} (attempt ${attempt}/${TOTAL})."
    exit 0
  fi

  echo "docker login to ${REGISTRY} failed on attempt ${attempt}/${TOTAL}:"
  echo "::stop-commands::${FENCE}"
  echo "$output"
  echo "::${FENCE}::"

  if [ "$attempt" -ge "$TOTAL" ]; then
    echo "::error::docker login to ${REGISTRY} failed ${TOTAL} times across $(( TOTAL - 1 )) backoffs. That is longer than a handshake blip, so treat it as the registry being down or the token being wrong rather than as a flake."
    exit 1
  fi

  backoff="${BACKOFFS[$(( attempt - 1 ))]}"
  echo "::warning::docker login to ${REGISTRY} failed (attempt ${attempt}/${TOTAL}); retrying in ${backoff}s. A transient handshake or throttle here would otherwise fail the release outright."
  sleep "$backoff"
  attempt=$(( attempt + 1 ))
done
