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
# companion repo and already converges the same `override_rc` line, at the same path, on
# every production deploy. This script is staging's equivalent; it takes a host and is not
# wired into production's deploy. One path, two managers, one host each -- the headers the
# two write differ, so the file on a box always names whichever one owns it. Pointing both
# at the same host would leave them rewriting each other's header on alternating runs; if
# that ever becomes wanted, make the two bodies identical rather than running both.
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
# The merge below sees the stock `override_rc` because needrestart.conf assigns it ~150
# lines before it evals conf.d, not because of the filename. What `99-` buys is ordering
# against OTHER snippets: a later one cannot silently reassign over this. The filename is
# the one production uses, so on a host carrying a hand-copied version of it this converge
# REPLACES the pet file instead of sitting beside it.
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
staged="${conf_d}/.99-sysbox.conf.new"

# Nothing may leave a staged file behind in a directory needrestart reads. It cannot be
# picked up -- the name does not end in .conf, and needrestart globs *.conf -- but one per
# failed deploy accumulates, and the next reader has to work out which file is live.
trap 'rm -f "$staged"' EXIT

cat > "$staged" <<'NRCONF'
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
# Merge, never reassign -- a bare assignment would drop the 43 stock entries this hash
# already carries, among them qr(^docker) => 0. Dropping that one hands unattended-upgrades
# permission to restart Docker out from under every container on the host.
$nrconf{override_rc} = { %{$nrconf{override_rc} // {}}, qr(^sysbox) => 0 };
NRCONF
chmod 0644 "$staged"

# Both assertions run against the STAGED file, before it is published. needrestart `die`s
# on a snippet that does not compile, and it is unattended-upgrades that carries the error
# -- so a broken file here is worse than no file at all: it aborts every upgrade run on the
# box until someone removes it. Validating after the `mv` would report that correctly and
# still have installed it. The staged name is safe to leave sitting there while this runs,
# because needrestart globs `*.conf` and this is not one.

# Both assertions exit 4 rather than letting perl's own status through. perl exits 255 on
# a compile error or a `die`, and 255 is also how ssh reports that it never got a session
# at all -- so an unremapped failure here would be read locally as an unreachable host and
# send whoever is looking at the deploy to the wrong place entirely. Nothing in this remote
# script may exit 255.

# --- assertion 1: it parses -------------------------------------------------------
perl -c "$staged" || exit 4

# --- assertion 2: it says what it is meant to say ---------------------------------
# Parsing is not the property that matters; matching a real unit name and preserving the
# stock hash are. The seeded entry stands in for the 43 the stock config ships -- among
# them `qr(^docker) => 0`, so a snippet that regressed to a bare assignment would still
# parse, still deselect sysbox, and hand unattended-upgrades permission to restart Docker
# out from under every container on the host.
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
' "$staged" || exit 4

# Only now is it allowed to become the live file.
mv "$staged" "$dropin"

after=$(md5sum "$dropin" | cut -d' ' -f1)
if [ "$before" = "$after" ]; then
  echo "drop-in already current at ${dropin} (unchanged)"
elif [ -z "$before" ]; then
  echo "drop-in created at ${dropin}"
else
  echo "drop-in updated at ${dropin} (${before} -> ${after})"
fi

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
else
  # Signalled by exit status rather than by a token in stdout, because the deploy log
  # streams this output live -- capturing it locally to grep for a marker would withhold
  # every line of it until the ssh returns. 3 is ours; ssh forwards it verbatim, and only
  # this branch produces it.
  echo "the drop-in is in place, but nothing on this box reads it yet."
  exit 3
fi
REMOTE

if [ "$rc" -eq 0 ]; then
  echo "✅ needrestart on ${HOST} will not auto-restart sysbox"
  exit 0
fi

# Everywhere else this script is careful not to claim more than it checked, and the closing
# line is no place to stop: on a box with no needrestart the third assertion cannot run, so
# what was converged is an override that is correct and not yet consulted by anything.
if [ "$rc" -eq 3 ]; then
  echo "✅ the override is in place on ${HOST}, and takes effect if needrestart is ever installed"
  exit 0
fi

# 255 is ssh's own failure -- connect timed out, host unreachable, auth rejected, or the
# connection dropped mid-command -- and not a status forwarded from the remote script. The
# two send an operator to completely different places, and the remote script has already
# printed a precise reason for every exit of its own, so repeating a generic one over the
# top of it is worse than saying nothing. Same split, for the same reason, as
# clear-root-password-expiry.sh.
if [ "$rc" -eq 255 ]; then
  # Unambiguous: the remote script remaps its own perl failures off 255 precisely so this
  # branch can only mean ssh itself.
  echo "::error::Could not complete an SSH session with ${HOST}, so the drop-in was not converged."
  echo "::error::This is a reachability problem, not a needrestart one -- the preceding steps reach"
  echo "::error::the same host the same way, so check those first."
else
  echo "::error::Reached ${HOST}, but converging the needrestart sysbox drop-in exited ${rc}."
  echo "::error::The remote output above says which part failed -- the write, one of the two"
  echo "::error::assertions about the snippet, or the check that needrestart still reads conf.d."
fi

echo "::error::Until the override is in place and readable, the next apt-daily-upgrade that"
echo "::error::touches a library sysbox links against will restart sysbox-mgr/sysbox-fs and"
echo "::error::PERMANENTLY orphan every sysbox container on the box -- including the worker this"
echo "::error::deploy is about to put there. It keeps reporting Status=running while every"
echo "::error::\`docker exec\` into it fails with \"unsafe procfs detected\"; see"
echo "::error::https://github.com/tadasant/zimmer/issues/774 and docs/operate/nested-docker."
exit 1
