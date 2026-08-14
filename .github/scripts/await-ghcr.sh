#!/usr/bin/env bash
# Back off between release-image build attempts, and say what GHCR was doing.
#
# The retry in release-image.yml is blind on purpose: the GHCR secondary rate limit
# that keeps breaking the release has surfaced as a 403 on a base blob, a 404 on a
# base manifest, and a 403 on a push HEAD, so gating the retry on an error signature
# would trade a rare wasted rebuild for a missed retry the next time GitHub picks a
# new shape. This probe replaces that discrimination with a diagnosis.
#
# It reads a manifest from each package the build touches -- the base image it pulls
# FROM, and the app repository it pushes to -- because a throttle does not have to hit
# both. Read the result as evidence, not a verdict: these are READS, so two green
# probes narrow the suspect to the build without clearing a write-side throttle, which
# is exactly the shape the 2026-08-06 push failure took. The retry runs either way.
set -uo pipefail

BACKOFF_SECONDS="${BACKOFF_SECONDS:?BACKOFF_SECONDS must be set}"
ATTEMPT="${ATTEMPT:?ATTEMPT must be set}"
BASE_IMAGE="${BASE_IMAGE:-ghcr.io/tadasant/zimmer-base:latest}"
APP_IMAGE="${APP_IMAGE:-ghcr.io/tadasant/zimmer:latest}"

# Registry output is untrusted text; a line starting with `::` would otherwise be
# parsed as a workflow command. Fence it.
FENCE="await-ghcr-$$"

probe() {
  local image="$1" output
  # `imagetools inspect` is a manifest read over the registry API, using the
  # credentials the job already logged in with -- the same authenticated path the
  # build uses, and cheap enough to run twice in a failing job.
  if output=$(docker buildx imagetools inspect "$image" 2>&1); then
    echo "  ${image}: answered"
    return 0
  fi
  echo "  ${image}: REFUSED"
  echo "::stop-commands::${FENCE}"
  echo "$output"
  echo "::${FENCE}::"
  return 1
}

echo "Probing GHCR after failed build attempt ${ATTEMPT}:"
base_ok=true; app_ok=true
probe "$BASE_IMAGE" || base_ok=false
probe "$APP_IMAGE" || app_ok=false

if [ "$base_ok" = true ] && [ "$app_ok" = true ]; then
  echo "::warning::Build attempt ${ATTEMPT} failed, but GHCR answered manifest reads for both the base and app images just now. That points at the build rather than the registry -- though these are reads, so a write-side throttle on the push is not ruled out. Check whether the build died on the pull or the push. Retrying anyway in ${BACKOFF_SECONDS}s."
else
  echo "::warning::Build attempt ${ATTEMPT} failed and GHCR is also refusing a manifest read (base answered: ${base_ok}, app answered: ${app_ok}), so the registry was throttling or unavailable. Retrying in ${BACKOFF_SECONDS}s."
fi

sleep "$BACKOFF_SECONDS"
