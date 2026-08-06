#!/bin/sh
# Fail if a copy of the Zimmer documentation site is present under a directory tree.
#
# WHY: the docs are single-source. The only copy that exists is docs/ in this repo,
# built by Cloudflare Pages and served at docs.zimmer.tadasant.com. A second copy
# riding along inside the published application image would be a copy nobody deploys,
# nobody reads, and nobody keeps true -- drift with no signal.
#
# The only thing keeping it out is one `/docs` line in .dockerignore standing in front
# of the blanket `COPY . .` in Dockerfile. This script asserts the OUTCOME instead of
# trusting that line, and it runs from two places:
#
#   Dockerfile              against /rails in the final stage -- the real filesystem of
#                           the real published image. Fails the BUILD, so an image
#                           carrying the docs is never pushed.
#   Dockerfile.docs-audit   against the real build context, inside a tiny busybox image,
#                           so PR CI gets the same signal without building the app image.
#
# It has to run in busybox ash and in the Debian-based app image, so: POSIX sh only, and
# no tool beyond find/grep/sed.
#
# Deliberately content-based, not path-based. Moving docs/ somewhere else is exactly how
# the exclusion gets lost silently, so an Astro config or a Starlight dependency anywhere
# in the tree counts, whatever directory it sits in.
set -eu

usage() {
  cat <<'USAGE'
Usage: assert-docs-excluded.sh --root DIR

Exit 0 if DIR holds no copy of the documentation site, 1 if it does, 2 on a usage error.
USAGE
}

root=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      if [ "$#" -lt 2 ]; then
        echo "assert-docs-excluded.sh: --root needs a directory" >&2
        exit 2
      fi
      root="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "assert-docs-excluded.sh: unknown argument: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

if [ -z "$root" ]; then
  usage >&2
  exit 2
fi

if [ ! -d "$root" ]; then
  echo "assert-docs-excluded.sh: not a directory: $root" >&2
  exit 2
fi

findings=""

# $1: label for the kind of hit, $2: newline-separated paths (may be empty).
# printf, not echo: in ash and dash, echo expands backslash escapes, which would mangle
# a path containing one.
record() {
  if [ -n "$2" ]; then
    findings="${findings}$(printf '%s\n' "$2" | sed "s|^|  $1: |")
"
  fi
}

# A scan that cannot run is not a scan that found nothing. Every failure below exits 2
# rather than falling through to the "OK" at the bottom -- a guardrail that passes when
# its own machinery is broken is worse than no guardrail, because it looks like a check.
scan_failed() {
  echo "assert-docs-excluded.sh: $1 under $root" >&2
  exit 2
}

# Every scan skips node_modules and .git. A Starlight dependency vendored under
# node_modules belongs to some other package's tree, not to a second copy of our site.

# 1. The canonical path, at the top of the tree. Exact, cheap, and the case that actually
# regresses. Checks 2 and 3 are the recursive ones.
if [ -e "$root/docs" ]; then
  record "docs directory" "$root/docs"
fi

# 2. An Astro site anywhere under the tree, whatever directory it was moved to.
if ! astro_configs=$(find "$root" \( -name node_modules -o -name .git \) -prune -o \
  -type f -name 'astro.config.*' -print); then
  scan_failed "could not scan for Astro configs"
fi
record "Astro config" "$astro_configs"

# 3. A Starlight dependency in any package manifest -- catches a docs site whose config
# was renamed or generated, and catches a stray docs/package-lock.json on its own.
if ! manifests=$(find "$root" \( -name node_modules -o -name .git \) -prune -o \
  -type f \( -name package.json -o -name package-lock.json \) -print); then
  scan_failed "could not scan for package manifests"
fi
starlight=""
if [ -n "$manifests" ]; then
  # `elif [ "$?" -gt 1 ]` reads grep's status: 1 is "no match", anything higher is a file
  # grep could not read, which must not be mistaken for a clean manifest.
  if ! starlight=$(printf '%s\n' "$manifests" | while IFS= read -r manifest; do
    if grep -q '@astrojs/starlight' "$manifest"; then
      printf '%s\n' "$manifest"
    elif [ "$?" -gt 1 ]; then
      exit 2
    fi
  done); then
    scan_failed "could not read a package manifest"
  fi
fi
record "Starlight dependency" "$starlight"

if [ -n "$findings" ]; then
  cat >&2 <<EOF
FAIL: the documentation site is present under $root.

$findings
The docs are single-source: docs/ in this repo, deployed to Cloudflare Pages and nowhere
else. They must not be bundled into the published application image, or the product
ships a second, drift-prone copy that nobody deploys and nobody keeps true.

Fix the exclusion, not this check:
  - .dockerignore must exclude the docs tree from the build context. If the docs
    moved, move the /docs entry with them.
  - No COPY or ADD in Dockerfile may reintroduce them by another route.

See docs/src/content/docs/operate/deploying.md ("The docs never ship in the image").
EOF
  exit 1
fi

echo "OK: no copy of the documentation site under $root"
