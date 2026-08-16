#!/usr/bin/env bash
# Zimmer worker watchdog -- catch the worker container that reports `running` while
# `docker exec` into it is permanently broken.
#
# THE FAILURE THIS EXISTS FOR (issue #502)
# ----------------------------------------
# Under `sysbox-runc`, a cgroup out-of-memory kill can empty the worker container of
# every process while Docker still reports `Status=running, Restarts=0`. The kill
# lands inside the cgroup, which is exactly what `memory: 2g` in
# config/deploy.<dest>.yml is for -- but the container never *exits*, so
# `unless-stopped` never fires and nothing that reads container state notices. The
# worker keeps its slot, passes every container-shaped health check, and runs no jobs
# and no agent sessions. On production that is a silent outage.
#
# So this probe does not read container state. It runs a real `docker exec`, which is
# the operation that actually breaks, and treats "container running + exec fails" as
# the signature. Everything else it collects -- OOMKilled, the cgroup's oom_kill
# counter, the live-process census -- is evidence for the human, not the trigger.
#
# WHY IT RUNS ON THE HOST
# -----------------------
# The wedged container cannot report on itself, and the app cannot report on it
# either: GoodJob cron runs *in the worker*, so a job that watches the worker is a job
# that dies with it. The web container survives, which is why the alert is delivered
# through it (see `alert` below) -- but the detection has to sit outside Docker
# entirely, on the host, in systemd.
#
# WHAT IT DOES ON A CONFIRMED WEDGE
# ---------------------------------
#   1. Writes an incident record to the state dir (forensics, survives everything).
#   2. Logs it to journald at error level.
#   3. Raises a Slack alert through the healthy web container's Rails process, using
#      Zimmer's own AlertService -- no new secret and no new endpoint.
#   4. Optionally clears the wedge, but ONLY when the container is provably empty.
#
# THE GUARD ON RECOVERY
# ---------------------
# Recovery kills the container's containerd shim, which is destructive if anything is
# still running inside. So it is gated on a census of the container's cgroup: if any
# process other than the `init: true` shim is alive in there, the watchdog alerts and
# does nothing else. Zero live workload means there is nothing left to lose, and
# turning an invisible failure into a visible `exited` container is a strict
# improvement even when the restart afterwards does not take.
#
# Recovery deliberately stops before the last rung of #502's manual ladder (`docker
# rm` plus a redeploy). Removing the container is the one step that cannot be undone
# from here -- nothing on the host can recreate it, so a misfire would replace a
# wedged worker with no worker at all. That rung stays manual, and the alert says so.
#
# INSTALLATION
# ------------
# `scripts/install-worker-watchdog.sh <host>` copies this to
# /usr/local/sbin/zimmer-worker-watchdog and drives it from a systemd timer. Settings
# are overridable in /etc/default/zimmer-worker-watchdog.
#
# Exit status is 0 for "I ran", including when a wedge was found -- systemd should not
# see a unit failure for a condition the script handled and reported. A non-zero exit
# means the watchdog itself could not run.

set -uo pipefail

# Sourced by systemd through EnvironmentFile as well; read here too so the script is
# runnable by hand with the same settings.
if [ -r /etc/default/zimmer-worker-watchdog ]; then
  # shellcheck disable=SC1091
  . /etc/default/zimmer-worker-watchdog
fi

# Name substring identifying the worker container. Kamal names it
# zimmer-worker-<dest>-<dest>-<sha>, so the role prefix is the stable part.
FILTER="${ZIMMER_WATCHDOG_CONTAINER_FILTER:-zimmer-worker}"

# The healthy container the Slack alert is delivered through. Same image, same
# credentials, unaffected by the worker's cgroup.
WEB_FILTER="${ZIMMER_WATCHDOG_WEB_FILTER:-zimmer-web}"

# Bound on the liveness probe. A healthy exec answers in well under a second; the
# wedged one fails fast with an OCI runtime error. The timeout is for the third case,
# a probe that hangs, which must not hold the timer's slot open.
PROBE_TIMEOUT="${ZIMMER_WATCHDOG_PROBE_TIMEOUT:-20}"

# Consecutive failed probes before the watchdog acts. At the timer's 60s cadence this
# is ~2 minutes of unbroken failure, which is longer than any container swap Kamal
# performs and longer than a transient exec failure under load. The count is keyed to
# the container id, so a redeploy resets it rather than inheriting a partial streak.
FAILURES_TO_ACT="${ZIMMER_WATCHDOG_FAILURES_TO_ACT:-3}"

