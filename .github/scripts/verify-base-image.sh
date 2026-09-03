#!/usr/bin/env bash
# Assert that a base image really carries every npm package Dockerfile.base pins.
#
# This runs INSIDE the image, after it has been pushed and pulled back down, so what
# it reads is what the registry serves rather than what a build log claimed. The
# `test -f` lines in Dockerfile.base check the same ground at build time and are not
# a substitute: they say a layer was produced, not that the tag every session image
# is built FROM now resolves to it.
#
# EXPECTED_PINS is a whitespace-separated list of `name@version` specs, extracted
# from Dockerfile.base by the caller (the runner has the repo; the image does not).
#
# Invoked as `docker run --rm -i -e EXPECTED_PINS=... --entrypoint bash IMAGE -s`
# with this file on stdin — deliberately not a bind mount, because the self-hosted
# runner and the Docker daemon do not necessarily share a filesystem.
set -uo pipefail

# Every place Dockerfile.base installs npm packages into. A pin resolved from none
# of them is reported as missing rather than silently skipped.
ROOTS=(
  /usr/lib/node_modules
  /usr/local/lib/node_modules
  /opt/air-cli/node_modules
  /opt/pi-extensions/node_modules
)

if [ -z "${EXPECTED_PINS// }" ]; then
  echo "EXPECTED_PINS is empty — the caller's extraction matched nothing, which would" >&2
  echo "make this check pass vacuously. Refusing." >&2
  exit 1
fi

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

# The Pi extension entrypoints are paths, not versions: an unpacked tarball with the
# entrypoint at a different path installs cleanly and then loads nothing, which is
# the failure #757 hit. Read them out of the packages' own `pi.extensions` field
# rather than restating the paths here.
for name in pi-mcp-adapter @tadasant/pi-hooks @tadasant/pi-plugins; do
  pkg="/opt/pi-extensions/node_modules/$name/package.json"
  [ -f "$pkg" ] || continue
  entries=$(node -p "JSON.stringify(require('$pkg').pi?.extensions ?? [])" 2>/dev/null || echo "[]")
  for rel in $(node -p "($entries).map(e => typeof e === 'string' ? e : e.path).join(' ')" 2>/dev/null); do
    abs="/opt/pi-extensions/node_modules/$name/${rel#./}"
    if [ -f "$abs" ]; then
      printf '  ok       %-46s entrypoint %s\n' "$name" "$rel"
    else
      printf '  MISSING  %-46s entrypoint %s (no file at %s)\n' "$name" "$rel" "$abs"
      failed=1
    fi
  done
done

if [ "$failed" -ne 0 ]; then
  echo
  echo "The published base image does not match the pins in Dockerfile.base." >&2
  exit 1
fi

echo
echo "Every pin in Dockerfile.base is present in the published image."
