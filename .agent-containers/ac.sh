#!/usr/bin/env bash
#
# ac.sh — "agent containers": orchestrate parallel, isolated, containerized Zimmer
# dev sessions.
#
# Each session is a full stack (Rails app + Postgres + Redis) running under its
# own Docker Compose project named `zimmer-dev-<name>`, in its own git clone, on
# its own dynamically-assigned host port. That isolation is what lets many agent
# (or human) sessions run at once without colliding on ports, databases, or code.
#
# The `zimmer-dev-` project prefix is not cosmetic: DockerCleanupJob
# (app/jobs/docker_cleanup_job.rb) reaps stale stacks by exactly this prefix, and
# DockerComposeCleanupService tears them down by compose-file path on clone
# cleanup. Keep them in lockstep — see .agent-containers/README.md.
#
# Commands:
#   clone <name> [branch]   Create + boot a new isolated session
#   status [name]           List sessions, or show one session's port + health
#   open <name>             Print (and try to open) the session's URL
#   attach <name>           Attach to the session's tmux (Claude Code) window
#   logs <name> [proc]      Tail a session's logs (proc: app|css, default app)
#   stop <name>             Stop a session's containers (keeps its data volume)
#   destroy <name>          Tear a session down completely (removes volumes)
#
# Requires: docker (with compose plugin), git, tmux. Claude Code (`claude`) is
# optional — `clone` skips the tmux/agent step if it isn't installed.
set -euo pipefail

# --------------------------------------------------------------------------- #
# Paths and constants
# --------------------------------------------------------------------------- #

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_REPO="$(dirname "$SCRIPT_DIR")"

# Where per-session clones live. Override with AC_WORKSPACE_DIR.
SESSIONS_DIR="${AC_WORKSPACE_DIR:-$HOME/.zimmer-dev-sessions}"

PROJECT_PREFIX="zimmer-dev-"
COMPOSE_REL=".agent-containers/docker-compose.dev.yml"

# How long to wait for /up after boot before giving up (seconds).
HEALTH_TIMEOUT="${AC_HEALTH_TIMEOUT:-180}"

# --------------------------------------------------------------------------- #
# Small helpers
# --------------------------------------------------------------------------- #

log()  { printf '\033[0;34m[ac]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[ac] warning:\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[ac] error:\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

require() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."
}

validate_name() {
  local name="$1"
  [[ -n "$name" ]] || die "session name is required"
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
    || die "invalid session name '$name' (use lowercase letters, digits, dashes)"
}

project_name() { echo "${PROJECT_PREFIX}$1"; }
session_dir()  { echo "${SESSIONS_DIR}/$1"; }
compose_file() { echo "$(session_dir "$1")/${COMPOSE_REL}"; }

session_exists() { [[ -d "$(session_dir "$1")" ]]; }

# Run docker compose for a session (project + compose file already wired).
compose() {
  local name="$1"; shift
  docker compose -p "$(project_name "$name")" -f "$(compose_file "$name")" "$@"
}

# The host port that the session's app :3000 is published on (empty if down).
# Must never fail: `docker compose port` exits non-zero for a stopped/absent
# service, and under `set -euo pipefail` that would abort callers that do
# `port="$(host_port ...)"`. The trailing `|| true` keeps the pipeline's exit 0.
host_port() {
  local name="$1"
  { compose "$name" port app 3000 2>/dev/null || true; } | awk -F: 'NF>1 {print $NF; exit}'
}

# Is the app container running for this session?
app_running() {
  local name="$1"
  [[ -n "$(compose "$name" ps -q app 2>/dev/null)" ]]
}

# --------------------------------------------------------------------------- #
# clone — create and boot a new isolated session
# --------------------------------------------------------------------------- #

