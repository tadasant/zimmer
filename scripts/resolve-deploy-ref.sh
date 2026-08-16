#!/usr/bin/env bash
# Resolve a deploy workflow's `ref` input into something actions/checkout can actually
# check out -- and when it cannot be resolved, say which ref failed, in a second.
#
# Why this exists: actions/checkout only special-cases a FULL 40-character SHA. Anything
# shorter it treats as a branch or tag name, so for "9e95b4d" it fetches
# `+refs/heads/9e95b4d*` and `+refs/tags/9e95b4d*`, matches nothing, retries three times,
# and exits with a bare
#   The process '/usr/bin/git' failed with exit code 1
# that never mentions the ref. An abbreviated SHA is exactly what `git log --oneline`
# prints and what gets pasted into a pinned redeploy or a rollback rehearsal, so the
# input's own "SHA" description walked people straight into it: sixty seconds of a
# self-hosted runner and a #alerts page, for a typo-shaped mistake nobody was told about.
#
# The commits API resolves every form in one request -- branch, tag, full SHA, abbreviated
# SHA -- and distinguishes "this repository has no such commit" from "the API could not be
# reached", which are two different problems for whoever reads the failure.
#
# Usage: env REQUESTED_REF=... FALLBACK_REF=... scripts/resolve-deploy-ref.sh
#   REQUESTED_REF  the workflow_dispatch input; empty means nothing was pinned
#   FALLBACK_REF   what to deploy when nothing was pinned (github.sha)
#   GITHUB_OUTPUT  where the decision is written; required (use /dev/null by hand)
#   ATTEMPTS       tries before giving up on an unreachable API (default 3)
# Both refs arrive as environment variables rather than as arguments on purpose: a dispatch
# input interpolated into a `run:` command line is a script-injection hole, and `env:` is
# the documented way to keep it data.
#
# Writes `ref=<value>` to $GITHUB_OUTPUT and prints the decision.
# Exit codes: 0 resolved · 1 could not resolve · 2 called wrong.
set -euo pipefail

# Strip the ENDS only. Padding is what survives a copy-paste (" 9e95b4d", a trailing
# newline out of a terminal) and no deploy should die over an invisible character -- but
# whitespace in the middle means the input was never a ref, and silently closing
# "feature x" up into "featurex" could resolve something real that nobody asked for.
trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  printf '%s' "${value%"${value##*[![:space:]]}"}"
}

requested="$(trim "${REQUESTED_REF-}")"
fallback="$(trim "${FALLBACK_REF-}")"
attempts="${ATTEMPTS:-3}"

emit() {
  # Without GITHUB_OUTPUT nothing downstream consumes the decision, and an empty `ref:`
  # makes checkout quietly take the default branch -- the silent wrong deploy this script
  # exists to prevent. Refuse rather than exit 0 having decided nothing.
  if [ -z "${GITHUB_OUTPUT:-}" ]; then
    echo "::error::GITHUB_OUTPUT is not set, so nothing would consume this decision."
    exit 2
  fi
  echo "Checking out ${1} (${2})."
  echo "ref=${1}" >> "$GITHUB_OUTPUT"
}

fail() {
  echo "::error::$*"
  exit 1
}

if [ -z "$requested" ]; then
  if [ -z "$fallback" ]; then
    echo "::error::Neither REQUESTED_REF nor FALLBACK_REF is set, so there is nothing to check out."
    exit 2
  fi
  emit "$fallback" "no ref was pinned, so the commit this run was dispatched from"
  exit 0
fi

# A full SHA is the one form actions/checkout already handles, and asking the API about it
# can only NARROW what this workflow accepts -- a commit the API declines to show (an
# unreachable object, a fork head) would be rejected here while checkout fetches it fine.
# Pass it through, lowercased so the value written out matches the one validated below.
if [[ "$requested" =~ ^[0-9a-fA-F]{40}$ ]]; then
  emit "${requested,,}" "already a full commit SHA"
  exit 0
fi

