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
    group-add: "<%= ENV['DOCKER_GID'].to_s.strip.empty? ? '988' : ENV['DOCKER_GID'].to_s.strip %>"
    volume:
      - /var/run/docker.sock:/var/run/docker.sock
```

(The long-hand default is deliberate. A CI `env:` block hands over an *unset* variable as
an empty string, and `ENV.fetch`'s default only applies to an absent key — so `ENV.fetch`
would yield `""` and render `--group-add ""`.)

The **mount** puts the socket in the container. The **group** makes it usable: the socket
is `srw-rw---- root:docker` and Zimmer's image runs as uid/gid 1000 (`Dockerfile`:
`USER 1000:1000`), so a container without the `docker` group as a supplementary group
gets `permission denied while trying to connect to the Docker API` on every call.

The two are a pair. A mount without the group grants nothing, and the group without the
mount has nothing to grant — so an edit that drops either one disables every
Docker-dependent feature at once, without any single thing failing loudly.
`test/config/worker_docker_group_test.rb` asserts both halves together for that reason.

## `DOCKER_GID` is host-specific

`988` is the `docker` group's GID on Zimmer's own droplets. **It is not a standard.**
Debian and Ubuntu assign it from the dynamic system range, so a fresh host commonly lands
on `999`, `998`, or something else entirely.

Check yours before assuming the default fits:

```bash
getent group docker          # docker:x:988:
stat -c '%g' /var/run/docker.sock
```

If it differs, set `DOCKER_GID` in the deploy environment and redeploy. A wrong GID fails
exactly like no GID at all — permission denied, with nothing pointing at the cause.

Where "the deploy environment" is depends on how you deploy:

- **Running `kamal deploy` yourself:** export it in the shell.
- **Through this repo's staging workflow:** it is named in the `env:` block of the "Kamal
  deploy (staging)" step, so a repository variable named `DOCKER_GID` reaches Kamal. A var
  *missing* from that block arrives empty and `ENV.fetch`'s default silently wins — the
  same trap the Parameter Store key carries a comment about.
- **Production:** deployed from the private companion repo, so the override has to be
  plumbed there. Unset, the `988` default applies.

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

- **`DockerCleanupJob`** reaps Compose projects whose name starts with `zimmer-dev-`,
  `ao-dev-` or `pulsemcp-dev-` once they outlive `MAX_DEV_SERVER_AGE`, and prunes stale
  containers, images and volumes. (Build cache is pruned only by `emergency_cleanup`,
  which needs disk usage past `EMERGENCY_THRESHOLD`.)
- **`DockerComposeCleanupService`** tears down a session's Compose stack when its clone is
  cleaned up.
- **[`.agent-containers/`](/start/containers/)** — the Compose dev stack. With socket
  access a session can bring one up from the host it runs on, getting a fully isolated
  app + Postgres + Redis of its own.

Without socket access the failure is quieter than it should be, and unevenly so. The
prune paths log `Rails.logger.warn "[DockerCleanupJob] ... prune failed"`, so there is
something to find. But the discovery step — `find_stale_dev_server_projects` — does
`return [] unless SubprocessStatus.success?(status)` and logs nothing, so a permission
denial there is indistinguishable from "no stale stacks". That is the path that makes the
whole job look like it ran and found nothing to do.

## Turning it off

Delete the `group-add` line from the worker options and redeploy. The socket mount can
stay — without the group it grants nothing. Expect, in exchange:

- `DockerCleanupJob`'s stale-stack sweep silently finds nothing, and its prunes fail with
  a warning in the log. Containers accumulate until someone prunes by hand.
- `DockerComposeCleanupService` stops tearing down abandoned stacks.
- `.agent-containers/` becomes a workstation-only tool.

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
