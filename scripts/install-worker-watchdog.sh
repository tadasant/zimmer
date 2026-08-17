#!/usr/bin/env bash
# Install (or update) the Zimmer worker watchdog on a host, and prove it is armed.
#
# The watchdog itself is scripts/worker-watchdog.sh; this is the delivery path. It
# copies that script to /usr/local/sbin/zimmer-worker-watchdog, writes a systemd
# service + timer, and enables them. Convergent: re-running lands the box in the same
# state, and a changed script is picked up on the next deploy.
#
# Why a converge script rather than cloud-init: cloud-init runs ONCE, at first boot,
# and Terraform provisions the droplet with `ignore_changes = [user_data]`. A watchdog
# written into cloud-init would never reach the hosts that already exist -- which is
# every host that matters. Same reasoning, and the same shape, as
# scripts/clear-root-password-expiry.sh.
#
# Why a timer rather than a long-running daemon: the probe is a `docker exec` and two
# `docker inspect`s. A oneshot on a 60s timer has no state to leak, restarts itself
# after a reboot for free, and cannot wedge in the way the thing it is watching does.
#
# Production note: this repository has no production deploy workflow (that lives in
# the private companion repo), so on production this is driven from there. That deploy
# does not reach its droplet the way staging does -- see ZIMMER_WATCHDOG_SSH_EXTRA and
# ZIMMER_WATCHDOG_RECOVER below, which are the two knobs it needs.
#
# Usage: install-worker-watchdog.sh <tailnet-host-or-ip>
set -euo pipefail

HOST="${1:?usage: install-worker-watchdog.sh <tailnet-host-or-ip>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG_SRC="${SCRIPT_DIR}/worker-watchdog.sh"

# Cadence of the probe. Fast enough that a wedge is reported within a few minutes
# (the script needs FAILURES_TO_ACT consecutive failures), slow enough to be free.
INTERVAL="${ZIMMER_WATCHDOG_INTERVAL:-60s}"

# Recovery, asserted declaratively. Unset (the default, and staging) means "seed the
# template if the box has no settings file, then never touch it again" -- the operator
# who edits it by hand keeps their edit. Set to 0 or 1 and this script instead OWNS
# /etc/default/zimmer-worker-watchdog and rewrites it on every converge.
#
# That distinction is the whole point for production, where recovery must be OFF:
# restarting the worker there kills every in-flight agent session, and a setting that
# only "sticks if nobody changed it" is not a safety property. A deploy that declares
# RECOVER=0 gets it re-asserted on every run, on any host, including one someone edited
# by hand and including a droplet rebuilt from scratch an hour ago.
RECOVER="${ZIMMER_WATCHDOG_RECOVER:-}"
case "$RECOVER" in
  '' | 0 | 1) ;;
  *)
    echo "::error::ZIMMER_WATCHDOG_RECOVER must be 0, 1, or unset (got '${RECOVER}')"
    exit 2
    ;;
esac

[ -r "$WATCHDOG_SRC" ] || { echo "::error::missing ${WATCHDOG_SRC}"; exit 1; }

# accept-new + /dev/null: a rebuilt droplet has a new host key and staging pins none.
# The keepalives bound a silent session, so a thrashing box fails the step instead of
# hanging the deploy for hours.
#
# ZIMMER_WATCHDOG_SSH_EXTRA is the seam for a caller that does not reach its host the
# way staging does. Staging's deploy runs a plain `ssh root@<host>` off the runner's own
# key; production's lives in the private companion repo and reaches the droplet over the
# tailnet with a generated config -- `-F <config>` -- because its runner-hygiene check
# forbids a key or a `Host *` stanza in the shared runner $HOME that a bare
# `ssh root@host` would otherwise depend on. Rather than teach this script about
# tailnets, let the caller pass the arguments it already knows it needs:
#
#   ZIMMER_WATCHDOG_SSH_EXTRA="-F ${SSH_CONFIG}" bash scripts/install-worker-watchdog.sh prod-host
#
# The extras go FIRST, ahead of the options below, because ssh takes the first value it
# obtains for any option -- so a caller can override ConnectTimeout or the host-key
# policy here, and cannot be overridden by them. Splitting is on whitespace with no
# quote handling, which is what every real value looks like; a path containing spaces is
# not supported (`-o` forms with `=` are, and are the usual escape hatch).
SSH_OPTS=()
if [ -n "${ZIMMER_WATCHDOG_SSH_EXTRA:-}" ]; then
  read -r -a SSH_OPTS <<<"${ZIMMER_WATCHDOG_SSH_EXTRA}"
fi
SSH_OPTS+=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=15
  -o ServerAliveInterval=10
  -o ServerAliveCountMax=3
)

# `run` forwards this script's stdin to the remote command, which is how the file
# bodies below get there. `run_q` is the same call with stdin closed -- ssh would
# otherwise swallow whatever the caller's stdin happens to be (a workflow's, a
# terminal's) and hand it to a command that never asked for it.
run() { ssh "${SSH_OPTS[@]}" "root@${HOST}" "$@"; }
run_q() { ssh -n "${SSH_OPTS[@]}" "root@${HOST}" "$@"; }

