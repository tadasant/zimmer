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
ATTEMPTS="${ATTEMPTS:-5}"

# accept-new + /dev/null: a rebuilt droplet has a new host key (staging does not pin one),
# and BatchMode alone would just fail on the unknown key instead of prompting.
SSH_OPTS=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=10
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

# Retried: on a freshly-rebuilt box this runs moments after the node reports Online, while
# cloud-init is still working. sshd may not be serving yet, and unattended-upgrades can hold
# the /etc/passwd lock ("usermod: cannot lock /etc/passwd; try again later").
for attempt in $(seq 1 "$ATTEMPTS"); do
  echo "Clearing any forced root-password expiry on ${HOST} (Tailscale SSH, :22) — attempt ${attempt}/${ATTEMPTS}…"

  if ssh "${SSH_OPTS[@]}" root@"${HOST}" "$repair"; then
    echo "✅ root password neutralized and aging disabled on ${HOST}"
    exit 0
  fi

  # `if`, not `[ … ] && sleep`: on the last attempt that AND-list returns 1, and under
  # `set -e` it would exit here, swallowing the diagnostics below.
  if [ "$attempt" -lt "$ATTEMPTS" ]; then
    sleep 15
  fi
done

echo "::error::Could not clear the forced root-password expiry on ${HOST} after ${ATTEMPTS} attempts."
echo "::error::Leaving it unrepaired would mean publickey auth on :2222 succeeds and then EVERY session"
echo "::error::is rejected by pam_unix -- the ssh-agent-mcp-server healthcheck fails and nobody can get a"
echo "::error::shell. Tailscale SSH (tailnet :22) still works, so repair it there by hand."
exit 1
