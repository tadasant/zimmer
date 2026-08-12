---
title: Run it in containers
description: Boot an isolated, containerized Zimmer (app + Postgres + Redis) with Docker Compose — no host Ruby, Postgres, or Redis required.
sidebar:
  order: 2
---

[Run it locally](/start/local/) runs Zimmer as host processes and expects you to
supply Postgres and Redis yourself. The containerized environment in
`.agent-containers/` does the opposite: it brings up the whole stack — the Rails
app, Postgres, and Redis — in Docker, so you need nothing on your host but Docker
itself.

It exists mainly so **many sessions can run in parallel**. Each session is its own
Compose project, in its own git clone, on its own database, on its own
dynamically-assigned host port. That isolation is what lets a fleet of agent
sessions build against Zimmer at once without colliding.

## Prerequisites

- **Docker** with the Compose plugin (`docker compose version`).
- That's it. Ruby, Postgres, and Redis all live in containers.
- Optional: the **`claude`** CLI and **`tmux`** on the host, if you want `ac.sh`
  to drop you into a Claude Code session; **`gh`** logged in on the host, if you
  want the container to inherit your GitHub auth.

## The `ac.sh` way (parallel sessions)

`.agent-containers/ac.sh` orchestrates isolated sessions:

```bash
.agent-containers/ac.sh clone spike     # clone + build + boot a session named "spike"
.agent-containers/ac.sh status          # every session, with its port and health
.agent-containers/ac.sh attach spike    # attach the Claude Code tmux window
.agent-containers/ac.sh logs spike      # tail the Rails log
.agent-containers/ac.sh destroy spike   # tear it down (removes its volume + clone)
```

Commands: `clone`, `status`, `open`, `attach`, `logs`, `stop`, `destroy`. Clones
land in `~/.zimmer-dev-sessions/<name>` (override with `AC_WORKSPACE_DIR`). Each
`clone` picks a random free host port, so two sessions never fight over `:3000`.

The first `clone` is slow: it runs `bundle install` and creates both databases.

## The manual way (one stack, current checkout)

This is a single shared stack (Compose project `zimmer-dev-local`) — fine for one
developer or a quick check, but not isolated. For parallel instances use `ac.sh`.

```bash
# Build + start db, redis, and the app workspace. APP_PORT=0 → random host port;
# pin it with APP_PORT=3000 for copy-paste health checks.
APP_PORT=3000 docker compose -f .agent-containers/docker-compose.dev.yml up -d --build

# One-time prepare: bundle install + create/migrate both databases.
docker compose -f .agent-containers/docker-compose.dev.yml exec app .agent-containers/setup.sh

# Start web + css (backgrounded via nohup, logs in .logs/).
docker compose -f .agent-containers/docker-compose.dev.yml exec app .agent-containers/run.sh

curl -fsS http://localhost:3000/up && echo " UP"
```

When you used `APP_PORT=0`, find the port with
`docker compose -f .agent-containers/docker-compose.dev.yml port app 3000`.

## What's in the box

| Service | Image | Role |
| --- | --- | --- |
| `app` | built from `.agent-containers/Dockerfile.dev` | Rails 8 web + Tailwind watcher; a long-lived workspace (`sleep infinity`) that `run.sh` starts the server inside |
| `db` | `postgres:16` | `zimmer_development` + `zimmer_development_cable` |
| `redis` | `redis:7-alpine` | cache + Action Cable |

The app reads its Postgres and Redis wiring from the committed
`.agent-containers/.env.dev` (`db:5432`, `redis:6379`) — it holds no secrets. The
container borrows your host `~/.claude` and `~/.config/gh` credentials via bind
mounts, both optional.

Unlike `bin/dev`, the container does **not** run foreman: `run.sh` starts the two
`Procfile.dev` processes (`web`, `css`) directly under `nohup`, which behaves
better under `docker compose exec`. As in local dev, there is no worker process —
GoodJob runs `:async` in-process.

## Teardown always uses `-v`

Postgres data lives in a named volume. A plain `down` orphans it; always:

```bash
docker compose -f .agent-containers/docker-compose.dev.yml down -v
```

`ac.sh destroy` does this for you. Stacks are also reaped automatically:
`DockerCleanupJob` stops any Compose project named `zimmer-dev-*` (both the manual
`zimmer-dev-local` and per-session `zimmer-dev-<name>`) that has outlived
`MAX_DEV_SERVER_AGE`, every 6 hours; and `DockerComposeCleanupService` tears down a
manual `zimmer-dev-local` stack by compose-file path when its Zimmer-managed clone
is cleaned up. See [Background jobs](/operate/background-jobs/).

The full playbook — infrastructure, `ac.sh`, and browser checks — is in
`.agent-containers/VERIFY.md`.
