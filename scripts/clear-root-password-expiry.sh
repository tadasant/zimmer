#!/usr/bin/env bash
# Clear the force-expired root password DigitalOcean plants on a droplet, on an
# ALREADY-RUNNING box. Same repair as the one in cloud-init's runcmd -- this is the
# converge path for hosts that already exist.
#
# Why a converge path at all: cloud-init runs ONCE, at first boot. A droplet created
# before the runcmd fix (production, and any staging box not rebuilt since) still carries
# `lastchg=0`, and nothing else in the deploy touches it. Production cannot be rebuilt
# casually, so without this its :2222 publickey path stays broken until someone recreates
# the droplet.
#
# Why it connects on :22, not :2222: :2222 is exactly what the expiry blocks -- publickey
# succeeds and pam_unix then refuses the session ("password change required but no TTY
# available"). Tailnet :22 is Tailscale SSH, which authenticates by tailnet identity and
# never consults pam_unix, so it keeps working on a broken box. It is the only way in.
#
# Idempotent: on a healthy box both commands are no-ops, so this runs on every deploy.
#
# Usage: clear-root-password-expiry.sh <tailnet-host-or-ip>
set -euo pipefail

HOST="${1:?usage: clear-root-password-expiry.sh <tailnet-host-or-ip>}"

echo "Clearing any forced root-password expiry on ${HOST} (over Tailscale SSH on :22)…"

# `usermod -p '*'` sets an INVALID hash, not an empty one -- `passwd -d` would leave the
# field blank, which means "no password required" rather than "no password login".
# `chage -M -1` disables aging so it cannot re-expire.
ssh -o BatchMode=yes root@"${HOST}" '
  set -eu
  usermod -p "*" root
  chage -d "$(date +%Y-%m-%d)" -M -1 root
  chage -l root
'

echo "✅ root password neutralized and aging disabled on ${HOST}"