# 1 = attempt the bounded recovery above; 0 = detect and alert only. Detection is the
# floor and works with this off.
RECOVER="${ZIMMER_WATCHDOG_RECOVER:-1}"

# How long to wait for the container to actually leave `running` after the shim is
# killed, before giving up on recovery.
EXIT_WAIT="${ZIMMER_WATCHDOG_EXIT_WAIT:-30}"

# A wedge that nobody has cleared is still a wedge on the next tick, and the next.
# Without this the watchdog would write an incident file and boot a Rails process
# inside the web container every 60 seconds, on a host that is by definition already
# short of memory. Report once per container per interval instead; the streak keeps
# running underneath, so the condition is never forgotten, only throttled.
REALERT_INTERVAL="${ZIMMER_WATCHDOG_REALERT_INTERVAL:-3600}"

STATE_DIR="${ZIMMER_WATCHDOG_STATE_DIR:-/var/lib/zimmer-worker-watchdog}"
STATE_FILE="${STATE_DIR}/state"
INCIDENT_DIR="${STATE_DIR}/incidents"

TAG="zimmer-worker-watchdog"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
err() { log "ERROR: $*" >&2; }

mkdir -p "$STATE_DIR" "$INCIDENT_DIR" 2>/dev/null || {
  err "cannot create state dir ${STATE_DIR}"
  exit 1
}

command -v docker >/dev/null 2>&1 || { err "docker not on PATH"; exit 1; }

# ---------------------------------------------------------------------------
# JSON helpers. Deliberately dependency-free: jq is not guaranteed on a droplet,
# and an alert that fails because a formatting tool is missing is worse than a
# crude escape. The Ruby side tolerates a malformed payload rather than dropping
# the alert, so the worst case here is an uglier Slack message.
# ---------------------------------------------------------------------------
json_escape() {
  local s
  # Strip control characters other than the ones escaped below, which have no
  # legal unescaped JSON representation.
  s=$(printf '%s' "${1-}" | tr -d '\000-\010\013\014\016-\037')
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# Streak state. One line: "<container-id> <consecutive-failures> <last-report-epoch>".
# Keyed by id so a fresh container after a deploy never inherits the old one's
# failures or its report throttle.
# ---------------------------------------------------------------------------
STREAK=0
LAST_REPORT=0

read_state() {
  local id="$1" saved_id saved_n saved_t
  STREAK=0
  LAST_REPORT=0
  [ -r "$STATE_FILE" ] || return
  read -r saved_id saved_n saved_t <"$STATE_FILE" 2>/dev/null || true
  [ "${saved_id:-}" = "$id" ] || return
  STREAK="${saved_n:-0}"
  LAST_REPORT="${saved_t:-0}"
}

write_state() { printf '%s %s %s\n' "$1" "$2" "$3" >"$STATE_FILE"; }
clear_state() { rm -f "$STATE_FILE"; }

# ---------------------------------------------------------------------------
# The probe. `/bin/true` is the cheapest possible exec: it exercises the setns path
# that breaks and nothing else.
# ---------------------------------------------------------------------------
probe() {
  timeout "$PROBE_TIMEOUT" docker exec "$1" /bin/true 2>&1
}

# ---------------------------------------------------------------------------
# Locate the container's cgroup ROOT -- the scope named after the container, not the
# cgroup its PID happens to sit in.
#
# The distinction matters under sysbox and is easy to get backwards. A sysbox
# container's own processes do NOT live in the scope directly; they live in a child,
# `.../docker-<id>.scope/init.scope`, which is exactly what #502's kernel line showed
# (`task_memcg=.../scope/init.scope`). Reading /proc/<pid>/cgroup therefore lands one
# level down, and a census from there could miss whole sibling subtrees. So resolve
# the scope by container id first, and fall back to the PID's cgroup with a trailing
# `/init.scope` trimmed off only when the scope cannot be named directly.
# ---------------------------------------------------------------------------
find_cgroup() {
  local pid="$1" full="$2" rel c
  for c in "/sys/fs/cgroup/system.slice/docker-${full}.scope" "/sys/fs/cgroup/docker/${full}"; do
    if [ -d "$c" ]; then
      printf '%s' "$c"
      return
    fi
  done
  if [ -n "$pid" ] && [ "$pid" != "0" ] && [ -r "/proc/${pid}/cgroup" ]; then
    rel=$(awk -F: '$1 == "0" { print $3 }' "/proc/${pid}/cgroup" 2>/dev/null)
    rel="${rel%/init.scope}"
    if [ -n "$rel" ] && [ -d "/sys/fs/cgroup${rel}" ]; then
      printf '%s' "/sys/fs/cgroup${rel}"
      return
    fi
  fi
  printf ''
}

# Census of what is still alive in the cgroup, as "<total> <non-init>". The second
# number is what gates recovery: `docker-init`/`tini` is the `init: true` shim, which
# owns no work, so a container holding only that is empty in every sense that matters.
#
# The walk is RECURSIVE, and that is load-bearing rather than tidy. `cgroup.procs`
# lists only the processes directly in one cgroup, and under nested Docker the
# interesting ones are not there: sysbox roots the container's cgroup namespace at
# this scope, so the inner dockerd and every container it runs sit in CHILD cgroups.
# A non-recursive read would report an empty container while a dev stack was still up
# inside it, and recovery would then kill work it promised not to touch.
cgroup_census() {
  local dir="$1" total=0 workload=0 p comm procs
  if [ -n "$dir" ] && [ -d "$dir" ]; then
    procs=$(find "$dir" -name cgroup.procs -exec cat {} + 2>/dev/null | sort -u)
    while read -r p; do
      [ -n "$p" ] || continue
      total=$((total + 1))
      comm=$(cat "/proc/${p}/comm" 2>/dev/null)
      case "$comm" in
        docker-init | tini | "") ;;
        *) workload=$((workload + 1)) ;;
      esac
    done <<<"$procs"
  fi
  printf '%s %s' "$total" "$workload"
}

