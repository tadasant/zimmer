#!/usr/bin/env bash
# Stop needrestart from auto-restarting the sysbox units on a host, and prove the
# drop-in it writes is actually read.
#
# WHAT IT PREVENTS. `apt-daily-upgrade` upgrades a library that sysbox-fs/sysbox-mgr
# link against; needrestart then runs `systemctl restart sysbox.service`; the daemons
# come back with an EMPTY container registry. Every sysbox container that was already
# running is then orphaned permanently -- `docker exec` into it fails with "unsafe
# procfs detected: openat2 ... operation not permitted" while its own processes keep
# running normally. So the worker keeps its slot, reports `Status=running, Restarts=0`,
# passes every container-shaped check in the deploy, and runs no jobs and no sessions.
# That is exactly what happened to both hosts on 2026-09-02
# ([#774](https://github.com/tadasant/zimmer/issues/774)), twelve minutes apart, from one
# host-level event. Recovering a wedged container costs a container RECREATION, which
# unattended-upgrades is in no position to do.
#
# The prevention is one needrestart config snippet that deselects anything matching
# `^sysbox` from the automatic restart set. The upgrade still lands; only the restart is
# declined.
#
# WHY A CONVERGE SCRIPT, and not cloud-init. Same reasoning as
# install-worker-watchdog.sh and clear-root-password-expiry.sh: cloud-init runs ONCE, at
# first boot, and Terraform provisions the droplet with `ignore_changes = [user_data]`,
# so a snippet written there would never reach a host that already exists. Staging's
# sysbox was installed out of band and its droplet is persistent between rebuilds, which
# leaves the deploy as the only place that reliably reaches it. Re-running is how a
# changed snippet lands.
#
# WHY THIS REPO AND NOT THE PROVISIONER. Nothing here provisions sysbox -- the staging
# deploy only PREFLIGHTS it. Writing the drop-in from a step that runs on every deploy
# is deliberately independent of how sysbox got onto the box.
#
# PRODUCTION IS NOT THIS PATH. Production's sysbox provisioning lives in the private
# companion repo and already converges the same `override_rc` line on every production
# deploy. This script is staging's equivalent; it takes a host and is not wired into
# production's deploy.
#
# Usage: install-needrestart-sysbox-dropin.sh <tailnet-host-or-ip>
set -euo pipefail

HOST="${1:?usage: install-needrestart-sysbox-dropin.sh <tailnet-host-or-ip>}"

# accept-new + /dev/null: a rebuilt droplet has a new host key and staging pins none.
# The keepalives bound a silent session, so a thrashing box fails the step instead of
# hanging the deploy for hours. Same options, for the same reasons, as the other two
# converge scripts here.
SSH_OPTS=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=15
  -o ServerAliveInterval=10
  -o ServerAliveCountMax=3
)

echo "Converging the needrestart sysbox drop-in on ${HOST}"

# One `sh -s` rather than a command string per operation. The remote work is a write and
# then three assertions about it, and they have to see the same box: splitting them across
# ssh invocations buys nothing and costs a round trip each. It also keeps the Perl below
# free of the nested single-quoting that a `ssh host '...'` form would force on it.
#
# Everything the remote script needs is in its own text, so ssh's stdin is the script and
# nothing else.
#
# The drop-in is written to a temp path and moved into place. needrestart is invoked by
# unattended-upgrades on a timer that is not coordinated with this deploy, and it `die`s on
# a snippet that does not parse -- so a run that caught the file half-written would abort
# the upgrade it was called from. `mv` within one directory is atomic; `cat >` in place is
# not.
#
# `99-` sorts last among conf.d snippets, which is what makes the merge below see the stock
# `override_rc` rather than the other way round. Same filename production uses, so on a host
# that carries a hand-copied version of it this converge REPLACES the pet file instead of
# sitting beside it.
rc=0
ssh "${SSH_OPTS[@]}" "root@${HOST}" 'sh -s' <<'REMOTE' || rc=$?
set -eu

conf_d=/etc/needrestart/conf.d
dropin="${conf_d}/99-sysbox.conf"

# Absent needrestart is not a failure. It is preinstalled on Ubuntu server and is what
# unattended-upgrades calls, but a box without it is simply not exposed to this yet -- and
# apt does not clobber conf.d snippets, so a drop-in written now is live the moment the
# package arrives. Write it either way; only the "is it actually read" assertion is skipped.
if command -v needrestart >/dev/null 2>&1; then
  have_needrestart=1
else
  have_needrestart=0
  echo "note: needrestart is not installed on this host; writing the drop-in anyway so it"
  echo "note: takes effect if the package is ever pulled in."
fi

before=$(md5sum "$dropin" 2>/dev/null | cut -d' ' -f1 || true)

