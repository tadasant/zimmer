#!/bin/sh
# Fail if the Zimmer extension tree did not survive into a directory tree.
#
# WHY: an extension (app/extensions/<id>/, see Zimmer::Extension) is only useful if it
# is present in the container that runs it. .dockerignore used to carry
# `/app/extensions/*/`, which stripped every extension directory out of the build
# context, and the failure was completely silent: the app still booted,
# ExtensionRegistry resolves builtins with safe_constantize and skips the ones that no
# longer resolve, every seam fell back to native, and nothing anywhere said the seam
# was dead. It stayed dead long enough for the only extension that ever shipped to be
# rewritten as a plain AppSetting column. That is tadasant/zimmer#91.
#
# Nothing in Dockerfile is selective: the build stage does a blanket `COPY . .` and the
# final stage a `COPY --from=build /rails /rails`. So the whole invariant rests on
# .dockerignore NOT excluding this path -- an absence, which is the hardest kind of
# thing to notice going missing. This script asserts the OUTCOME instead, and runs from
# two places:
#
#   Dockerfile                    against /rails in the final stage -- the real
#                                 filesystem of the real published image. Fails the
#                                 BUILD, so an image with the seam stripped out is
#                                 never pushed.
#   Dockerfile.extensions-audit   against the real build context, inside a tiny busybox
#                                 image, so PR CI's image_includes_extensions job gets
#                                 the same signal without building the app image.
#
# It has to run in busybox ash and in the Debian-based app image, so: POSIX sh only, and
# no tool beyond find/grep/sed.
#
# Deliberately outcome-based, not text-based. A check that reads .dockerignore looking
# for a forbidden line passes happily while a differently-spelled pattern
# (`**/extensions`, `app/extensions/**/*.rb`, a broad `app/ex*`) does the same damage.
set -eu

usage() {
  cat <<'USAGE'
Usage: assert-extensions-shipped.sh --root DIR

Exit 0 if DIR carries an intact app/extensions tree, 1 if it does not, 2 on a usage
error or a scan that could not run.
USAGE
}

root=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      if [ "$#" -lt 2 ]; then
        echo "assert-extensions-shipped.sh: --root needs a directory" >&2
        exit 2
      fi
      root="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "assert-extensions-shipped.sh: unknown argument: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

if [ -z "$root" ]; then
  usage >&2
  exit 2
fi

if [ ! -d "$root" ]; then
  echo "assert-extensions-shipped.sh: not a directory: $root" >&2
  exit 2
fi

# Strip trailing slashes so the paths below have one spelling: "/rails/app/extensions",
# never "/rails//app/extensions".
while [ "$root" != "/" ] && [ "${root%/}" != "$root" ]; do
  root="${root%/}"
done

ext_root="$root/app/extensions"

fail() {
  cat >&2 <<EOF
FAIL: $1

  root: $root

Extensions are meant to be baked into the image. An extension is a Ruby object that
changes how Zimmer itself drives a runtime; if its directory is absent from the
container, ExtensionRegistry skips the class, every seam falls back to native, and the
whole seam is silently dead -- see tadasant/zimmer#91.

Fix the exclusion, not this check:
  - .dockerignore must NOT exclude app/extensions/ or anything under it. There is no
    entry for it today, and there should not be one.
  - No COPY or ADD in Dockerfile may remove or shadow the tree after the build stage
    copies it in.

Removability lives in the SOURCE TREE, not in the image: deleting app/extensions/<id>/
from the repository is what drops an extension, and ExtensionRegistry's safe_constantize
skip is what makes that safe. Stripping the directory at build time is not the same
thing and is not a substitute for it.

See docs/src/content/docs/operate/deploying.md ("Extensions do ship in the image").
EOF
  exit 1
}

# A scan that cannot run is not a scan that found nothing -- a guardrail that passes
# when its own machinery is broken is worse than no guardrail, because it looks like a
# check. Every failure below exits 2 rather than falling through to the "OK".
scan_failed() {
  echo "assert-extensions-shipped.sh: $1 under $ext_root" >&2
  exit 2
}

# 1. The tree itself. Its absence is the coarse regression -- somebody excluded
# `/app/extensions` outright, or moved it.
if [ ! -d "$ext_root" ]; then
  fail "app/extensions/ is not present."
fi

# 2. The canary, one level down. This is the assertion that actually matters: the
# pattern this check exists to catch was `/app/extensions/*/`, which excluded
# SUBDIRECTORIES while leaving app/extensions/CLAUDE.md in place. A marker at the top of
# the tree would have passed all the way through the outage.
if [ ! -f "$ext_root/image_canary/IMAGE_CANARY.md" ]; then
  fail "app/extensions/image_canary/IMAGE_CANARY.md is missing, so no subdirectory of app/extensions/ survived."
fi

# 3. Any directory under the tree that arrived hollow. Catches the narrower exclusions a
# subdirectory canary alone would not: `app/extensions/**/*.rb` leaves every directory
# standing and empties the ones that carry code.
#
# Not depth-limited, deliberately. app/extensions/CLAUDE.md blesses a `lib/` driver
# script inside an extension, so the code an exclusion would strip is routinely one more
# level down -- and against `pty_transport/lib/*.rb`, a scan capped at depth 1 sees
# pty_transport/ still holding lib/ and calls the tree healthy.
#
# `-mindepth`, `-empty`: both are in busybox find (busybox:stable is what
# Dockerfile.extensions-audit runs) and in GNU find. A build of find without them exits
# non-zero, which lands in scan_failed and reddens the job rather than passing it.
if ! empty_dirs=$(find "$ext_root" -mindepth 1 -type d -empty -print); then
  scan_failed "could not scan for empty extension directories"
fi
if [ -n "$empty_dirs" ]; then
  fail "these extension directories arrived empty:
$(printf '%s\n' "$empty_dirs" | sed 's|^|    |')"
fi

echo "OK: app/extensions/ shipped intact under $root"
