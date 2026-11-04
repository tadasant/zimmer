#!/usr/bin/env bash
# Drives rerun-unacquired-jobs.sh against a stub `gh` through every verdict it can reach.
# The script only runs for real from main's copy of alert-ci-failure.yml, after a real
# runner loss, so this is the only place its paging logic is exercised before it matters.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Answers from STUB_* variables; logs re-runs to $STUB_LOG.
case "$*" in
  *attempts/1/jobs*)
    [ "${STUB_JOBS_FAIL:-}" = 1 ] && exit 1
    printf '%s\n' "${STUB_UNFINISHED:-}" ;;
  *check-runs/*/annotations*) printf '%s\n' "${STUB_ANN:-}" ;;
  *compare/*)
    [ "${STUB_COMPARE:-}" = fail ] && exit 1
    printf '%s\n' "${STUB_COMPARE:-ahead}" ;;
  *actions/workflows/*/runs*)
    # STUB_LATEST is one answer per call, split on `|`, and the last one repeats.
    calls=$(( $(cat "$STUB_LOG.latest" 2>/dev/null || echo 0) + 1 ))
    echo "$calls" > "$STUB_LOG.latest"
    IFS='|' read -r -a answers <<<"${STUB_LATEST:-$THIS_RUN}"
    index=$(( calls <= ${#answers[@]} ? calls - 1 : ${#answers[@]} - 1 ))
    [ "${answers[$index]}" = fail ] && exit 1
    printf '%s\n' "${answers[$index]}" ;;
  "run rerun"*)
    echo rerun >> "$STUB_LOG"
    [ "${STUB_RERUN_FAIL:-}" = 1 ] && exit 1
    exit 0 ;;
  *actions/runs/*/jobs*)
    [ "${STUB_RAN:-}" = fail ] && exit 1
    printf '%s\n' "${STUB_RAN:-ios}" ;;
  *actions/runs/*)
    polls=$(( $(cat "$STUB_LOG.polls" 2>/dev/null || echo 0) + 1 ))
    echo "$polls" > "$STUB_LOG.polls"
    if [ "$polls" -lt 2 ]; then echo "2 queued "; else echo "2 completed ${STUB_FINAL:-}"; fi ;;
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
    REPO=o/r RUN_ID=7 RUN_ATTEMPT=1 WORKFLOW_ID=9 HEAD_SHA=abc RUN_EVENT=push POLL_SECONDS=0 "$@" \
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

expect "attempt 2 always pages"            true  0 RUN_ATTEMPT=2
expect "unlistable jobs page"              true  0 STUB_JOBS_FAIL=1
expect "no cancelled job pages"            true  0
expect "an ordinary cancel pages"          true  0 "$ios" STUB_ANN="The operation was canceled."
expect "a failed re-run request pages"     true  1 "$ios" "$ann" STUB_RERUN_FAIL=1
expect "a re-run that passes is quiet"     false 1 "$ios" "$ann" STUB_FINAL=success
expect "a re-run that fails pages"         true  1 "$ios" "$ann" STUB_FINAL=failure
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
  STUB_LATEST="20 def completed failure push" STUB_RAN="ios"
expect "superseded: replaced by a newer push" false 0 "$ios" "$ann" \
  STUB_LATEST="$queued|$queued|30 fed completed success push"
expect "superseded: one failed read is not an answer" false 0 "$ios" "$ann" \
  STUB_LATEST="$queued|fail|$passed"
expect "superseded: unreadable pages"         true  0 "$ios" "$ann" STUB_LATEST=fail
expect "superseded: unreadable mid-wait pages at the deadline" true 0 "$ios" "$ann" \
  STUB_LATEST="$queued|fail" WAIT_MINUTES=0
expect "superseded: unreadable jobs page at the deadline" true 0 "$ios" "$ann" \
  STUB_LATEST="$passed" STUB_RAN=fail WAIT_MINUTES=0
expect "superseded: unreadable compare pages at the deadline" true 0 "$ios" "$ann" \
  STUB_LATEST="$passed" STUB_COMPARE=fail WAIT_MINUTES=0
expect "superseded: empty list pages"         true  0 "$ios" "$ann" STUB_LATEST="null null null - null"
expect "superseded: an older run on top pages" true 0 "$ios" "$ann" STUB_LATEST="5 def completed success push"
expect "superseded: newest cancelled pages"   true  0 "$ios" "$ann" STUB_LATEST="20 def completed cancelled push"
expect "superseded: newest neutral pages"     true  0 "$ios" "$ann" STUB_LATEST="20 def completed neutral push"
expect "superseded: newest never ends pages"  true  0 "$ios" "$ann" STUB_LATEST="$queued" WAIT_MINUTES=0
expect "superseded: other trigger pages"      true  0 "$ios" "$ann" STUB_LATEST="20 def completed success workflow_dispatch"
expect "superseded: a fork's pull_request pages" true 0 "$ios" "$ann" STUB_LATEST="20 def completed success pull_request"
expect "superseded: newest lacks the commit"  true  0 "$ios" "$ann" STUB_LATEST="$passed" STUB_COMPARE=behind
expect "superseded: newest skipped the job"   true  0 "$ios" "$ann" STUB_LATEST="$passed" STUB_RAN="lint"
expect "superseded: newest ran one shard of two" true 0 "$ann" STUB_LATEST="$passed" STUB_RAN="ui-test (a)" \
  STUB_UNFINISHED="$(printf '11 cancelled ui-test (a)\n12 cancelled ui-test (b)')"
expect "superseded: a real failure beside it pages" true 0 "$ann" STUB_LATEST="$passed" STUB_RAN="$(printf 'ios\nlint')" \
  STUB_UNFINISHED="$(printf '11 cancelled ios\n12 failure lint')"
expect "superseded: dry run reports the wait" false 0 "$ios" "$ann" STUB_LATEST="$queued" DRY_RUN=1
expect "superseded: dry run rules on a finished run" true 0 "$ios" "$ann" STUB_LATEST="20 def completed cancelled push" DRY_RUN=1

# The re-run itself cancelled: only a newer run can answer for it.
expect "re-run cancelled, newer run passed"   false 1 "$ios" "$ann" STUB_FINAL=cancelled \
  STUB_LATEST="$this_run|$passed"
expect "re-run cancelled, gate beside it passed" false 1 "$ann" STUB_FINAL=cancelled \
  STUB_LATEST="$this_run|$passed" STUB_RAN="$(printf 'ios\nall-checks-pass')" \
  STUB_UNFINISHED="$(printf '11 cancelled ios\n12 failure all-checks-pass')"
expect "re-run cancelled, nothing newer pages" true 1 "$ios" "$ann" STUB_FINAL=cancelled
expect "re-run skipped, nothing newer pages"  true  1 "$ios" "$ann" STUB_FINAL=skipped
expect "re-run cancelled, newer skipped it"   true  1 "$ios" "$ann" STUB_FINAL=cancelled \
  STUB_LATEST="$this_run|$passed" STUB_RAN="lint"

if [ "$failures" -gt 0 ]; then
  echo "::error::${failures} rerun-unacquired-jobs.sh case(s) failed."
  exit 1
fi