# The ref is interpolated into a URL path, so hold it to a conservative shape: nothing that
# could graft a query or a fragment onto the request, and no ".." for curl to normalize
# into a different endpoint. This is NARROWER than `git check-ref-format` -- a branch named
# `fix#123` is legal in git and refused here -- so the message says that plainly instead of
# calling a real branch invalid, and a full 40-character SHA is always a way through.
if [[ ! "$requested" =~ ^[A-Za-z0-9][A-Za-z0-9._/@+-]*$ ]] || [[ "$requested" == *".."* ]]; then
  fail "Cannot deploy ref '${requested}': this resolver only accepts refs made of" \
       "[A-Za-z0-9._/@+-], never containing '..', because the ref goes into a URL path." \
       "Dispatch the full 40-character SHA instead."
fi

api_url="${GITHUB_API_URL:-https://api.github.com}"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set to owner/name}"
token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

case "$attempts" in
  ''|*[!0-9]*) echo "::error::ATTEMPTS must be a positive integer (got '${attempts}')"; exit 2 ;;
esac
if [ "$attempts" -lt 1 ]; then
  echo "::error::ATTEMPTS must be a positive integer (got '${attempts}')"
  exit 2
fi

auth=()
if [ -n "$token" ]; then
  auth=(-H "Authorization: Bearer ${token}")
fi

body="$(mktemp)"
curl_stderr="$(mktemp)"
# shellcheck disable=SC2064  # expand the paths now, not at trap time
trap "rm -f '${body}' '${curl_stderr}'" EXIT

# What the API said, for the operator: its own sentence beats a status code. No pipeline --
# under `pipefail` a body big enough to SIGPIPE `head` would abort this function and lose
# the sentence entirely, which is the HTML-error-page case it exists for.
api_message() {
  local message=""
  if command -v jq >/dev/null 2>&1; then
    message="$(jq -r '.message // empty' < "$body" 2>/dev/null || true)"
  fi
  if [ -z "$message" ]; then
    message="$(tr -d '\n' < "$body")"
  fi
  message="${message:0:200}"
  printf '%s' "${message:-no response body}"
}

code=000
attempt=0
while [ "$attempt" -lt "$attempts" ]; do
  attempt=$((attempt + 1))

  # The `.sha` media type answers with the 40 characters and nothing else -- no commit
  # diff, no file list -- so this stays a ~40-byte request however large the commit is.
  #
  # curl prints `%{http_code}` (000 when it never got a response) and THEN exits non-zero,
  # so `|| echo 000` would append a second status to the one already printed and produce
  # "000000", matching no case below. `|| true` keeps `set -e` off the substitution without
  # touching what curl wrote. Its stderr is kept, not discarded: on a 000 the reason ("Could
  # not resolve host", "Connection timed out") is the only explanation there will ever be.
  code="$(curl -sS -o "$body" -w '%{http_code}' --max-time 20 \
    -H "Accept: application/vnd.github.sha" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    ${auth[@]+"${auth[@]}"} \
    "${api_url}/repos/${repo}/commits/${requested}" 2>"$curl_stderr" || true)"
  code="${code:-000}"

  case "$code" in
    # Only a transport failure or a server-side wobble is worth another go. A 4xx is a
    # verdict about the ref, and retrying it just spends the minute this script saves.
    000|429|5??)
      # Back off BETWEEN attempts. After the last one there is nothing left to wait for.
      if [ "$attempt" -lt "$attempts" ]; then
        sleep 2
      fi
      ;;
    *) break ;;
  esac
done

case "$code" in
  200) : ;;
  404|422)
    fail "Cannot deploy ref '${requested}': ${repo} has no commit, branch, or tag by that" \
         "name, or it is not visible to this token. GitHub said: $(api_message)."
    ;;
  401|403)
    fail "Cannot resolve ref '${requested}': the GitHub API refused the request (HTTP ${code})." \
         "GitHub said: $(api_message). This is a token or rate-limit problem, not a bad ref."
    ;;
  *)
    transport="$(tr -d '\n' < "$curl_stderr")"
    transport="${transport:0:200}"
    fail "Could not reach the GitHub API to resolve ref '${requested}' after ${attempts}" \
         "attempt(s) (last status ${code}${transport:+; ${transport}})." \
         "The ref may well be fine; the API was not."
    ;;
esac

sha="$(tr -d '[:space:]' < "$body")"
if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
  fail "GitHub resolved ref '${requested}' to something that is not a commit SHA:" \
       "'${sha:0:100}'."
fi

emit "$sha" "resolved from '${requested}'"
