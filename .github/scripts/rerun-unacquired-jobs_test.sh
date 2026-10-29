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
    printf '%s\n' "${STUB_CANCELLED:-}" ;;
  *check-runs/*/annotations*) printf '%s\n' "${STUB_ANN:-}" ;;
  *actions/workflows/*/runs*) printf '%s\n' "${STUB_NEWEST:-abc}" ;;
  "run rerun"*)
    echo rerun >> "$STUB_LOG"
    [ "${STUB_RERUN_FAIL:-}" = 1 ] && exit 1
    exit 0 ;;
  *actions/runs/*)
    polls=$(( $(cat "$STUB_LOG.polls" 2>/dev/null || echo 0) + 1 ))
    echo "$polls" > "$STUB_LOG.polls"
    if [ "$polls" -lt 2 ]; then echo "2 queued "; else echo "2 completed ${STUB_FINAL:-}"; fi ;;
esac
STUB
chmod +x "$tmp/bin/gh"

lost="The job was not acquired by Runner of type hosted even after multiple attempts"
failures=0

# expect <name> <page> <reruns> [VAR=value ...]
expect() {
  local name="$1" want_page="$2" want_reruns="$3"
  shift 3
  rm -f "$tmp/log" "$tmp/log.polls" "$tmp/out"
  touch "$tmp/log"
  env PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/log" GITHUB_OUTPUT="$tmp/out" \
    REPO=o/r RUN_ID=7 RUN_ATTEMPT=1 WORKFLOW_ID=9 HEAD_SHA=abc POLL_SECONDS=0 "$@" \
    bash "$here/rerun-unacquired-jobs.sh" > /dev/null 2>&1
  local page reruns
  page="$(sed -n 's/^page=//p' "$tmp/out")"
  reruns="$(grep -c rerun "$tmp/log")"
  if [ "$page" = "$want_page" ] && [ "$reruns" = "$want_reruns" ]; then
    echo "ok   ${name}"
  else
    echo "FAIL ${name}: page=${page:-<unset>} reruns=${reruns}, wanted page=${want_page} reruns=${want_reruns}"
    failures=$((failures + 1))
  fi
}

expect "attempt 2 always pages"            true  0 RUN_ATTEMPT=2
expect "unlistable jobs page"              true  0 STUB_JOBS_FAIL=1
expect "no cancelled job pages"            true  0
expect "an ordinary cancel pages"          true  0 STUB_CANCELLED="11 ios" STUB_ANN="The operation was canceled."
expect "a superseded run is not re-run"    true  0 STUB_CANCELLED="11 ios" STUB_ANN="$lost" STUB_NEWEST=def
expect "a failed re-run request pages"     true  1 STUB_CANCELLED="11 ios" STUB_ANN="$lost" STUB_RERUN_FAIL=1
expect "a re-run that passes is quiet"     false 1 STUB_CANCELLED="11 ios" STUB_ANN="$lost" STUB_FINAL=success
expect "a re-run superseded is quiet"      false 1 STUB_CANCELLED="11 ios" STUB_ANN="$lost" STUB_FINAL=cancelled
expect "a re-run that fails pages"         true  1 STUB_CANCELLED="11 ios" STUB_ANN="$lost" STUB_FINAL=failure
expect "a re-run that never ends pages"    true  1 STUB_CANCELLED="11 ios" STUB_ANN="$lost" STUB_FINAL=x WAIT_MINUTES=0
expect "a dry run decides without acting"  false 0 STUB_CANCELLED="11 ios" STUB_ANN="$lost" DRY_RUN=1

if [ "$failures" -gt 0 ]; then
  echo "::error::${failures} rerun-unacquired-jobs.sh case(s) failed."
  exit 1
fi
