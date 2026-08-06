#!/usr/bin/env bash
# Back off between release-image build attempts, and say which side failed.
#
# The retry in release-image.yml is blind on purpose: the GHCR secondary rate limit
# that keeps breaking the release has surfaced as a 403 on a base blob, a 404 on a
# base manifest, and a 403 on a HEAD to a zimmer blob, so gating the retry on an
# error signature would trade a rare wasted rebuild for a missed retry the next time
# GitHub picks a new shape. This probe replaces that discrimination with a diagnosis:
# it asks the registry a question it can only answer if it is willing to talk to us.
#
# A probe failure means GHCR was refusing this account when the build died, which is
# the throttle. A probe success means the registry was fine and the build is the
# suspect -- read the build log, not this one. Either way the retry still runs; the
# probe reports, it does not decide.
set -uo pipefail

BACKOFF_SECONDS="${BACKOFF_SECONDS:?BACKOFF_SECONDS must be set}"
ATTEMPT="${ATTEMPT:?ATTEMPT must be set}"
PROBE_IMAGE="${PROBE_IMAGE:-ghcr.io/tadasant/zimmer-base:latest}"

# Uses the credentials the job already logged in with. `imagetools inspect` is a
# manifest read over the registry API -- the same authenticated path the build uses,
# and cheap enough to run twice in a failing job.
if probe_output=$(docker buildx imagetools inspect "$PROBE_IMAGE" 2>&1); then
  echo "::warning::Build attempt ${ATTEMPT} failed, but GHCR answered a manifest read for ${PROBE_IMAGE} just now. That points at the build rather than the registry -- read the build log above. Retrying anyway in ${BACKOFF_SECONDS}s."
else
  echo "::warning::Build attempt ${ATTEMPT} failed and GHCR is also refusing a manifest read for ${PROBE_IMAGE}, so the registry was throttling or unavailable. Retrying in ${BACKOFF_SECONDS}s."
  echo "Probe output:"
  echo "$probe_output"
fi

sleep "$BACKOFF_SECONDS"
