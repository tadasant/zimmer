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

:::caution[It is off by default]
Nothing here is active unless a deploy sets `ZIMMER_NESTED_DOCKER=1`. Unset, the worker
runs under `runc` as uid 1000 exactly as before, and the host's Docker socket is not
mounted into it at all.
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
container-root:

```yaml
runtime: <%= ENV["ZIMMER_NESTED_DOCKER"] == "1" ? "sysbox-runc" : "runc" %>
user: "<%= ENV["ZIMMER_NESTED_DOCKER"] == "1" ? "0:0" : "1000:1000" %>"
```

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

For a **new** droplet, cloud-init does the host half. Then deploy with
`ZIMMER_NESTED_DOCKER=1` set in the deploy environment.

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
