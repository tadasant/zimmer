#!/usr/bin/env bash
# Drives rerun-unacquired-jobs.sh against a stub `gh` through every verdict it can reach.
# The script only runs for real from main's copy of alert-ci-failure.yml, after a real
# runner loss, so this is the only place its paging logic is exercised before it matters.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# The stub serves JSON and runs the caller's real --jq over it, so the filters are under test.
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Answers from STUB_* variables; logs re-runs to $STUB_LOG.
filter=""
args=("$@")
for i in "${!args[@]}"; do
  [ "${args[$i]}" = "--jq" ] && filter="${args[$((i + 1))]}"
done
serve() { jq -r "$filter" <<<"$1"; }

# Lines of `<conclusion> <name>` into a jobs response. A passed and a skipped job always sit
# alongside, as they do in a real run.
jobs_json() {
  { echo "1 success passed-job"; echo "2 skipped skipped-job"; printf '%s\n' "$1"; } | jq -Rs '
    {jobs: [split("\n")[] | select(. != "") | capture("^(?<id>[0-9]+) (?<conclusion>[^ ]+) (?<name>.*)$")]}'
}

case "$*" in
  *alert-ci-failure.yml/runs*)
    # Other listener runs in progress; this listener is run 99 and must not count itself.
    [ "${STUB_OWNERS:-}" = fail ] && exit 1
    serve "$(jq -n --argjson n "${STUB_OWNERS:-1}" '{workflow_runs: ([{id: 99}] + [range($n) | {id: (100 + .)}])}')" ;;
  *attempts/1/jobs*)
    [ "${STUB_JOBS_FAIL:-}" = 1 ] && exit 1
    serve "$(jobs_json "${STUB_UNFINISHED:-}")" ;;
  *attempts/*/jobs*)
    # Attempt N's jobs are the (N-1)th of STUB_RERUN_JOBS's `|`-separated answers, the last
    # one repeating: a real failure unless a case says otherwise.
    [ "${STUB_RERUN_JOBS:-}" = fail ] && exit 1
    n="$*"; n="${n#*attempts/}"; n="${n%%/*}"
    IFS='|' read -r -d '' -a rerun_jobs <<<"${STUB_RERUN_JOBS:-11 failure ios}"
    rerun_jobs[-1]="${rerun_jobs[-1]%$'\n'}"
    serve "$(jobs_json "${rerun_jobs[$(( n - 1 <= ${#rerun_jobs[@]} ? n - 2 : ${#rerun_jobs[@]} - 1 ))]}")" ;;
  *actions/runs/*/attempts/*)
    # Who triggered a later attempt: a human unless STUB_ACTOR says otherwise.
    [ "${STUB_ACTOR:-}" = fail ] && exit 1
    serve "$(jq -n --arg a "${STUB_ACTOR:-a-human}" '{triggering_actor: {login: $a}}')" ;;
  *check-runs/*/annotations*)
    [ "${STUB_ANN_FAIL:-}" = 1 ] && exit 1
    # STUB_ANN_PLAIN names the job ids that were cancelled some other way.
    id="${args[1]#*check-runs/}"; id="${id%%/*}"
    case " ${STUB_ANN_PLAIN:-} " in *" $id "*) message="The operation was canceled." ;; *) message="${STUB_ANN:-}" ;; esac
    serve "$(jq -n --arg m "$message" '[{message: $m}]')" ;;
  *compare/*)
    [ "${STUB_COMPARE:-}" = fail ] && exit 1
    # Against the old commit: the script must ask how the newest run stands relative to it.
    case "$*" in
      *compare/abc...*) serve "$(jq -n --arg s "${STUB_COMPARE:-ahead}" '{status: $s}')" ;;
      *) serve '{"status": "behind"}' ;;
    esac ;;
  *actions/workflows/*/runs*)
    # STUB_LATEST is one answer per call, split on `|`, and the last one repeats. Each is
    # `<id> <sha> <status> <conclusion> <event>`, `-` for no conclusion, or `empty` or `fail`.
    calls=$(( $(cat "$STUB_LOG.latest" 2>/dev/null || echo 0) + 1 ))
    echo "$calls" > "$STUB_LOG.latest"
    IFS='|' read -r -a answers <<<"${STUB_LATEST:-$THIS_RUN}"
    answer="${answers[$(( calls <= ${#answers[@]} ? calls - 1 : ${#answers[@]} - 1 ))]}"
    [ "$answer" = fail ] && exit 1
    [ "$answer" = empty ] && { serve '{"workflow_runs": []}'; exit 0; }
    read -r id sha status conclusion event <<<"$answer"
    # A query for one trigger does not see another's run; this run is then the newest.
    case "$*" in
      *"&event="*) case "$*" in *"&event=${event}"*) ;; *) read -r id sha status conclusion event <<<"$THIS_RUN" ;; esac ;;
    esac
    serve "$(jq -n --argjson id "$id" --arg sha "$sha" --arg status "$status" --arg conclusion "$conclusion" \
      --arg event "$event" '{workflow_runs: [{id: $id, head_sha: $sha, status: $status, event: $event,
        conclusion: (if $conclusion == "-" then null else $conclusion end)}]}')" ;;
  "run rerun"*)
    echo rerun >> "$STUB_LOG"
    rm -f "$STUB_LOG.polls"
    [ "${STUB_RERUN_FAIL:-}" = 1 ] && exit 1
    exit 0 ;;
  *actions/runs/*/jobs*)
    [ "${STUB_NEWEST_JOBS:-}" = fail ] && exit 1
    serve "$(jobs_json "${STUB_NEWEST_JOBS:-5 success ios}")" ;;
  *actions/runs/*)
    # Re-run N is attempt N+1: queued on its first poll, then completed with the Nth of
    # STUB_FINAL's `|`-separated conclusions, the last one repeating.
    reruns=$(grep -c rerun "$STUB_LOG")
    polls=$(( $(cat "$STUB_LOG.polls" 2>/dev/null || echo 0) + 1 ))
    echo "$polls" > "$STUB_LOG.polls"
    IFS='|' read -r -a finals <<<"${STUB_FINAL:-}"
    final="${finals[$(( reruns <= ${#finals[@]} ? reruns - 1 : ${#finals[@]} - 1 ))]:-}"
    if [ "$polls" -lt 2 ]; then echo "$((reruns + 1)) queued "; else echo "$((reruns + 1)) completed ${final}"; fi ;;
esac
STUB
chmod +x "$tmp/bin/gh"

lost="The job was not acquired by Runner of type hosted even after multiple attempts"
this_run="7 abc completed failure push"
failures=0

# expect <name> <page> <reruns> [VAR=value ...]
expect() {
  local name="$1" want_page="$2" want_reruns="$3"
  shift 3
  rm -f "$tmp/log" "$tmp/log.polls" "$tmp/log.latest" "$tmp/out"
  touch "$tmp/log"
  env PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/log" GITHUB_OUTPUT="$tmp/out" THIS_RUN="$this_run" \
    GITHUB_RUN_ID=99 RERUN_RESERVE_MINUTES=0 REPO=o/r RUN_ID=7 RUN_ATTEMPT=1 WORKFLOW_ID=9 HEAD_SHA=abc RUN_EVENT=push POLL_SECONDS=0 \
    WAIT_MINUTES=1 "$@" \
    bash "$here/rerun-unacquired-jobs.sh" > /dev/null 2>&1
  local page reruns note
  page="$(sed -n 's/^page=//p' "$tmp/out")"
  note="$(sed -n 's/^note=//p' "$tmp/out")"
  reruns="$(grep -c rerun "$tmp/log")"
  if [ "$page" = "$want_page" ] && [ "$reruns" = "$want_reruns" ]; then
    echo "ok   ${name}: page=${page} reruns=${reruns} note=${note}"
  else
    echo "FAIL ${name}: page=${page:-<unset>} reruns=${reruns}, wanted page=${want_page} reruns=${want_reruns}; note=${note}"
    failures=$((failures + 1))
  fi
}

ios="STUB_UNFINISHED=11 cancelled ios"
ann="STUB_ANN=$lost"
queued="20 def queued - push"
running="20 def in_progress - push"
passed="20 def completed success push"

expect "a human's attempt 2 pages"         true  0 RUN_ATTEMPT=2
expect "the listener's own attempt 2 is quiet" false 0 RUN_ATTEMPT=2 STUB_ACTOR="github-actions[bot]"
expect "an unreadable attempt 2 actor pages" true 0 RUN_ATTEMPT=2 STUB_ACTOR=fail
expect "the listener's own attempt 2 with no listener left pages" true 0 RUN_ATTEMPT=2 \
  STUB_ACTOR="github-actions[bot]" STUB_OWNERS=0
expect "the listener's own attempt 2, listeners unreadable, pages" true 0 RUN_ATTEMPT=2 \
  STUB_ACTOR="github-actions[bot]" STUB_OWNERS=fail
expect "a re-run too late to finish is not started" true 1 "$ios" "$ann" RERUN_RESERVE_MINUTES=5 \
  STUB_FINAL=failure STUB_RERUN_JOBS="11 cancelled ios"
expect "unlistable jobs page"              true  0 STUB_JOBS_FAIL=1
expect "no cancelled job pages"            true  0
expect "an ordinary cancel pages"          true  0 "$ios" STUB_ANN="The operation was canceled."
expect "unreadable annotations page"       true  0 "$ios" STUB_ANN_FAIL=1
expect "a failed re-run request pages"     true  1 "$ios" "$ann" STUB_RERUN_FAIL=1
expect "a re-run that passes is quiet"     false 1 "$ios" "$ann" STUB_FINAL=success
expect "a re-run that fails pages"         true  1 "$ios" "$ann" STUB_FINAL=failure
expect "a re-run that loses its runner again goes round" false 2 "$ios" "$ann" \
  STUB_FINAL="failure|success" STUB_RERUN_JOBS="11 cancelled ios"
expect "a shortage longer than the cap pages" true 3 "$ios" "$ann" MAX_RERUNS=3 \
  STUB_FINAL=failure STUB_RERUN_JOBS="11 cancelled ios"
expect "a lost runner, then a real failure, pages" true 2 "$ios" "$ann" \
  STUB_FINAL="failure|failure" STUB_RERUN_JOBS="11 cancelled ios|11 failure ios"
expect "a real failure beside the lost runner gets one re-run" true 1 "$ann" STUB_FINAL=failure \
  STUB_UNFINISHED="$(printf '11 cancelled ios\n12 failure lint')" \
  STUB_RERUN_JOBS="$(printf '11 cancelled ios\n12 failure lint')"
expect "a gate job beside the lost runner goes round" false 2 "$ann" STUB_FINAL="failure|success" \
  STUB_UNFINISHED="$(printf '11 cancelled ios\n12 failure all-checks-pass')" \
  STUB_RERUN_JOBS="$(printf '11 cancelled ios\n12 failure all-checks-pass')"
expect "an unlistable re-run pages"        true  1 "$ios" "$ann" STUB_FINAL=failure STUB_RERUN_JOBS=fail
expect "a re-run that never ends pages"    true  1 "$ios" "$ann" STUB_FINAL=x WAIT_MINUTES=0
expect "a dry run decides without acting"  false 0 "$ios" "$ann" DRY_RUN=1

# Superseded: the newest run answers, or this pages.
expect "superseded: newest passed"            false 0 "$ios" "$ann" STUB_LATEST="$passed"
expect "superseded: waits for the pass"       false 0 "$ios" "$ann" STUB_LATEST="$queued|$running|$passed"
expect "superseded: same commit, newer run"   false 0 "$ios" "$ann" STUB_COMPARE=identical \
  STUB_LATEST="20 abc completed success push"
expect "superseded: newest failed, its own alert answers" false 0 "$ios" "$ann" \
  STUB_LATEST="20 def completed failure push"
expect "superseded: newest lost a runner too, its own alert answers" false 0 "$ios" "$ann" \
  STUB_LATEST="20 def completed failure push" STUB_NEWEST_JOBS="5 cancelled ios"
expect "superseded: gate job beside it, newest did not skip" false 0 "$ann" STUB_LATEST="$passed" \
  STUB_UNFINISHED="$(printf '11 cancelled ios\n12 failure all-checks-pass')" \
  STUB_NEWEST_JOBS="$(printf '5 success ios\n6 success all-checks-pass')"
expect "superseded: replaced by a newer push" false 0 "$ios" "$ann" \
  STUB_LATEST="$queued|$queued|30 fed completed success push"
expect "superseded: one failed read is not an answer" false 0 "$ios" "$ann" \
  STUB_LATEST="$queued|fail|$passed"
expect "superseded: unreadable pages"         true  0 "$ios" "$ann" STUB_LATEST=fail
expect "superseded: unreadable mid-wait pages at the deadline" true 0 "$ios" "$ann" \
  STUB_LATEST="$queued|fail" WAIT_MINUTES=0
expect "superseded: unreadable jobs page at the deadline" true 0 "$ios" "$ann" \
  STUB_LATEST="$passed" STUB_NEWEST_JOBS=fail WAIT_MINUTES=0
expect "superseded: unreadable compare pages at the deadline" true 0 "$ios" "$ann" \
  STUB_LATEST="$passed" STUB_COMPARE=fail WAIT_MINUTES=0
expect "superseded: empty list pages"         true  0 "$ios" "$ann" STUB_LATEST=empty
expect "superseded: an older run on top pages" true 0 "$ios" "$ann" STUB_LATEST="5 def completed success push"
expect "superseded: newest cancelled pages"   true  0 "$ios" "$ann" STUB_LATEST="20 def completed cancelled push"
expect "superseded: newest neutral pages"     true  0 "$ios" "$ann" STUB_LATEST="20 def completed neutral push"
expect "superseded: newest never ends pages"  true  0 "$ios" "$ann" STUB_LATEST="$queued" WAIT_MINUTES=0
expect "superseded: only another trigger is newer" true 0 "$ios" "$ann" STUB_LATEST="20 def completed success workflow_dispatch"
expect "superseded: only a fork's pull_request is newer" true 0 "$ios" "$ann" STUB_LATEST="20 def completed success pull_request"
expect "superseded: a dispatched run pages"   true  0 "$ios" "$ann" RUN_EVENT=workflow_dispatch \
  STUB_LATEST="20 def completed success workflow_dispatch"
expect "superseded: newest lacks the commit"  true  0 "$ios" "$ann" STUB_LATEST="$passed" STUB_COMPARE=behind
expect "superseded: newest skipped the job"   true  0 "$ios" "$ann" STUB_LATEST="$passed" \
  STUB_NEWEST_JOBS="$(printf '5 success ios-changes\n6 skipped ios')"
expect "superseded: newest skipped one shard of two" true 0 "$ann" STUB_LATEST="$passed" \
  STUB_UNFINISHED="$(printf '11 cancelled ui-test (a)\n12 cancelled ui-test (b)')" \
  STUB_NEWEST_JOBS="$(printf '5 success ui-test (a)\n6 skipped ui-test (b)')"
expect "superseded: a real failure beside it pages" true 0 "$ann" STUB_LATEST="$passed" \
  STUB_UNFINISHED="$(printf '11 cancelled ios\n12 failure lint')" \
  STUB_NEWEST_JOBS="$(printf '5 success ios\n6 success lint')"
expect "superseded: an ordinary cancel beside it pages" true 0 "$ann" STUB_LATEST="$passed" STUB_ANN_PLAIN=12 \
  STUB_UNFINISHED="$(printf '11 cancelled ios\n12 cancelled lint')"
expect "superseded: dry run reports the wait" false 0 "$ios" "$ann" STUB_LATEST="$queued" DRY_RUN=1
expect "superseded: dry run rules on a finished run" true 0 "$ios" "$ann" STUB_LATEST="20 def completed cancelled push" DRY_RUN=1

# The re-run itself cancelled: only a newer run can answer for it.
expect "re-run cancelled, newer run passed"   false 1 "$ios" "$ann" STUB_FINAL=cancelled \
  STUB_LATEST="$this_run|$passed"
expect "re-run cancelled, gate beside it passed" false 1 "$ann" STUB_FINAL=cancelled \
  STUB_LATEST="$this_run|$passed" \
  STUB_UNFINISHED="$(printf '11 cancelled ios\n12 failure all-checks-pass')" \
  STUB_NEWEST_JOBS="$(printf '5 success ios\n6 success all-checks-pass')"
expect "re-run cancelled, a real failure beside it pages" true 1 "$ann" STUB_FINAL=cancelled \
  STUB_LATEST="$this_run|$passed" \
  STUB_UNFINISHED="$(printf '11 cancelled ios\n12 failure test-unit')" \
  STUB_NEWEST_JOBS="$(printf '5 success ios\n6 success test-unit')"
expect "re-run cancelled, nothing newer pages" true 1 "$ios" "$ann" STUB_FINAL=cancelled
expect "re-run skipped, nothing newer pages"  true  1 "$ios" "$ann" STUB_FINAL=skipped
expect "re-run cancelled, newer skipped it"   true  1 "$ios" "$ann" STUB_FINAL=cancelled \
  STUB_LATEST="$this_run|$passed" STUB_NEWEST_JOBS="6 skipped ios"

if [ "$failures" -gt 0 ]; then
  echo "::error::${failures} rerun-unacquired-jobs.sh case(s) failed."
  exit 1
fi
