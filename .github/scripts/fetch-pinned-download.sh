#!/usr/bin/env bash
# Puts a file whose sha256 is pinned at <dest>, and fails if that cannot be done.
#
#   usage: fetch-pinned-download.sh <url> <sha256> <dest>
#
# A CI job that downloads a tool on every run turns any upstream 5xx into a red `main` with
# nothing wrong in the repo. So the first verified copy is kept on the runner, under a name
# that is its own checksum, and later runs make no request at all.
#
# The cache only saves the request; it is not trusted. Every copy is checked against the pin
# on every run. A cached copy that does not match is dropped and fetched again. It does not
# fail the job, because nobody has a shell on these runners to clear it and the bad file would
# keep `main` red. A download that does not match does fail the job, and nothing is cached.
#
# A cold cache gets 8 retries with curl's doubling backoff, so 1+2+...+128 = 255 seconds
# between attempts: long enough to outlast a short upstream blip, bounded so that a sustained
# outage still fails the job. FETCH_RETRIES exists for the test, which cannot wait that long.
set -euo pipefail

url="${1:?usage: fetch-pinned-download.sh <url> <sha256> <dest>}"
sha="${2:?usage: fetch-pinned-download.sh <url> <sha256> <dest>}"
dest="${3:?usage: fetch-pinned-download.sh <url> <sha256> <dest>}"
retries="${FETCH_RETRIES:-8}"
cache_dir="${FETCH_CACHE_DIR:-${HOME:?}/.zimmer-ci/downloads}"
cached="${cache_dir}/${sha}"

matches_pin() {
  printf '%s  %s\n' "$sha" "$1" | sha256sum --check --status -
}

if [ -f "$cached" ]; then
  if matches_pin "$cached"; then
    cp "$cached" "$dest"
    echo "Using the cached copy of ${url}"
    exit 0
  fi
  echo "::warning::The cached copy at ${cached} does not match its pin. Dropping it and fetching again."
  rm -f "$cached"
fi

# --retry-all-errors, because plain --retry skips a dropped connection or a failed DNS lookup.
curl -fsSL --retry "$retries" --retry-all-errors --connect-timeout 20 --max-time 120 \
  -o "$dest" "$url"

if ! matches_pin "$dest"; then
  actual="$(sha256sum "$dest" | cut -d' ' -f1)"
  rm -f "$dest"
  echo "::error::${url} has sha256 ${actual}, not the pinned ${sha}."
  exit 1
fi

# The file is verified and in place, so a runner that cannot cache is slower, not broken.
# Runners on one machine share this directory, so the rename is what publishes the file:
# none of them can ever read a half-written copy.
if ! { mkdir -p "$cache_dir" &&
  tmp="$(mktemp "${cache_dir}/.incoming.XXXXXX")" &&
  cp "$dest" "$tmp" &&
  mv -f "$tmp" "$cached"; }; then
  echo "::warning::Could not cache ${url} in ${cache_dir}; the next run will download it again."
fi
