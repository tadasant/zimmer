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
# Only while the run is still the newest of its workflow on main. A re-run joins the
# workflow's concurrency group like a new run, so re-running an older commit would cancel
# the newer commit's run (`ci.yml` cancels in progress), and a cancelled run never pages:
# main's newest commit would be left with no CI answer and nobody told.
#
# A superseded run waits for the newest run's answer instead, and the same wait covers a
# re-run a newer push cancelled. A human has nothing to do while that answer is coming: a
# failed newest run reaches this same listener, where a lost runner gets its one re-run and
# anything else pages. So this stays quiet only once the newest run of the same trigger has
# FINISHED, because a run still queued can yet be cancelled, and a cancelled run never pages.
# It pages when that newest run:
#   - concluded anything but success or a failure the listener hears (`cancelled` with
#     nothing newer behind it is the usual one);
#   - does not contain this run's commit;
#   - skipped a job this run never finished. `ci.yml`'s iOS jobs skip on a commit that
#     does not touch ios/, and a skip is a non-answer, so a green run there says nothing
#     about the lost job;
#   - had not finished when the wait ran out.
# A dispatched run always pages: its inputs are its own (`signing` in `testflight.yml`, the
# configuration in `ios-ui-tests.yml`), and no other run can answer for them.
#
# A job that really failed beside the lost one pages at once on both paths: with no lost
# runner it would have paged, and a newer pass does not make it not have happened.
# `ci.yml`'s `all-checks-pass` is the exception. It fails because the lost job did not pass,
# which says nothing new, so it is not counted as a failure of its own.
#
# Every answer this cannot reach is "page". A missed re-run costs one human command; a
# swallowed alert costs a red main nobody knows about.
#
# Writes `page=true|false` and `note=<one line for the alert>` to $GITHUB_OUTPUT.
# DRY_RUN=1 decides without re-running or waiting: a newer run still going reports the wait
# it would make, and a finished one gets its real verdict.
set -uo pipefail

REPO="${REPO:?REPO must be set}"
RUN_ID="${RUN_ID:?RUN_ID must be set}"
RUN_ATTEMPT="${RUN_ATTEMPT:?RUN_ATTEMPT must be set}"
WORKFLOW_ID="${WORKFLOW_ID:?WORKFLOW_ID must be set}"
HEAD_SHA="${HEAD_SHA:?HEAD_SHA must be set}"
RUN_EVENT="${RUN_EVENT:?RUN_EVENT must be set}"
# Below the retry step's timeout-minutes, so a wait that never ends still pages. One budget
# for the whole script, re-run and newer run together.
WAIT_MINUTES="${WAIT_MINUTES:-100}"
POLL_SECONDS="${POLL_SECONDS:-60}"
# Per API call: one stalled request is a transient error, not the whole wait.
API_TIMEOUT="${API_TIMEOUT:-60}"
MARKER="was not acquired by Runner"
GATE_JOB="all-checks-pass"

api() { timeout "$API_TIMEOUT" gh api "$@"; }

verdict() {
  # One line each: a newline in a job name must not write a second `page=` line.
  local note="${2//$'\n'/ }"
  {
    echo "page=$1"
    echo "note=${note}"
  } >> "${GITHUB_OUTPUT:-/dev/null}"
  echo "page=$1: ${note}"
  exit 0
}

# The newest run of this workflow on main, as: id head_sha status conclusion
# $1 narrows the query, as `&event=push`.
read_newest() {
  api "repos/${REPO}/actions/workflows/${WORKFLOW_ID}/runs?branch=main&per_page=1${1:-}" \
    --jq '.workflow_runs[0] | "\(.id) \(.head_sha) \(.status) \(.conclusion // "-")"'
}

# Rule on the newest run, or return if it has not answered yet. A failed API call returns
# too: one transient error must not page, and the deadline still does.
check_newest() {
  local context="$1" newest id sha status conclusion contains ran job
  if [ "$RUN_EVENT" = "workflow_dispatch" ]; then
    verdict true "${context}; a dispatched run has its own inputs, so no other run answers for it."
  fi
  # The same trigger only: a dispatch of `ios-ui-tests.yml` on top says nothing about pushes.
  newest="$(read_newest "&event=${RUN_EVENT}")" || return 0
  read -r id sha status conclusion <<<"$newest"

  # A number comparison, so an empty list (`null`) or a stale one pages as well.
  if ! [ "$id" -gt "$RUN_ID" ] 2>/dev/null; then
    verdict true "${context}; no newer run will answer for it."
  fi
  [ "$status" = "completed" ] || return 0

  case "$conclusion" in
    success | failure | startup_failure | timed_out) ;;
    *) verdict true "${context}; the newest run ${id} then concluded ${conclusion}, which answers nothing." ;;
  esac

  contains="$(api "repos/${REPO}/compare/${HEAD_SHA}...${sha}" --jq '.status')" || return 0
  if [ "$contains" != "ahead" ] && [ "$contains" != "identical" ]; then
    verdict true "${context}; the newest run ${id} does not contain this run's commit."
  fi

  ran="$(api --paginate "repos/${REPO}/actions/runs/${id}/jobs" \
    --jq '.jobs[] | select(.conclusion != "skipped") | .name')" || return 0
  while read -r job; do
    [ -n "$job" ] || continue
    if ! grep -qxF -- "$job" <<<"$ran"; then
      verdict true "${context}; the newest run ${id} concluded ${conclusion} and skipped ${job}."
    fi
  done <<<"$must_run"

  verdict false "${context}; the newest run ${id} did not skip it and concluded ${conclusion}, which the listener answers for."
}

