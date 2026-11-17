#!/usr/bin/env bash
# Decide whether a failed main-branch run is GitHub never handing a job a runner, and if so
# re-run it and wait for the answer, instead of paging #alerts for a failure no code caused.
#
# A hosted job that waits too long for a runner is given up with the check-run annotation
# "The job was not acquired by Runner of type hosted even after multiple attempts", about 15
# minutes after it queued. GitHub does that, not this repo: no setting here moves it. A macOS
# arm64 capacity shortage does it to the iOS jobs in `ci.yml`, the shards in `ios-ui-tests.yml`
# and `upload` in `testflight.yml`; GitHub marks such a job "Due to capacity constraints, jobs
# targeting macOS arm64 runners may experience longer queue times". Re-running the failed jobs
# is the whole fix, once the shortage eases.
#
# It waits on the re-run here rather than leaving each attempt to page on its own. Whether a
# re-run requested with GITHUB_TOKEN fires `workflow_run` when it completes has varied: none
# did on 2026-10-29, and one did on 2026-11-17 (run 44137247444, attempt 2). So the listener
# that re-ran a run owns its answer, and a listener for a later attempt the bot re-ran stays
# quiet and leaves it to that owner.
#
# From attempt 1 only, and again for as long as every job that did not pass on the newest
# attempt is a lost runner, up to MAX_RERUNS re-runs inside the WAIT_MINUTES budget. A shortage
# outlasts one wait for a runner: on run 44137247444 it outlasted two. `gh run rerun --failed`
# re-runs every failed and cancelled job, so a real failure sitting beside the lost one runs
# once more and pages if it fails again; a run where any job ran and failed is never re-run a
# second time. A shortage that outlasts the budget or the cap pages, saying so.
#
# Only while the run is still the newest of its workflow on main. A re-run joins the
# workflow's concurrency group like a new run, so re-running an older commit would cancel the
# newer commit's run (`ci.yml` cancels in progress), and a cancelled run never pages: main's
# newest commit would be left with no CI answer and nobody told.
#
# A superseded run waits for the newest run's answer instead, and the same wait covers a
# re-run a newer push cancelled. A human has nothing to do while that answer is coming: a
# failed newest run reaches this same listener, where a lost runner gets its re-runs and
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
# for the whole script, every re-run and the newer run together. Room for two lost ~15-minute
# waits and then `testflight.yml`'s whole 105-minute upload.
WAIT_MINUTES="${WAIT_MINUTES:-170}"
# Each lost attempt costs about 15 minutes, so the budget caps it near this anyway; the cap
# stops a fast-failing loop from re-running without end.
MAX_RERUNS="${MAX_RERUNS:-6}"
# Who a re-run requested with GITHUB_TOKEN is triggered by.
RERUN_ACTOR="github-actions[bot]"
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

# Sort attempt $1's unfinished jobs into `unacquired` (no runner ever picked it up), `others`
# (anything else that did not pass, bar the gate job) and `must_run` (every one of them).
classify() {
  local attempt="$1" unfinished id conclusion name messages
  if ! unfinished="$(api --paginate "repos/${REPO}/actions/runs/${RUN_ID}/attempts/${attempt}/jobs" \
      --jq '.jobs[] | select(.conclusion != "success" and .conclusion != "skipped") | "\(.id) \(.conclusion) \(.name)"')"; then
    verdict true "Could not list attempt ${attempt}'s jobs to check for a lost runner."
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
}

if [ "$RUN_ATTEMPT" != "1" ]; then
  # A re-run requested with GITHUB_TOKEN can fire this listener when it completes (seen on
  # run 44137247444, 2026-11-17), and the listener that requested it is still waiting on that
  # same attempt and pages if it did not pass. Answering here too pages twice, or re-runs
  # behind that listener's back. Any other re-run, such as a human's, has nobody waiting on
  # it, so it pages here. An actor that cannot be read pages.
  actor="$(api "repos/${REPO}/actions/runs/${RUN_ID}/attempts/${RUN_ATTEMPT}" --jq '.triggering_actor.login')" || actor=""
  if [ "$actor" = "$RERUN_ACTOR" ]; then
    verdict false "Attempt ${RUN_ATTEMPT} is the listener's own re-run; the listener waiting on it answers for it."
  fi
  verdict true ""