echo "Installing the worker watchdog on ${HOST}"

# Write to a temp path and move into place, so a probe that fires mid-copy never
# executes half a script.
run 'cat > /usr/local/sbin/.zimmer-worker-watchdog.new && chmod 0755 /usr/local/sbin/.zimmer-worker-watchdog.new && mv /usr/local/sbin/.zimmer-worker-watchdog.new /usr/local/sbin/zimmer-worker-watchdog' \
  <"$WATCHDOG_SRC"

# Defaults file. Two modes, and which one applies is the caller's declaration.
#
# Unset ZIMMER_WATCHDOG_RECOVER: created only if absent, so an operator who turned
# recovery off on a box stays turned off across deploys. The script's own defaults are
# the source of truth for the values; this file exists to be edited.
if [ -z "$RECOVER" ]; then
  run "test -e /etc/default/zimmer-worker-watchdog || cat > /etc/default/zimmer-worker-watchdog" <<'DEFAULTS'
# Zimmer worker watchdog -- see /usr/local/sbin/zimmer-worker-watchdog for what each
# of these does. Commented out = the script's own default applies.
#
# Set to 0 to detect and alert without ever touching the container.
#ZIMMER_WATCHDOG_RECOVER=1
#ZIMMER_WATCHDOG_FAILURES_TO_ACT=3
#ZIMMER_WATCHDOG_PROBE_TIMEOUT=20
#ZIMMER_WATCHDOG_REALERT_INTERVAL=3600
DEFAULTS
else
  # Declared: this file is now managed by the deploy, and is rewritten every converge.
  # Same temp-and-move as the script copy above, for the same reason -- the watchdog
  # sources this file every 60 seconds and must never read half of it.
  echo "Asserting ZIMMER_WATCHDOG_RECOVER=${RECOVER} in /etc/default/zimmer-worker-watchdog"
  run 'cat > /etc/default/.zimmer-worker-watchdog.new && chmod 0644 /etc/default/.zimmer-worker-watchdog.new && mv /etc/default/.zimmer-worker-watchdog.new /etc/default/zimmer-worker-watchdog' <<DEFAULTS
# Zimmer worker watchdog -- MANAGED BY THE DEPLOY (scripts/install-worker-watchdog.sh).
# Edits here are overwritten on the next converge; change the deploy instead.
#
# 1 = clear a confirmed wedge by restarting the worker container; 0 = detect and alert
# only. Recovery is bounded and only ever fires on a container proven empty, but on a
# host running real agent sessions "proven empty" is a claim about a moment that has
# already passed by the time the restart lands -- so production declares 0.
ZIMMER_WATCHDOG_RECOVER=${RECOVER}
#
# The rest are the script's own defaults; uncomment to override.
#ZIMMER_WATCHDOG_FAILURES_TO_ACT=3
#ZIMMER_WATCHDOG_PROBE_TIMEOUT=20
#ZIMMER_WATCHDOG_REALERT_INTERVAL=3600
DEFAULTS
fi

run "cat > /etc/systemd/system/zimmer-worker-watchdog.service" <<'UNIT'
[Unit]
Description=Zimmer worker watchdog (exec-based liveness probe for the worker container)
Documentation=https://github.com/tadasant/zimmer/issues/502
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
EnvironmentFile=-/etc/default/zimmer-worker-watchdog
ExecStart=/usr/local/sbin/zimmer-worker-watchdog
# The probe's own timeouts bound each docker call; this bounds the whole run, so a
# stuck invocation can never overlap the next tick.
TimeoutStartSec=600
UNIT

run "cat > /etc/systemd/system/zimmer-worker-watchdog.timer" <<UNIT
[Unit]
Description=Run the Zimmer worker watchdog every ${INTERVAL}
Documentation=https://github.com/tadasant/zimmer/issues/502

[Timer]
# Not OnCalendar: the probe wants a steady cadence measured from the last run, so a
# slow run delays the next one instead of stacking on top of it.
OnBootSec=2min
OnUnitActiveSec=${INTERVAL}
AccuracySec=5s
Unit=zimmer-worker-watchdog.service

[Install]
WantedBy=timers.target
UNIT

run_q "systemctl daemon-reload && systemctl enable --now zimmer-worker-watchdog.timer >/dev/null"

# Run it once, now, so the deploy fails here rather than silently installing a probe
# that cannot run. A wedge found on this first run is reported by the script and does
# not fail the deploy -- the script exits 0 for "I ran".
run_q "systemctl start zimmer-worker-watchdog.service" || {
  echo "::error::the watchdog's first run failed on ${HOST}"
  run_q "journalctl -u zimmer-worker-watchdog.service -n 30 --no-pager" || true
  exit 1
}

if ! run_q "systemctl is-active --quiet zimmer-worker-watchdog.timer"; then
  echo "::error::zimmer-worker-watchdog.timer is not active on ${HOST}"
  run_q "systemctl status zimmer-worker-watchdog.timer --no-pager" || true
  exit 1
fi

echo "Watchdog armed on ${HOST}; last run:"
run_q "journalctl -u zimmer-worker-watchdog.service -n 10 --no-pager -o cat" || true
