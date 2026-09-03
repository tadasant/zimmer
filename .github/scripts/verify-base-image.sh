#!/usr/bin/env bash
# Assert that a base image really carries every npm package Dockerfile.base pins, and
# every Pi extension entrypoint it smoke-checks.
#
# This runs INSIDE the image, after it has been pushed and pulled back down, so what it
# reads is what the registry serves rather than what a build log claimed. The `test -f`
# lines in Dockerfile.base check the same ground at build time and are not a substitute:
# they say a layer was produced, not that the tag the release path resolves serves it.
#
# Both inputs are whitespace-separated lists extracted from Dockerfile.base by the
# caller, because the runner has the repo and the image does not:
#   EXPECTED_PINS         `name@version` specs from its npm install lines
#   EXPECTED_ENTRYPOINTS  absolute paths from its `test -f` smoke checks
#
# Invoked as `docker run --rm -i -e EXPECTED_PINS=… -e EXPECTED_ENTRYPOINTS=… \
#   --entrypoint bash IMAGE -s` with this file on stdin — deliberately not a bind
# mount, because the self-hosted runner and the Docker daemon do not necessarily share
# a filesystem.
set -uo pipefail

# Every place Dockerfile.base installs npm packages into. A pin resolved from none of
# them is reported missing rather than silently skipped.
ROOTS=(
  /usr/lib/node_modules
  /usr/local/lib/node_modules
  /opt/air-cli/node_modules
  /opt/pi-extensions/node_modules
)

# An empty list would make the whole check pass while asserting nothing, which is the
# one failure mode worse than the drift it is looking for. Read with :- so `set -u`
# does not abort before this can say why.
for var in EXPECTED_PINS EXPECTED_ENTRYPOINTS; do
  value="${!var:-}"
  if [ -z "${value// }" ]; then
    echo "$var is empty — the caller's extraction from Dockerfile.base matched nothing," >&2
    echo "which would make this check pass vacuously. Refusing." >&2
    exit 1
  fi
done

failed=0

for spec in $EXPECTED_PINS; do
  name="${spec%@*}"
  want="${spec##*@}"

  got=""
  where=""
  for root in "${ROOTS[@]}"; do
    pkg="$root/$name/package.json"
    if [ -f "$pkg" ]; then
      got=$(node -p "require('$pkg').version" 2>/dev/null || echo "unreadable")
      where="$root"
      break
    fi
  done

  if [ -z "$got" ]; then
    printf '  MISSING  %-46s (want %s; searched %s)\n' "$name" "$want" "${ROOTS[*]}"
    failed=1
  elif [ "$got" != "$want" ]; then
    printf '  WRONG    %-46s want %s, image has %s (%s)\n' "$name" "$want" "$got" "$where"
    failed=1
  else
    printf '  ok       %-46s %s (%s)\n' "$name" "$got" "$where"
  fi
done

# A version check cannot see this: an npm package whose tarball unpacked to a different
# layout installs cleanly at the right version and then loads nothing, because
# PiExtensions#resolved_paths drops an extension whose entrypoint is not on disk and Pi
# runs without it. That is the failure #757 hit.
for path in $EXPECTED_ENTRYPOINTS; do
  if [ -f "$path" ]; then
    printf '  ok       %-46s entrypoint present\n' "$path"
  else
    printf '  MISSING  %-46s entrypoint absent\n' "$path"
    failed=1
  fi
done

if [ "$failed" -ne 0 ]; then
  echo
  echo "The published image does not match the declarations in Dockerfile.base." >&2
  exit 1
fi

echo
echo "Every pin and entrypoint Dockerfile.base declares is present in the published image."