# Hold until the newest run answers. The newest is re-read every time: the run seen first
# can be replaced by a later push, and then the later push's run is the answer.
await_newest() {
  local context="$1"
  while :; do
    check_newest "$context"
    if [ "${DRY_RUN:-}" = "1" ]; then
      verdict false "DRY_RUN: ${context}; would wait up to ${WAIT_MINUTES} min for the newest run: $(read_newest "&event=${RUN_EVENT}")."
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      verdict true "${context}; the newest run had not answered after ${WAIT_MINUTES} min."
    fi
    sleep "$POLL_SECONDS"
  done
}

deadline=$(( $(date +%s) + WAIT_MINUTES * 60 ))

if [ "$RUN_ATTEMPT" != "1" ]; then
  verdict true ""
fi

if ! unfinished="$(api --paginate "repos/${REPO}/actions/runs/${RUN_ID}/attempts/1/jobs" \
    --jq '.jobs[] | select(.conclusion != "success" and .conclusion != "skipped") | "\(.id) \(.conclusion) \(.name)"')"; then
  verdict true "Could not list the run's jobs to check for a lost runner."
fi

unacquired=""
others=""
must_run=""
while read -r id conclusion name; do
  [ -n "$id" ] || continue
  must_run="${must_run}${name}"$'\n'
  if [ "$conclusion" != "cancelled" ]; then
    [ "$name" = "$GATE_JOB" ] || others="${others}${others:+, }${name}"
    continue
  fi
  if ! messages="$(api "repos/${REPO}/check-runs/${id}/annotations" --jq '.[].message')"; then
    verdict true "Could not read job ${name}'s annotations to check for a lost runner."
  fi
  if grep -qF "$MARKER" <<<"$messages"; then
    unacquired="${unacquired}${unacquired:+, }${name}"
  else
    others="${others}${others:+, }${name}"
  fi
done <<<"$unfinished"

if [ -z "$unacquired" ]; then
  verdict true ""
fi

if ! newest="$(read_newest)"; then
  verdict true "GitHub gave no runner to ${unacquired}; could not check for a newer run, so not re-run."
fi
read -r newest_id _ <<<"$newest"
if [ "$newest_id" != "$RUN_ID" ]; then
  if [ -n "$others" ]; then
    verdict true "GitHub gave no runner to ${unacquired}, and ${others} did not pass either; not re-run, because a newer commit's run would be cancelled by it."
  fi
  await_newest "GitHub gave no runner to ${unacquired}; not re-run, because a newer commit's run would be cancelled by it"
fi

if [ "${DRY_RUN:-}" = "1" ]; then
  verdict false "DRY_RUN: would re-run and wait; GitHub gave no runner to: ${unacquired}."
fi

if ! timeout "$API_TIMEOUT" gh run rerun "$RUN_ID" --failed -R "$REPO"; then
  verdict true "GitHub gave no runner to ${unacquired}, and re-running it failed."
fi
echo "GitHub gave no runner to ${unacquired}; re-ran the failed jobs, waiting up to ${WAIT_MINUTES} min."

while [ "$(date +%s)" -lt "$deadline" ]; do
  sleep "$POLL_SECONDS"
  # One transient API error must not page; keep polling until the deadline.
  state="$(api "repos/${REPO}/actions/runs/${RUN_ID}" \
    --jq '"\(.run_attempt) \(.status) \(.conclusion // "")"')" || continue
  read -r attempt status conclusion <<<"$state"
  echo "attempt ${attempt}: ${status} ${conclusion}"
  if ! [ "$attempt" -ge 2 ] 2>/dev/null || [ "$status" != "completed" ]; then
    continue
  fi
  case "$conclusion" in
    success)
      verdict false "GitHub gave no runner to ${unacquired}; the automatic re-run passed." ;;
    cancelled | skipped)
      # A newer push cancelling it is the usual cause, and only that push's run can answer.
      if [ -n "$others" ]; then
        verdict true "GitHub gave no runner to ${unacquired}, and ${others} did not pass either; the re-run was ${conclusion}."
      fi
      await_newest "GitHub gave no runner to ${unacquired}; the re-run was ${conclusion}" ;;
    *)
      verdict true "GitHub gave no runner to ${unacquired} on attempt 1; the automatic re-run then concluded ${conclusion}." ;;
  esac
done
verdict true "GitHub gave no runner to ${unacquired}; the automatic re-run had not finished after ${WAIT_MINUTES} min."