mkdir -p "$conf_d"
cat > "${conf_d}/.99-sysbox.conf.new" <<'NRCONF'
# Managed by scripts/install-needrestart-sysbox-dropin.sh in tadasant/zimmer, run by the
# "Deploy staging" workflow. Do not hand-edit: every deploy rewrites this file.
#
# Keep needrestart from auto-restarting the sysbox runtime after a library upgrade.
# Restarting sysbox-mgr/sysbox-fs orphans every sysbox container already running: the
# daemons come back with an empty registry, so `docker exec` into those containers fails
# with "unsafe procfs detected" while their own processes keep running. Recovering one
# costs a container recreation, which unattended-upgrades is in no position to do.
# See https://github.com/tadasant/zimmer/issues/774.
#
# Merge, never reassign -- a bare assignment would drop the stock dbus/display-manager/
# networking entries this hash already carries.
$nrconf{override_rc} = { %{$nrconf{override_rc} // {}}, qr(^sysbox) => 0 };
NRCONF
chmod 0644 "${conf_d}/.99-sysbox.conf.new"
mv "${conf_d}/.99-sysbox.conf.new" "$dropin"

after=$(md5sum "$dropin" | cut -d' ' -f1)
if [ "$before" = "$after" ]; then
  echo "drop-in already current at ${dropin} (unchanged)"
elif [ -z "$before" ]; then
  echo "drop-in created at ${dropin}"
else
  echo "drop-in updated at ${dropin} (${before} -> ${after})"
fi

# --- assertion 1: it parses -------------------------------------------------------
# needrestart `die`s on a snippet that does not compile, and it is unattended-upgrades that
# would carry the error. A broken file here is worse than no file: it takes the whole
# upgrade run down rather than just failing to protect sysbox.
perl -c "$dropin"

# --- assertion 2: it says what it is meant to say ---------------------------------
# Parsing is not the property that matters; matching a real unit name and preserving the
# stock hash are. The seeded entry stands in for the ~20 the stock config ships (dbus,
# display managers, networking) -- if the snippet ever regresses to a bare assignment it
# still parses, still deselects sysbox, and silently re-arms an automatic dbus restart.
perl -e '
  our %nrconf;
  $nrconf{override_rc} = { qr(^dbus) => 0 };
  my $fn = shift @ARGV;
  eval do { local(@ARGV, $/) = $fn; <> };
  die "the drop-in failed to evaluate: $@" if $@;

  my @keys = keys %{$nrconf{override_rc}};
  my @hit = grep { "sysbox-mgr.service" =~ /$_/ && $nrconf{override_rc}{$_} eq "0" } @keys;
  die "evaluated, but sysbox-mgr.service is not deselected by any override_rc key\n" unless @hit;

  my @kept = grep { "dbus.service" =~ /$_/ } @keys;
  die "the drop-in REPLACED override_rc instead of merging into it -- the stock dbus and\n"
    . "display-manager entries are gone, so needrestart would now restart dbus unattended\n"
    unless @kept;

  print "override_rc: sysbox-mgr.service deselected, pre-existing entries preserved\n";
' "$dropin"

# --- assertion 3: needrestart actually reads conf.d -------------------------------
# The drop-in only works because /etc/needrestart/needrestart.conf ends with a loop that
# evals every conf.d/*.conf. That loop is stock, but it is stock in the DISTRIBUTION's
# config file, which a package upgrade rewrites -- and if it ever goes away this file
# becomes inert with nothing to say so. Fail loudly instead: the whole point of the
# mechanism is that nobody looks at it again until a container is already wedged.
if [ "$have_needrestart" = 1 ]; then
  if ! grep -q '/etc/needrestart/conf.d' /etc/needrestart/needrestart.conf; then
    echo "::error::/etc/needrestart/needrestart.conf no longer evaluates /etc/needrestart/conf.d,"
    echo "::error::so ${dropin} is inert and sysbox is exposed to an unattended restart again."
    echo "::error::Move the override into needrestart.conf itself, or into whatever replaced the"
    echo "::error::snippet mechanism in this needrestart version."
    exit 1
  fi
  needrestart --version 2>&1 | head -1 || true
  echo "needrestart evaluates ${conf_d}, and ${dropin} sorts last within it"
fi
REMOTE

if [ "$rc" -ne 0 ]; then
  echo "::error::Could not converge the needrestart sysbox drop-in on ${HOST}."
  echo "::error::Until it is in place, the next apt-daily-upgrade that touches a library sysbox"
  echo "::error::links against will restart sysbox-mgr/sysbox-fs and PERMANENTLY orphan every"
  echo "::error::sysbox container on the box -- including the worker this deploy is about to put"
  echo "::error::there. It keeps reporting Status=running while every \`docker exec\` into it"
  echo "::error::fails with \"unsafe procfs detected\"; see"
  echo "::error::https://github.com/tadasant/zimmer/issues/774 and docs/operate/nested-docker."
  echo "::error::An ssh failure here is a reachability problem, not a needrestart one -- the"
  echo "::error::preceding steps reach the same host the same way."
  exit 1
fi

echo "✅ needrestart on ${HOST} will not auto-restart sysbox"
