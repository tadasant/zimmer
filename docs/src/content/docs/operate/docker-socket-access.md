---
title: Docker socket access
description: Zimmer's worker container can drive the host's Docker daemon. What that grants, why it is on, and how to turn it off.
---

Zimmer's **worker** container — the one agent sessions run inside — has access to the
host's Docker daemon. That is a deliberate choice with a real cost, and this page is the
honest version of it.

:::danger[This is root-equivalent access to the host]
Anything that can talk to the Docker socket can start a container that mounts `/` and
runs as root. There is no meaningful privilege boundary between "can use the Docker
socket" and "is root on this machine".

So an agent session on a Zimmer host can control every container on the box — including
Zimmer's own web and worker containers, and its database. **Only run agent workloads you
trust on a host configured this way.**
:::

## How it is wired

Two halves, in the `worker` role of `config/deploy.production.yml` and
`config/deploy.staging.yml`. Both are required; either alone does nothing.

```yaml
worker:
  options:
    group-add: "<%= ENV.fetch('DOCKER_GID', '988') %>"
    volume:
      - /var/run/docker.sock:/var/run/docker.sock
```

The **mount** puts the socket in the container. The **group** makes it usable: the socket
is `srw-rw---- root:docker` and Zimmer's image runs as uid/gid 1000 (`Dockerfile`:
`USER 1000:1000`), so a container without the `docker` group as a supplementary group
gets `permission denied while trying to connect to the Docker API` on every call.

For most of Zimmer's history only the mount was present. It came across, along with
`DockerCleanupJob`, when Zimmer was extracted from its ancestor; the `group-add` line did
not. Both were inert until it was added.

## `DOCKER_GID` is host-specific

`988` is the `docker` group's GID on Zimmer's own droplets. **It is not a standard.**
Debian and Ubuntu assign it from the dynamic system range, so a fresh host commonly lands
on `999`, `998`, or something else entirely.

Check yours before assuming the default fits:

```bash
getent group docker          # docker:x:988:
stat -c '%g' /var/run/docker.sock
```

If it differs, export `DOCKER_GID` in the deploy environment and redeploy. A wrong GID
fails the same way as no GID at all — permission denied, with nothing pointing at the
cause.

## Verifying it took effect

`kamal deploy` restarts the container, so the group is applied on the next deploy. From
the host:

```bash
docker inspect <worker-container> --format '{{.Config.User}} | {{.HostConfig.GroupAdd}}'
# 1000:1000 | [988]
```

and from inside the container:

```bash
docker ps
```

An empty `GroupAdd` (`[]`) means the deploy predates the change or `DOCKER_GID` did not
reach Kamal.

## What it is for

- **`DockerCleanupJob`** reaps Compose projects named `zimmer-dev-*` older than
  `MAX_DEV_SERVER_AGE`, and prunes stale containers, images, volumes and build cache. It
  shells out to `docker`, so without socket access it silently reaps nothing — it treats
  the non-zero exit as "nothing to do".
- **`DockerComposeCleanupService`** tears down a session's Compose stack when its clone is
  cleaned up.
- **[`.agent-containers/`](/start/containers/)** — the Compose dev stack. With socket
  access a session can bring up a fully isolated app + Postgres + Redis, rather than
  sharing the `devdb` accessory that [`bin/agent-dev`](/sessions/dev-server/) uses.

## Turning it off

Delete the `group-add` line from the worker options and redeploy. The socket mount can
stay — without the group it grants nothing. Expect, in exchange:

- `DockerCleanupJob` and `DockerComposeCleanupService` become no-ops again. Nothing warns
  you; containers accumulate until someone prunes by hand.
- `.agent-containers/` becomes a workstation-only tool.
- `bin/agent-dev` keeps working. It needs no Docker at all — that is its point.

## Reducing the blast radius without giving it up

The socket is all-or-nothing, but it does not have to be reached directly:

- **A socket proxy** (for example `tecnativa/docker-socket-proxy`) sits between the
  container and the daemon and whitelists API endpoints. A session gets `compose up` and
  `compose down` without `POST /containers/create` with arbitrary binds.
- **Rootless Docker or a DinD sidecar** gives sessions their own daemon, so the blast
  radius is that daemon rather than the host.
- **Move sessions off the worker.** The coupling exists because agent sessions run inside
  the same container as the job runner. A separate, lower-privilege execution host would
  make this moot.

None of these are wired up today. They are the options if the current posture stops being
acceptable.
