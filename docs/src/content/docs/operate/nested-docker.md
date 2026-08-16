---
title: Nested Docker for agent sessions
description: How the worker runs its own Docker daemon under sysbox instead of reaching the host's, what it costs, and the workaround it currently depends on.
---

Agent sessions run inside the worker container and want `docker compose` for a per-session
dev stack. The obvious way to give them that — mount the host's Docker socket and add the
container to the host's `docker` group — hands every session **root-equivalent access to
the host**: anything that can talk to that daemon can start a container mounting `/` as
root.

This page describes what Zimmer does instead: the worker runs its **own** Docker daemon,
inside its own user namespace, under the [sysbox](https://github.com/nestybox/sysbox)
runtime.

:::caution[On in staging, off in production]
**Staging deploys with this armed by default** — `config/deploy.staging.yml` resolves
`ZIMMER_NESTED_DOCKER` to `1` unless the deploy environment says otherwise, and the
`Deploy staging` workflow exposes a `nested_docker` checkbox (default on) to turn it off.

**Production still defaults to off**: unset, the worker runs under `runc` as uid 1000
exactly as before. Production is where agent sessions actually run, so it gets the switch
only once staging has carried it — see [Extending it to production](#extending-it-to-production).

In neither case is the host's Docker socket mounted into the worker.
:::

## Why a nested daemon confines and a socket mount does not

Under sysbox the container gets its own user namespace. Container root maps to an
unprivileged host uid:

```
# worker image under sysbox-runc
/proc/self/uid_map:  0  100000  65536     <- container root -> host uid 100000
# the same image under plain runc
/proc/self/uid_map:  0       0  4294967295 <- container root IS host root
```

That mapping is the whole fence. Measured on staging, from a `--privileged` container
started *inside* the nested daemon, bind-mounting `/`:

| attempt | result |
| --- | --- |
| read a host-only sentinel file | `No such file or directory` |
| inspect what `/` resolves to | the worker container's root, not the host's |
| reach `/var/run/docker.sock` on the host | not present |
| read `/proc/1/comm` | the worker's PID 1, not the host's `systemd` |
| `mount /dev/vda1` | device not visible; `mount: permission denied` |
| `modprobe` a kernel module | fails |
| write `/sys/kernel/profiling` | `Permission denied` |

A privileged container inside the nested daemon cannot reach the host. A container started
through a mounted host socket trivially can.

There is a second, quieter benefit: the nested daemon resolves bind-mount sources **inside
the worker**, so `.agent-containers/`'s `..:/app` resolves against the clone as the worker
sees it, and the host accumulates nothing. No `zimmer-dev-*` stacks pile up on the host,
which is most of what `DockerCleanupJob` exists to sweep.

## How it is wired

Three pieces that only work together, which is why one variable arms all of them.

**The host** (`infra/terraform/cloud-init.yaml.tftpl`) installs sysbox, registers the
`sysbox-runc` runtime in `/etc/docker/daemon.json`, and sets the workaround flag below.

**The image** (`Dockerfile.base`) carries `docker-ce`, `containerd.io`, `iptables` and
`uidmap` alongside the CLI and compose plugin. That is about **+340 MB**, and it lands on
the single image Kamal ships to *both* roles — `web` carries a daemon it never starts.

**The role** (`config/deploy.*.yml`) runs the worker under the runtime and starts it as
container-root. The switch is resolved once per destination — that is the only thing that
differs between staging and production — and all three settings read the resolved value,
so they cannot drift apart:

```erb
<%# top of the file; production's default is "0" %>
<% nested_docker = ENV.fetch("ZIMMER_NESTED_DOCKER", "1") == "1" %>

<%# under servers.worker.options %>
runtime: <%= nested_docker ? "sysbox-runc" : "runc" %>
user: "<%= nested_docker ? "0:0" : "1000:1000" %>"

<%# further down, under env.clear -- destination-wide, so it reaches web too %>
ZIMMER_NESTED_DOCKER: "<%= nested_docker ? "1" : "0" %>"
```

The three are not adjacent in the file; they are grouped here because they are one
decision. `web` receives the env var (`env.clear` is destination-wide) and ignores it —
the entrypoint's dockerd block sits inside its `id -u = 0` branch, and `web` runs as 1000.

`test/config/nested_docker_switch_test.rb` renders both destinations at all three switch
states (unset, `0`, `1`) and asserts the three settings are armed together or not at all —
the interesting failure being a config that arms two of them.

`dockerd` needs root *inside* the container, and the image normally runs as uid 1000. So
`bin/docker-entrypoint` starts as container-root, brings up `dockerd --group 1000` (the
group makes the socket usable after the drop), then re-execs itself as 1000 via `setpriv`.
The app never keeps running as root — the clones volume is shared with `web`, which runs as
1000, and root-owned files written there would be unwritable.

The entrypoint **refuses to start** if `ZIMMER_NESTED_DOCKER=1` but the container is not
user-namespaced, rather than silently handing a session real host root:

```
ZIMMER_NESTED_DOCKER=1 but this container is not user-namespaced.
Its root IS host root, so starting dockerd here would hand every agent
session root on the host.
```

### The environment has to be dropped too, not just the credentials

`setpriv` changes credentials and nothing else, so whatever `HOME` the container started
with survives the drop untouched. Left to the runtime, `user: "0:0"` would make that `/root`
— mode `0700` and owned by root, which uid 1000 cannot even traverse — and the app would run
as uid 1000 pointed at it. (The image pins `HOME` so it never comes to that; the two layers
are reconciled in [the subsection below](#the-entrypoint-only-covers-what-the-entrypoint-runs).)

That is not cosmetic, and it is not a tidiness problem. It took production down for ten
hours on 2026-08-13:

- **libpq** probes `$HOME/.postgresql/postgresql.crt` on every TLS connection and tolerates
  only `ENOENT`/`ENOTDIR`. `EACCES` is fatal. With `HOME=/root` the worker opened **no
  database connection at all** — no `LISTEN`, no poll, no claim, and no failure recorded
  anywhere, because recording one needs the database too.
- `~/.claude`, `~/.config/gh` and `~/.local` are Kamal volumes mounted under `/home/rails`.
  Pointed at `/root` they are simply not there, so agent sessions lose their CLI auth and
  their persisted Claude install.

So `bin/docker-entrypoint` reads the app user's home directory and name out of
`/etc/passwd` — exporting them as `HOME` and `USER`, with `LOGNAME` following `USER` — and
then **proves the result as the user that will have to live with it**, refusing outright if
uid 1000 cannot traverse and write that directory:

```
Refusing to start: HOME=/home/rails is not writable by uid 1000, which this
entrypoint is about to become.
```

#### The entrypoint only covers what the entrypoint runs

That fixup reaches the app process and its children, and nothing else. Two things in the
container never pass through it:

- **PID 1.** Every role sets `init: true`, so PID 1 is `docker-init`, which *forks* the
  entrypoint rather than exec'ing it. Its environment is the one Docker built from
  `--user`, untouched.
- **Every `docker exec`.** Docker builds an exec's environment from the container's
  config, not from PID 1's descendants. `docker exec -u 1000:1000 <worker> …` — the shape
  an operator debugging a session reaches for — therefore lands on `HOME=/root` at a uid
  that cannot traverse it.

So the image pins it too, with `ENV HOME=/home/rails` in the `Dockerfile`. That makes
`HOME` a property of the app user rather than of the uid the container happens to be
started as, and the two layers cover different halves: the image ENV makes the *container's*
environment right for everything that never runs the entrypoint, and the entrypoint proves
the directory is actually usable and refuses to boot when it is not — which no `ENV` can
check. Losing either reopens a real path to `/root`.

#### `kamal app exec --reuse` runs as root, and skips the entrypoint

`--reuse` is a bare `docker exec` into the running container
(`kamal/commands/app/execution.rb`), so it does **not** run the ENTRYPOINT and it inherits
the container's configured user — which under nested Docker is `user: "0:0"`. Your command
therefore runs as **root**, with none of the entrypoint's normalization applied.

The image `ENV` means it at least gets a working `HOME`, so DB-touching commands no longer
die on `could not open certificate file "/root/.postgresql/postgresql.crt": Permission
denied`. What it does not do is make the command run as uid 1000. Anything that writes under
`~` — `~/.zimmer/clones`, `~/.claude`, `~/.config/gh` — leaves **root-owned files in volumes
that `web` and the app read at uid 1000**, and those are unwritable afterwards.

So on the worker, prefer plain `kamal app exec` (no `--reuse`): that is a `docker run`
against the image, which runs the entrypoint and drops to uid 1000 properly. It is not free
— `execute_in_new_container` passes the role's option and env args too, so on the worker it
starts a throwaway container under sysbox that boots its own disposable inner `dockerd`
before your command runs. Expect the latency.

Reach for `--reuse` only for read-only inspection, and pass `docker exec -u 1000:1000`
directly if you need the app's identity inside the existing container.

A container that refuses to start is a failed deploy. One that starts and quietly claims
nothing is ten hours of silence — which is exactly what happened, because every check that
existed asked whether the container was *shaped* right, not whether the worker was
*working*. `test/config/docker_entrypoint_privilege_drop_test.rb` runs the real script with
`id`, `getent` and `setpriv` stubbed and asserts on the environment it hands over; it fails
against the entrypoint as it shipped that morning.

## The workaround this depends on

`/etc/docker/daemon.json` carries:

```json
{ "features": { "time-namespaces": false } }
```

Docker puts a `time` namespace in every container's OCI spec, and sysbox rejects it —
`OCI runtime create failed: namespace {"time" ""} does not exist`. Without this flag **no
sysbox container starts at all**, including `docker run alpine echo hi`.

Be clear about what it costs while it is in place:

- **It is global.** Every container on the host loses its own time namespace, not just
  sysbox ones. A normal `runc` container shares the host's — verified identical.
- **It is invisible.** Not surfaced in `docker info`. Nothing short of reading
  `daemon.json` reveals it.
- **It is load-bearing.** Remove it and every sysbox container stops starting.

It is inert for Zimmer — nothing here wants per-container clocks — and staging ran hours
with it and zero restarts. It is a workaround for [nestybox/sysbox#1011](https://github.com/nestybox/sysbox/issues/1011),
and removing it is tracked in
[#421](https://github.com/tadasant/zimmer/issues/421).

## Turning it on

For a **new** droplet, cloud-init does the host half. Staging then deploys armed with no
further action; production needs `ZIMMER_NESTED_DOCKER=1` in the deploy environment.

### What the staging deploy checks for you

`Deploy staging` refuses to deploy onto a droplet that cannot carry it, rather than letting
it present as an app bug. **Before** the cutover it starts a throwaway sysbox container and
reads its `uid_map` — one command that settles all three host requirements at once, since a
non-identity map (`0 100000 65536`) can only happen if the runtime resolved, the
`time-namespaces` flag is in place, and the user namespace is real:

```bash
docker run --rm --runtime=sysbox-runc alpine head -1 /proc/self/uid_map
```

**After** the cutover it asserts the properties an agent session actually depends on: the
container's runtime is `sysbox-runc`, its `uid_map` is non-identity, the host socket is
**not** among its mounts, the inner daemon answers `docker version` **as uid 1000** (not
merely as root — uid 1000 is what a session runs as after the privilege drop), and the
container's `HOME` is `/home/rails` and is traversable and writable at uid 1000.

That last one is not padding, and it is worth being precise about what it reads. It takes
`HOME` off PID 1, which is `docker-init` — so it sees the environment Docker derived from
`--user`, *not* the one `bin/docker-entrypoint` exports. That is deliberate: the entrypoint's
own guard already covers the app process and refuses to boot without it, so the useful thing
left to assert is the half nothing else checks — the environment every `docker exec` into the
worker inherits. It fails when the image stops pinning `ENV HOME=/home/rails` and Docker falls
back to deriving `/root` from `user: "0:0"`.

`HOME=/root` reaching the app is how the 2026-08-13 freeze presented, and every
container-shaped check stayed green throughout it.

### Extending it to production

The mechanism is identical and already written — production's config resolves the same
switch, and its role, image and entrypoint are the same ones staging uses. What production
needs is the two things staging has:

1. **The host half.** `infra/terraform/cloud-init.yaml.tftpl` covers a *new* droplet. A
   live production droplet predates it, so sysbox has to be applied out of band by the
   by-hand route below — and `ignore_changes = [user_data]` means editing the template will
   not touch a running box.
2. **The switch.** `ZIMMER_NESTED_DOCKER=1` in production's deploy environment, plus the
   preflight and post-deploy assertions that `Deploy staging` carries, ported to
   production's deploy workflow.

Do it as its own change, after staging has run on it. The blast radius is not comparable:
production is where agent sessions actually execute, and the failure mode of arming the
runtime without a working user namespace is that every session gets root on the host.

### Installing sysbox on an existing droplet

For an **existing** droplet, cloud-init will not help: `main.tf` sets
`ignore_changes = [user_data]`, so the template renders once at first boot and editing it
never touches a running box. The install has to be applied out of band — and the package's
own postinst refuses to run while any container exists, demanding
`docker rm $(docker ps -a -q) -f`, which on a live host means a full teardown.

The by-hand route avoids that. It registers the runtime without the postinst's network
step, and needs only a daemon restart, which running containers survive:

```bash
apt-get install -y jq fuse3 rsync                 # fuse3 is required and NOT pulled in
curl -fsSL -o /tmp/sysbox.deb \
  https://downloads.nestybox.com/sysbox/releases/v0.7.0/sysbox-ce_0.7.0-0.linux_amd64.deb
dpkg --unpack /tmp/sysbox.deb                     # unpack only; skip the postinst
useradd -s /bin/false sysbox 2>/dev/null || true
jq --indent 4 '.runtimes |= (. // {}) + {"sysbox-runc":{"path":"/usr/bin/sysbox-runc"}}
            | .features |= (. // {}) + {"time-namespaces": false}' \
  /etc/docker/daemon.json > /tmp/dj && install -m0644 /tmp/dj /etc/docker/daemon.json
systemctl daemon-reload && systemctl enable --now sysbox-mgr sysbox-fs
systemctl restart docker                          # containers restart per their policy
```

Verify before deploying anything onto it:

```bash
docker info --format '{{range $k,$v := .Runtimes}}{{$k}} {{end}}'   # expect sysbox-runc
docker run --rm --runtime=sysbox-runc alpine echo ok                # expect: ok
```

If that last command fails with the `time` namespace error, the flag did not land.

### Then check the worker *works*, not that it exists

Those checks say the host can start a sysbox container. They say nothing about whether the
worker inside one is doing its job, and that distinction is the whole lesson of 2026-08-13:
the deploy went green on four assertions about the container's shape while the queue sat
frozen for ten hours. Before trusting a nested-Docker deploy, watch a job go all the way
through:

```bash
# from the worker container -- run it there specifically, because the point is to ask the
# question from the process whose database access is in doubt
bin/rails runner 'GoodJob::Job.where("created_at > ?", 5.minutes.ago).where.not(finished_at: nil).count'
```

Read both outcomes as failures. **Zero** finished jobs against a non-empty queue means the
worker is up and not working. And the command **raising** — `ActiveRecord::ConnectionNotEstablished`
is what it did during this outage — is not a broken check, it *is* the symptom: the worker
container cannot reach the database, so nothing it hosts can either.

The same reading applies to an empty `good_job_processes` table. A worker that cannot reach
the database cannot register itself, which is why "no tracked processes" and "everything
looks healthy" showed up together for ten hours.

## When the worker wedges

A `memory:` cap makes cgroup OOM the *designed* containment path: a runaway allocation is
killed inside the worker's cgroup instead of becoming a global out-of-memory event that
takes sshd and the proxy with it. Under plain `runc` that path terminates cleanly — the
container exits and `unless-stopped` restarts it.

Under `sysbox-runc` it can end somewhere else
([#502](https://github.com/tadasant/zimmer/issues/502)). The kill empties the container of
every process, but the container never *exits*, so:

```
Status=running   Running=true   Restarts=0   OOMKilled=true
```

`docker ps` says `Up`. The restart policy never fires. Every check that reads container
state passes. And every `docker exec` into it fails:

```
OCI runtime exec failed: exec failed: container_linux.go:439:
starting container process caused: process_linux.go:119:
executing setns process caused: exit status 1
```

That combination is the whole problem: the worker keeps its slot, reports healthy, and
runs no jobs and no agent sessions. Nothing about its shape says so.

### What watches for it

`zimmer-worker-watchdog`, a systemd timer on the host. It does not read container state —
it runs a real `docker exec` every 60 seconds, because exec is the operation that actually
breaks. Three consecutive failures against a container Docker still reports as `running`
is the signature.

It lives on the host, not in the app, because the app cannot watch this: Zimmer's cron runs
on GoodJob **in the worker**, so a job that watches the worker is a job that dies with it.
The alert is delivered the other way round, through the *web* container
(`bin/rails zimmer:worker_wedge_alert`, see `app/services/worker_wedge_alert.rb`), which
shares the image and the Slack credentials and is untouched by the worker's cgroup. So
detection needs no Rails and delivery needs no secret on the host.

| Where | What |
| --- | --- |
| `scripts/worker-watchdog.sh` | the probe, installed as `/usr/local/sbin/zimmer-worker-watchdog` |
| `scripts/install-worker-watchdog.sh <host>` | the converge installer (unit + timer), run by `Deploy staging` |
| `/etc/default/zimmer-worker-watchdog` | per-host settings; `ZIMMER_WATCHDOG_RECOVER=0` turns recovery off |
| `/var/lib/zimmer-worker-watchdog/incidents/` | one JSON record per incident, for forensics |
| `journalctl -u zimmer-worker-watchdog` | every probe, healthy or not |

Production has no deploy workflow in this repository, so there it is installed by hand or
from the companion repo: `bash scripts/install-worker-watchdog.sh <prod-tailnet-host>`.

### What it will and will not do on its own

Recovery is gated on a census of the container's cgroup — **recursively**, because under
nested Docker the inner dockerd and its containers live in child cgroups, and a
non-recursive read would call a busy container empty. If any process other than the
`init: true` shim is alive in there, the watchdog alerts and touches nothing. Zero live
workload means nothing can be lost by killing the container, which is what makes the
automation safe rather than clever.

When it does act, it walks the first rungs of the ladder below and stops before the last
one. `docker rm` plus a redeploy is deliberately manual: nothing on the host can recreate
the container, so a misfire there would replace a wedged worker with no worker at all.

### The manual ladder

Nothing below the rung that works, works. This is the sequence that recovered staging on
2026-08-16:

```bash
w=$(docker ps --filter name=zimmer-worker --format '{{.ID}}' | head -1)
full=$(docker inspect -f '{{.Id}}' "$w")

# 1. docker restart / kill / rm -f  ->  all fail:
#    "tried to kill container, but did not receive an exit event"

# 2. kill the containerd shim. This is what actually moves it to `exited`.
pkill -9 -f "containerd-shim.*${full}"

# 3. the init: true shim is reparented to PID 1 rather than reaped -- kill it too
#    (find it in the container's cgroup: /sys/fs/cgroup/system.slice/docker-<id>.scope)

# 4. docker start  ->  "mkdir /run/containerd/io.containerd.runtime.v2.task/moby/<id>:
#    file exists"
rm -rf "/run/containerd/io.containerd.runtime.v2.task/moby/${full}"

# 5. docker start  ->  "failed to register with sysbox-mgr: redundant container
#    registration". The container id is burned; only a NEW one gets past this.

# 6. docker rm "$w", then re-run the deploy.
```

**Do not restart `sysbox-fs` to clear a stuck registration.** Any process blocked in it is
*permanently* orphaned: on staging that left 19 processes in `D` state (`runc:[…]` in
`fuse_flush`) which inflate load average and clear only on reboot.

Before reaching for any of it, confirm the shape rather than assuming it. `dmesg -T | grep
oom-kill` names both the scope and the victim, and the two cases read differently: a
`uid=1000` kill in the scope root is a plain-`runc` worker, which recovers on its own; the
sysbox wedge carries the uid-shifted `uid=101000` and `task_memcg=.../init.scope`.

## Kernel requirements

Sysbox needs either shiftfs or ID-mapped mounts. DigitalOcean's Ubuntu image ships the
generic kernel with no shiftfs, so ID-mapped mounts are what we rely on. `sysbox-mgr`
reports what it found at startup:

```
Shiftfs-on-overlayfs works properly: no
ID-mapped mounts supported by kernel: yes
Overlayfs on ID-mapped mounts supported by kernel: yes
```

Both `yes` lines are required. Ubuntu 24.04 / kernel 6.8 satisfies them.

## What was ruled out

**A socket proxy.** `docker compose up` *is* `POST /containers/create`, and
`tecnativa/docker-socket-proxy` filters by URL path and method without inspecting request
bodies — so it cannot separate a benign create from one with `Binds: ["/:/host"]` and
`Privileged: true`. Useful for read-mostly access; useless as a fence for this.

**Rootless DinD as a sidecar.** Measured on this host and it does not run:

```
[rootlesskit:parent] error: failed to start the child:
fork/exec /proc/self/exe: operation not permitted
```

Identical failure with seccomp *and* apparmor unconfined. It needs `--privileged`, which is
host-root-equivalent — so it buys nothing over the socket mount it was meant to replace.