cgroup_field() {
  # memory.events is "<key> <value>" per line.
  local dir="$1" key="$2" v=""
  [ -n "$dir" ] && [ -r "${dir}/memory.events" ] &&
    v=$(awk -v k="$key" '$1 == k { print $2 }' "${dir}/memory.events" 2>/dev/null)
  printf '%s' "${v:-0}"
}

# ---------------------------------------------------------------------------
# Deliver the alert through the web container's Rails process. Web is on the same
# host, shares the image and the credentials, and is untouched by the worker's
# cgroup -- so it is the one process that can page while the worker cannot.
# Failure here is logged, never fatal: the incident file and journald entry stand on
# their own.
# ---------------------------------------------------------------------------
alert() {
  local payload="$1" web out
  web=$(docker ps --filter "name=${WEB_FILTER}" --format '{{.ID}}' 2>/dev/null | head -1)
  if [ -z "$web" ]; then
    err "no running container matching '${WEB_FILTER}' -- alert not delivered to Slack"
    return 1
  fi
  if out=$(printf '%s' "$payload" |
    timeout 240 docker exec -i "$web" bin/rails zimmer:worker_wedge_alert 2>&1); then
    log "alert delivered via ${WEB_FILTER}: ${out}"
    return 0
  fi
  err "alert delivery via ${WEB_FILTER} failed: ${out}"
  return 1
}

# ---------------------------------------------------------------------------
# Bounded recovery. Called only when the cgroup census proved the container empty.
# Appends human-readable steps to RECOVERY_STEPS and sets RECOVERY_OUTCOME.
# ---------------------------------------------------------------------------
RECOVERY_STEPS=""
RECOVERY_OUTCOME="skipped"

step() {
  log "recovery: $*"
  if [ -z "$RECOVERY_STEPS" ]; then
    RECOVERY_STEPS="$*"
  else
    RECOVERY_STEPS="${RECOVERY_STEPS}; $*"
  fi
}

