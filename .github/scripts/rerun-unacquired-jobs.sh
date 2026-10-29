#!/usr/bin/env bash
# Decide whether a failed main-branch run is GitHub never handing a job a runner, and if so
# re-run it once and wait for the answer, instead of paging #alerts for a failure no code caused.
#
# A hosted job that waits too long for a runner is given up with the check-run annotation
# "The job was not acquired by Runner of type hosted even after multiple attempts". A macOS
# arm64 capacity shortage does this to the iOS jobs in `ci.yml` and the shards in
# `ios-ui-tests.yml`. Re-running the failed jobs is the whole fix.
#
# It waits on the re-run here rather than leaving attempt 2 to page on its own, because it
# cannot: a re-run requested with GITHUB_TOKEN fires no `workflow_run` event when it
# completes, so this listener would never hear about it. Measured on 2026-10-29: a
# GITHUB_TOKEN re-run of a finished run produced no listener run.
#
# Once, and only from attempt 1. `gh run rerun --failed` re-runs every failed and cancelled
# job, so a real failure sitting beside the lost one runs again and pages if it is real.
#
# Every answer this cannot reach is "page". A missed re-run costs one human command; a
# swallowed alert costs a red main nobody knows about.
#
# Writes `page=true|false` and `note=<one line for the alert>` to $GITHUB_OUTPUT.
# DRY_RUN=1 decides without re-running or waiting.
set -uo pipefail

REPO="${REPO:?REPO must be set}"
RUN_ID="${RUN_ID:?RUN_ID must be set}"
RUN_ATTEMPT="${RUN_ATTEMPT:?RUN_ATTEMPT must be set}"
# Below the job's timeout-minutes, so a re-run that never finishes still pages.
WAIT_MINUTES="${WAIT_MINUTES:-110}"
POLL_SECONDS="${POLL_SECONDS:-60}"
MARKER="was not acquired by Runner"

verdict() {
  {
    echo "page=$1"
    echo "note=$2"
  } >> "${GITHUB_OUTPUT:-/dev/null}"
  echo "page=$1: $2"
  exit 0
}

if [ "$RUN_ATTEMPT" != "1" ]; then
  verdict true ""
fi

if ! cancelled="$(gh api --paginate "repos/${REPO}/actions/runs/${RUN_ID}/attempts/1/jobs" \
    --jq '.jobs[] | select(.conclusion == "cancelled") | "\(.id) \(.name)"')"; then
  verdict true "Could not list the run's jobs to check for a lost runner."
fi

unacquired=""
while read -r id name; do
  [ -n "$id" ] || continue
  if ! messages="$(gh api "repos/${REPO}/check-runs/${id}/annotations" --jq '.[].message')"; then
    verdict true "Could not read job ${name}'s annotations to check for a lost runner."
  fi
  if grep -qF "$MARKER" <<<"$messages"; then
    unacquired="${unacquired}${unacquired:+, }${name}"
  fi
done <<<"$cancelled"

if [ -z "$unacquired" ]; then
  verdict true ""
fi

if [ "${DRY_RUN:-}" = "1" ]; then
  verdict false "DRY_RUN: would re-run and wait; GitHub gave no runner to: ${unacquired}."
fi

if ! gh run rerun "$RUN_ID" --failed -R "$REPO"; then
  verdict true "GitHub gave no runner to ${unacquired}, and re-running it failed."
fi
echo "GitHub gave no runner to ${unacquired}; re-ran the failed jobs, waiting up to ${WAIT_MINUTES} min."

deadline=$(( $(date +%s) + WAIT_MINUTES * 60 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  sleep "$POLL_SECONDS"
  # One transient API error must not page; keep polling until the deadline.
  state="$(gh api "repos/${REPO}/actions/runs/${RUN_ID}" \
    --jq '"\(.run_attempt) \(.status) \(.conclusion // "")"')" || continue
  read -r attempt status conclusion <<<"$state"
  echo "attempt ${attempt}: ${status} ${conclusion}"
  [ "$attempt" -ge 2 ] && [ "$status" = "completed" ] || continue
  case "$conclusion" in
    success)
      verdict false "GitHub gave no runner to ${unacquired}; the automatic re-run passed." ;;
    cancelled | skipped)
      # Superseded by a newer push, which the listener keeps quiet about anyway.
      verdict false "GitHub gave no runner to ${unacquired}; the re-run was ${conclusion}." ;;
    *)
      verdict true "GitHub gave no runner to ${unacquired} on attempt 1; the automatic re-run then concluded ${conclusion}." ;;
  esac
done
verdict true "GitHub gave no runner to ${unacquired}; the automatic re-run had not finished after ${WAIT_MINUTES} min."