cmd_clone() {
  local name="${1:-}"
  local branch="${2:-}"
  validate_name "$name"
  require docker
  require git

  local dir; dir="$(session_dir "$name")"
  if session_exists "$name"; then
    die "session '$name' already exists at $dir (use 'destroy' first, or pick another name)"
  fi

  log "Cloning $SOURCE_REPO → $dir"
  mkdir -p "$SESSIONS_DIR"
  git clone --quiet "$SOURCE_REPO" "$dir"

  if [[ -n "$branch" ]]; then
    log "Checking out branch '$branch'"
    git -C "$dir" checkout --quiet "$branch" \
      || git -C "$dir" checkout --quiet -b "$branch"
  fi

  log "Building and starting the stack (project $(project_name "$name"))"
  # APP_PORT=0 → Docker assigns a random free host port to container :3000.
  APP_PORT=0 compose "$name" up -d --build

  log "Running setup (bundle install, db:prepare) — first run is slow"
  compose "$name" exec -T app .agent-containers/setup.sh

  log "Starting the dev server"
  compose "$name" exec -T app .agent-containers/run.sh

  local port; port="$(host_port "$name")"
  [[ -n "$port" ]] || die "could not determine host port for session '$name'"

  log "Waiting for http://localhost:${port}/up (timeout ${HEALTH_TIMEOUT}s)"
  if wait_for_health "$port"; then
    log "Session '$name' is up: http://localhost:${port}"
  else
    warn "Session '$name' did not pass /up within ${HEALTH_TIMEOUT}s."
    warn "Inspect with: $0 logs $name"
  fi

  maybe_start_agent "$name" "$port"

  echo
  log "Next steps:"
  echo "  $0 status $name     # port + health"
  echo "  $0 attach $name     # attach the Claude Code tmux window"
  echo "  $0 logs $name       # tail the Rails log"
  echo "  $0 destroy $name    # tear it all down"
}

# Poll /up until it returns 200 or the timeout elapses.
wait_for_health() {
  local port="$1"
  local deadline=$(( SECONDS + HEALTH_TIMEOUT ))
  while (( SECONDS < deadline )); do
    if curl -fsS "http://localhost:${port}/up" >/dev/null 2>&1; then
      return 0
    fi
    sleep 3
  done
  return 1
}

# Start a tmux session running Claude Code, if tmux + claude are available.
maybe_start_agent() {
  local name="$1" port="$2"
  if ! command -v tmux >/dev/null 2>&1; then
    warn "tmux not installed — skipping the agent window."
    return 0
  fi
  if ! command -v claude >/dev/null 2>&1; then
    warn "claude not installed — skipping the agent window (the stack is still up)."
    return 0
  fi

  local tmux_name; tmux_name="$(project_name "$name")"
  if tmux has-session -t "$tmux_name" 2>/dev/null; then
    warn "tmux session '$tmux_name' already exists — leaving it as is."
    return 0
  fi

  log "Starting Claude Code in tmux session '$tmux_name'"
  tmux new-session -d -s "$tmux_name" -c "$(session_dir "$name")"
  tmux send-keys -t "$tmux_name" \
    "ENABLE_TOOL_SEARCH=false ZIMMER_LOCAL_BASE_URL=http://localhost:${port} claude --dangerously-skip-permissions" \
    C-m
}

# --------------------------------------------------------------------------- #
# status
# --------------------------------------------------------------------------- #