recover() {
  local cid="$1" full="$2" cg="$3" shims pid waited state start_err

  # The shim is the process Docker talks to about this container. Killing it is what
  # finally moves a wedged container to `exited` -- `docker kill`, `restart` and
  # `rm -f` all fail first ("tried to kill container, but did not receive an exit
  # event"), which is rung 2 of #502's ladder.
  shims=$(pgrep -f "containerd-shim.*${full}" 2>/dev/null | tr '\n' ' ')
  if [ -z "$shims" ]; then
    step "no containerd shim found for ${full}"
    RECOVERY_OUTCOME="failed"
    return 1
  fi
  step "killing containerd shim(s) ${shims}"
  # shellcheck disable=SC2086
  kill -9 $shims 2>/dev/null

  waited=0
  while [ "$waited" -lt "$EXIT_WAIT" ]; do
    state=$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null)
    [ "$state" = "true" ] || break
    sleep 2
    waited=$((waited + 2))
  done

  state=$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null)
  if [ "$state" = "true" ]; then
    # Still running after the shim died: exec may have come back (Docker's own
    # restart policy can win the race), or the container is wedged harder than #502
    # describes. Distinguish the two rather than reporting a guess.
    if probe "$cid" >/dev/null 2>&1; then
      step "container is running and exec answers again"
      RECOVERY_OUTCOME="restarted"
      return 0
    fi
    step "container still reports running ${EXIT_WAIT}s after the shim was killed, and exec still fails"
    RECOVERY_OUTCOME="failed"
    return 1
  fi
  step "container left the running state"

  # The `init: true` shim is reparented to PID 1 rather than reaped, and holds the
  # cgroup open. Rung 3 of the ladder.
  if [ -n "$cg" ] && [ -d "$cg" ]; then
    # Recursive for the same reason the census is: anything left is in this subtree,
    # not necessarily in its root. The census already established that nothing here
    # owns work.
    while read -r pid; do
      [ -n "$pid" ] || continue
      step "killing orphaned in-cgroup pid ${pid} ($(cat "/proc/${pid}/comm" 2>/dev/null))"
      kill -9 "$pid" 2>/dev/null
    done < <(find "$cg" -name cgroup.procs -exec cat {} + 2>/dev/null | sort -u)
  fi

  if start_err=$(docker start "$cid" 2>&1); then
    step "docker start succeeded"
  else
    step "docker start failed: ${start_err}"
    # Rung 4/5: containerd leaves the task directory behind, and `start` refuses
    # while it exists.
    if [ -d "/run/containerd/io.containerd.runtime.v2.task/moby/${full}" ]; then
      step "removing stale containerd task dir"
      rm -rf "/run/containerd/io.containerd.runtime.v2.task/moby/${full}"
      if start_err=$(docker start "$cid" 2>&1); then
        step "docker start succeeded after clearing the stale task dir"
      else
        step "docker start failed again: ${start_err}"
        RECOVERY_OUTCOME="exited"
        return 1
      fi
    else
      RECOVERY_OUTCOME="exited"
      return 1
    fi
  fi

  # Started is not the same as usable. Ask the question that started all this.
  if probe "$cid" >/dev/null 2>&1; then
    step "exec answers again"
    RECOVERY_OUTCOME="restarted"
    return 0
  fi
  step "container started but exec still fails"
  RECOVERY_OUTCOME="failed"
  return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
cid=$(docker ps --filter "name=${FILTER}" --format '{{.ID}}' 2>/dev/null | head -1)
if [ -z "$cid" ]; then
  # No running worker is not this watchdog's problem: an exited or absent container is
  # already visible to Docker, to the restart policy and to the deploy. Clear the
  # streak so a replacement starts from zero.
  clear_state
  log "no running container matching '${FILTER}' -- nothing to probe"
  exit 0
fi

full=$(docker inspect -f '{{.Id}}' "$cid" 2>/dev/null)
name=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')
[ -n "$full" ] || { err "could not inspect container ${cid}"; exit 1; }

read_state "$full"

probe_err=$(probe "$cid")
probe_rc=$?

if [ "$probe_rc" -eq 0 ]; then
  clear_state
  log "${name}: exec probe OK"
  exit 0
fi

streak=$((STREAK + 1))
now_epoch=$(date -u +%s)
write_state "$full" "$streak" "$LAST_REPORT"

if [ "$streak" -lt "$FAILURES_TO_ACT" ]; then
  log "${name}: exec probe FAILED (rc=${probe_rc}, ${streak}/${FAILURES_TO_ACT}): ${probe_err}"
  exit 0
fi

# Re-read state before declaring a wedge: a container that has since exited is a
# normal failure Docker is already handling, not the silent one.
running=$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null)
if [ "$running" != "true" ]; then
  clear_state
  log "${name}: exec fails but the container is no longer running -- normal exit path, leaving it to Docker"
  exit 0
fi

