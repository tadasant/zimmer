#!/usr/bin/env bash
# Clear the force-expired root password DigitalOcean plants on a droplet, on an
# ALREADY-RUNNING box. Same repair as the one in cloud-init's runcmd -- this is the
# converge path for hosts that already exist.
#
# Why a converge path at all: cloud-init runs ONCE, at first boot. A droplet created
# before that runcmd existed still carries `lastchg=0`, and nothing else in the deploy
# touches it. Production cannot be rebuilt casually, so without this its :2222 publickey
# path stays broken until someone recreates the droplet. DigitalOcean's "reset root
# password" flow also re-arms `lastchg=0` on ANY box, so this is the standing repair, not
# a one-off migration.
#
# Why it connects on :22, not :2222: :2222 is exactly what the expiry blocks -- publickey
# succeeds and pam_unix then refuses the session ("password change required but no TTY
# available"). Tailnet :22 is Tailscale SSH, which authenticates by tailnet identity and
# never consults pam_unix, so it keeps working on a broken box. It is the only way in.
#
# CONVERGENT, not a no-op: re-running is safe and lands the box in the same state, but on a
# box where root has a real password (a DO-emailed one, or one set through the DO console)
# this DELETES it. That is the intent -- root is key-only here -- but it does mean the
# DigitalOcean console needs a password reset before it can be used as a break-glass door.
# See "A rebuilt droplet has exactly one fallback door" in docs/limitations.
#
# Usage: clear-root-password-expiry.sh <tailnet-host-or-ip>
set -euo pipefail

HOST="${1:?usage: clear-root-password-expiry.sh <tailnet-host-or-ip>}"
ATTEMPTS="${ATTEMPTS:-6}"

# A zero or non-numeric ATTEMPTS skips the loop entirely, which would leave the closing
# message describing a host that was never contacted. Reject the input instead of emitting
# a confident sentence about work that did not happen.
case "$ATTEMPTS" in
  ''|*[!0-9]*|0)
    echo "::error::ATTEMPTS must be a positive integer (got '${ATTEMPTS}')"
    exit 2
    ;;
esac

# accept-new + /dev/null: a rebuilt droplet has a new host key (staging does not pin one),
# and BatchMode alone would just fail on the unknown key instead of prompting.
#
# ConnectTimeout bounds the handshake only. A box thrashing badly enough to matter here can
# complete the handshake and then stop scheduling sshd, which would hang with no timeout of
# its own -- the workflow sets no timeout-minutes, so that stalls the deploy for hours. The
# keepalives bound a silent session to ~30s and keep the retry budget below meaningful.
SSH_OPTS=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=10
  -o ServerAliveInterval=10
  -o ServerAliveCountMax=3
)

# `usermod -p '*'` sets an INVALID hash, not an empty one -- `passwd -d` would leave the
# field blank, which means "no password required" rather than "no password login".
# `chage -M -1` disables aging, so the box cannot re-expire itself later.
repair='
  set -eu
  usermod -p "*" root
  chage -d "$(date +%Y-%m-%d)" -M -1 root
  chage -l root | grep -E "Last password change|Password expires"
'

# Retried with backoff, for two different transients. On a freshly-rebuilt box this runs
# moments after the node reports Online, while cloud-init is still working: sshd may not be
# serving yet, and unattended-upgrades can hold the /etc/passwd lock ("usermod: cannot lock
# /etc/passwd; try again later"). It also has to outlast a box that is briefly off the
# tailnet -- a host thrashing on memory starves tailscaled, and every connection to it times
# out for MINUTES while the control plane still reports the node Online. The backoff is sized
# for that second case: a lock clears in seconds, an unreachable host does not.
transport_failures=0

for attempt in $(seq 1 "$ATTEMPTS"); do
  echo "Clearing any forced root-password expiry on ${HOST} (Tailscale SSH, :22) — attempt ${attempt}/${ATTEMPTS}…"

  # `|| rc=$?` rather than branching on `if ssh …`: the status has to be inspected, not just
  # tested, because it is what separates "never got a session" from "ran the repair and it
  # failed". Safe under `set -e` -- the `||` list succeeds, and the assignment returns 0 even
  # when rc is non-zero.
  rc=0
  ssh "${SSH_OPTS[@]}" root@"${HOST}" "$repair" || rc=$?

  if [ "$rc" -eq 0 ]; then
    echo "✅ root password neutralized and aging disabled on ${HOST}"
    exit 0
  fi

  # 255 is ssh's own failure -- connect timed out, host unreachable, auth rejected, or the
  # connection dropped mid-command -- rather than a status forwarded from the remote command.
  # That last case is why the closing message says the repair did not run TO COMPLETION and
  # not that it never started: on a box that OOM-kills processes, a session can establish,
  # begin the repair, and lose sshd part-way through.
  if [ "$rc" -eq 255 ]; then
    transport_failures=$((transport_failures + 1))
    echo "   could not reach ${HOST} over Tailscale SSH (ssh exit 255)"
  else
    echo "   reached ${HOST}, but the repair exited ${rc}"
  fi

  # `if`, not `[ … ] && sleep`: on the last attempt that AND-list returns 1, and under
  # `set -e` it would exit here, swallowing the diagnostics below. Same reason the clamp
  # below is an `if` rather than `[ … ] && backoff=60`.
  if [ "$attempt" -lt "$ATTEMPTS" ]; then
    backoff=$(( attempt * 15 ))
    if [ "$backoff" -gt 60 ]; then
      backoff=60
    fi
    sleep "$backoff"
  fi
done

# Both branches exit 1 -- an unrepaired box is a broken box either way, and a deploy that
# carried on would leave :2222 answering publickey and then refusing every session. What
# differs is where the operator should go and look.
if [ "$transport_failures" -eq "$ATTEMPTS" ]; then
  echo "::error::Could not complete an SSH session with ${HOST} on any of ${ATTEMPTS} attempts, so the repair"
  echo "::error::did not run to completion: this is a reachability problem, not a repair problem. Do not go"
  echo "::error::looking for a broken password. Check the host instead: a box thrashing on memory starves"
  echo "::error::tailscaled and times out every connection for minutes at a stretch, while the control plane"
  echo "::error::still reports the node Online (so \`tailscale status\` looks fine). Those outages clear on"
  echo "::error::their own, so :22 may well answer by the time you read this -- that it does now is not"
  echo "::error::evidence the deploy was wrong to fail."
else
  echo "::error::Reached ${HOST}, but could not clear the forced root-password expiry after ${ATTEMPTS} attempts."
  if [ "$transport_failures" -gt 0 ]; then
    echo "::error::(${transport_failures}/${ATTEMPTS} of those attempts could not reach it at all, so the tailnet"
    echo "::error::path to it is flapping rather than healthy.)"
  fi
  echo "::error::Leaving it unrepaired would mean publickey auth on :2222 succeeds and then EVERY session"
  echo "::error::is rejected by pam_unix -- the ssh-agent-mcp-server healthcheck fails and nobody can get a"
  echo "::error::shell. Tailscale SSH (tailnet :22) still works, so repair it there by hand."
fi
exit 1