cmd_status() {
  require docker
  local name="${1:-}"

  if [[ -n "$name" ]]; then
    validate_name "$name"
    session_exists "$name" || die "no such session '$name'"
    show_one_status "$name"
    return 0
  fi

  if [[ ! -d "$SESSIONS_DIR" ]] || [[ -z "$(ls -A "$SESSIONS_DIR" 2>/dev/null)" ]]; then
    log "No sessions. Create one with: $0 clone <name>"
    return 0
  fi

  printf '%-20s %-8s %-10s %s\n' "SESSION" "PORT" "STATE" "HEALTH"
  local d
  for d in "$SESSIONS_DIR"/*/; do
    [[ -d "$d" ]] || continue
    show_one_status "$(basename "$d")" oneline
  done
}

show_one_status() {
  local name="$1" mode="${2:-full}"
  local port state health
  port="$(host_port "$name")"
  if app_running "$name"; then state="running"; else state="stopped"; fi

  health="-"
  if [[ -n "$port" ]] && curl -fsS "http://localhost:${port}/up" >/dev/null 2>&1; then
    health="ok"
  elif [[ -n "$port" ]]; then
    health="down"
  fi

  if [[ "$mode" == "oneline" ]]; then
    printf '%-20s %-8s %-10s %s\n' "$name" "${port:--}" "$state" "$health"
  else
    echo "Session:  $name"
    echo "Project:  $(project_name "$name")"
    echo "Dir:      $(session_dir "$name")"
    echo "State:    $state"
    echo "Port:     ${port:--}"
    [[ -n "$port" ]] && echo "URL:      http://localhost:${port}"
    echo "Health:   $health"
  fi
}

# --------------------------------------------------------------------------- #
# open / attach / logs
# --------------------------------------------------------------------------- #

cmd_open() {
  local name="${1:-}"
  validate_name "$name"
  session_exists "$name" || die "no such session '$name'"
  local port; port="$(host_port "$name")"
  [[ -n "$port" ]] || die "session '$name' is not running"
  local url="http://localhost:${port}"
  log "$url"
  if command -v open >/dev/null 2>&1; then open "$url"
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1 || true
  fi
}

cmd_attach() {
  local name="${1:-}"
  validate_name "$name"
  require tmux
  local tmux_name; tmux_name="$(project_name "$name")"
  tmux has-session -t "$tmux_name" 2>/dev/null \
    || die "no tmux session '$tmux_name' (was claude available at clone time?)"
  tmux attach -t "$tmux_name"
}

cmd_logs() {
  local name="${1:-}"
  local proc="${2:-app}"
  validate_name "$name"
  session_exists "$name" || die "no such session '$name'"
  case "$proc" in
    app|css) ;;
    *) die "unknown process '$proc' (use 'app' or 'css')" ;;
  esac
  compose "$name" exec app tail -f "/app/.logs/${proc}.log"
}

# --------------------------------------------------------------------------- #
# stop / destroy
# --------------------------------------------------------------------------- #

cmd_stop() {
  local name="${1:-}"
  validate_name "$name"
  session_exists "$name" || die "no such session '$name'"
  log "Stopping containers for '$name' (data volume preserved)"
  compose "$name" stop
}

cmd_destroy() {
  local name="${1:-}"
  validate_name "$name"
  session_exists "$name" || die "no such session '$name'"

  local tmux_name; tmux_name="$(project_name "$name")"
  if command -v tmux >/dev/null 2>&1 && tmux has-session -t "$tmux_name" 2>/dev/null; then
    log "Killing tmux session '$tmux_name'"
    tmux kill-session -t "$tmux_name" || true
  fi

  log "Tearing down the stack for '$name' (-v removes the postgres volume)"
  compose "$name" down -v --remove-orphans || warn "compose down reported errors"

  log "Removing clone directory $(session_dir "$name")"
  rm -rf "$(session_dir "$name")"
  log "Session '$name' destroyed."
}

# --------------------------------------------------------------------------- #
# Dispatch
# --------------------------------------------------------------------------- #

usage() {
  sed -n '3,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
  local cmd="${1:-}"
  [[ $# -gt 0 ]] && shift || true
  case "$cmd" in
    clone)   cmd_clone   "$@" ;;
    status)  cmd_status  "$@" ;;
    open)    cmd_open    "$@" ;;
    attach)  cmd_attach  "$@" ;;
    logs)    cmd_logs    "$@" ;;
    stop)    cmd_stop    "$@" ;;
    destroy) cmd_destroy "$@" ;;
    ""|-h|--help|help) usage ;;
    *) err "unknown command '$cmd'"; echo; usage; exit 1 ;;
  esac
}

main "$@"