# Already reported and still broken: keep counting, stay quiet. Re-reporting every
# tick would boot a Rails process a minute on a memory-starved host and bury the
# original alert.
if [ "$LAST_REPORT" -gt 0 ] && [ $((now_epoch - LAST_REPORT)) -lt "$REALERT_INTERVAL" ]; then
  log "${name}: still wedged (${streak} consecutive failures), last reported $((now_epoch - LAST_REPORT))s ago -- suppressed until ${REALERT_INTERVAL}s have passed"
  exit 0
fi
write_state "$full" "$streak" "$now_epoch"

oom=$(docker inspect -f '{{.State.OOMKilled}}' "$cid" 2>/dev/null)
restarts=$(docker inspect -f '{{.RestartCount}}' "$cid" 2>/dev/null)
runtime=$(docker inspect -f '{{.HostConfig.Runtime}}' "$cid" 2>/dev/null)
mem_limit=$(docker inspect -f '{{.HostConfig.Memory}}' "$cid" 2>/dev/null)
started_at=$(docker inspect -f '{{.State.StartedAt}}' "$cid" 2>/dev/null)
pid=$(docker inspect -f '{{.State.Pid}}' "$cid" 2>/dev/null)

cg=$(find_cgroup "$pid" "$full")
read -r cg_total cg_workload <<<"$(cgroup_census "$cg")"
oom_kill=$(cgroup_field "$cg" oom_kill)
oom_events=$(cgroup_field "$cg" oom)

err "${name} (${cid}) is WEDGED: running=true, ${streak} consecutive exec failures, ${cg_workload} live workload processes in its cgroup"
log "last exec error: ${probe_err}"

# Recovery is gated on the census, and on having *been able* to take one: an
# unreadable cgroup means unknown, and unknown is not a licence to kill.
recovery_attempted=false
if [ "$RECOVER" != "1" ]; then
  RECOVERY_OUTCOME="disabled"
  log "recovery disabled (ZIMMER_WATCHDOG_RECOVER=${RECOVER}) -- detecting and alerting only"
elif [ -z "$cg" ]; then
  RECOVERY_OUTCOME="skipped"
  log "recovery skipped: could not read the container's cgroup, so 'is anything still running in there?' is unanswered"
elif [ "$cg_workload" -gt 0 ]; then
  RECOVERY_OUTCOME="skipped"
  log "recovery skipped: ${cg_workload} process(es) other than the init shim are still alive in the cgroup"
else
  recovery_attempted=true
  recover "$cid" "$full" "$cg"
fi

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
payload=$(
  cat <<JSON
{
  "schema": 1,
  "host": "$(json_escape "$(hostname)")",
  "detected_at": "${now}",
  "container": {
    "id": "$(json_escape "$cid")",
    "name": "$(json_escape "$name")",
    "runtime": "$(json_escape "$runtime")",
    "running": ${running},
    "oom_killed": ${oom:-false},
    "restart_count": ${restarts:-0},
    "memory_limit_bytes": ${mem_limit:-0},
    "started_at": "$(json_escape "$started_at")"
  },
  "probe": {
    "consecutive_failures": ${streak},
    "timeout_seconds": ${PROBE_TIMEOUT},
    "last_error": "$(json_escape "$probe_err")"
  },
  "cgroup": {
    "path": "$(json_escape "$cg")",
    "process_count": ${cg_total:-0},
    "workload_process_count": ${cg_workload:-0},
    "oom_events": ${oom_events:-0},
    "oom_kills": ${oom_kill:-0}
  },
  "recovery": {
    "attempted": ${recovery_attempted},
    "outcome": "$(json_escape "$RECOVERY_OUTCOME")",
    "steps": "$(json_escape "$RECOVERY_STEPS")"
  }
}
JSON
)

incident_file="${INCIDENT_DIR}/${now//:/-}-${cid}.json"
printf '%s\n' "$payload" >"$incident_file"
log "incident written to ${incident_file}"

# journald carries it even if Slack does not.
command -v logger >/dev/null 2>&1 &&
  logger -t "$TAG" -p daemon.err \
    "worker ${name} wedged (running=true, exec fails, ${cg_workload} workload procs, oom_kills=${oom_kill}); recovery=${RECOVERY_OUTCOME}"

alert "$payload" || true

# A recovered container starts clean, so the next real failure is judged on its own
# streak rather than inheriting this one's.
if [ "$RECOVERY_OUTCOME" = "restarted" ]; then
  clear_state
  log "recovery restored exec on ${name}"
fi

exit 0
