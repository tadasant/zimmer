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
# the private companion repo), so on production this is run by hand or from there:
#   bash scripts/install-worker-watchdog.sh <prod-tailnet-host>
#
# Usage: install-worker-watchdog.sh <tailnet-host-or-ip>
set -euo pipefail

HOST="${1:?usage: install-worker-watchdog.sh <tailnet-host-or-ip>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG_SRC="${SCRIPT_DIR}/worker-watchdog.sh"

# Cadence of the probe. Fast enough that a wedge is reported within a few minutes
# (the script needs FAILURES_TO_ACT consecutive failures), slow enough to be free.
INTERVAL="${ZIMMER_WATCHDOG_INTERVAL:-60s}"

[ -r "$WATCHDOG_SRC" ] || { echo "::error::missing ${WATCHDOG_SRC}"; exit 1; }

# accept-new + /dev/null: a rebuilt droplet has a new host key and staging pins none.
# The keepalives bound a silent session, so a thrashing box fails the step instead of
# hanging the deploy for hours.
SSH_OPTS=(
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

# Defaults file: created only if absent, so an operator who turned recovery off on a
# box stays turned off across deploys. The script's own defaults are the source of
# truth for the values; this file exists to be edited.
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