fi

classify 1
if [ -z "$unacquired" ]; then
  verdict true ""
fi
first_lost="$unacquired"

attempt=1
reruns=0
while :; do
  if [ "$reruns" -eq 0 ]; then
    lost="GitHub gave no runner to ${unacquired}"
  else
    lost="GitHub gave no runner to ${first_lost} on attempt 1, nor to ${unacquired} on attempt ${attempt}"
  fi

  # A real failure gets the one re-run it shares with the lost runner, and pages if it fails
  # again: a lost runner is a reason to try again, never a reason to excuse another job.
  if [ "$reruns" -gt 0 ] && [ -n "$others" ]; then
    verdict true "${lost}, and ${others} did not pass on the re-run either."
  fi

  if ! newest="$(read_newest)"; then
    verdict true "${lost}; could not check for a newer run, so not re-run."
  fi
  read -r newest_id _ <<<"$newest"
  if [ "$newest_id" != "$RUN_ID" ]; then
    if [ -n "$others" ]; then
      verdict true "${lost}, and ${others} did not pass either; not re-run, because a newer commit's run would be cancelled by it."
    fi
    await_newest "${lost}; not re-run, because a newer commit's run would be cancelled by it"
  fi

  if [ "${DRY_RUN:-}" = "1" ]; then
    verdict false "DRY_RUN: would re-run and wait; ${lost}."
  fi

  # A shortage of macOS arm64 capacity outlasts one ~15-minute wait for a runner: on run
  # 44137247444 it outlasted two. So a run that lost nothing but runners is re-run again,
  # until the budget or the re-run cap runs out, and only then pages.
  if [ "$reruns" -ge "$MAX_RERUNS" ]; then
    verdict true "${lost}; a GitHub hosted-runner shortage outlasted ${reruns} automatic re-runs, so it did not run."
  fi
  if [ "$reruns" -gt 0 ] && [ "$(date +%s)" -ge "$deadline" ]; then
    verdict true "${lost}; a GitHub hosted-runner shortage outlasted the ${WAIT_MINUTES}-minute wait, so it did not run."
  fi

  if ! timeout "$API_TIMEOUT" gh run rerun "$RUN_ID" --failed -R "$REPO"; then
    verdict true "${lost}, and re-running it failed."
  fi
  reruns=$((reruns + 1))
  echo "${lost}; re-ran the failed jobs (re-run ${reruns} of at most ${MAX_RERUNS}), waiting until the ${WAIT_MINUTES}-minute budget runs out."

  conclusion=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep "$POLL_SECONDS"
    # One transient API error must not page; keep polling until the deadline.
    state="$(api "repos/${REPO}/actions/runs/${RUN_ID}" \
      --jq '"\(.run_attempt) \(.status) \(.conclusion // "")"')" || continue
    read -r seen status concl <<<"$state"
    echo "attempt ${seen}: ${status} ${concl}"
    if ! [ "$seen" -gt "$attempt" ] 2>/dev/null || [ "$status" != "completed" ]; then
      continue
    fi
    attempt="$seen"
    conclusion="$concl"
    break
  done
  if [ -z "$conclusion" ]; then
    verdict true "${lost}; the automatic re-run had not finished after ${WAIT_MINUTES} min."
  fi

  case "$conclusion" in
    success)
      verdict false "${lost}; automatic re-run ${reruns} passed." ;;
    cancelled | skipped)
      # A newer push cancelling it is the usual cause, and only that push's run can answer.
      if [ -n "$others" ]; then
        verdict true "${lost}, and ${others} did not pass either; the re-run was ${conclusion}."
      fi
      await_newest "${lost}; the re-run was ${conclusion}" ;;
    failure)
      # Lost runners again, and nothing else: go round. Anything else pages above.
      classify "$attempt"
      if [ -z "$unacquired" ]; then
        verdict true "GitHub gave no runner to ${first_lost} on attempt 1; automatic re-run ${reruns} got one and then concluded failure."
      fi ;;
    *)
      verdict true "${lost}; automatic re-run ${reruns} then concluded ${conclusion}." ;;
  esac
done
