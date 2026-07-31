# `.agent-containers/` — containerized Zimmer dev environment

Run an isolated, fully containerized Zimmer (Rails app + Postgres + Redis) for
development — without installing Ruby, Postgres, or Redis on your host. This is
the containerized alternative to the host-process `bin/dev` flow described in
[Run it locally](../docs/src/content/docs/start/local.md); use whichever suits
you.

It exists so that many agent (or human) sessions can run **in parallel**, each in
its own git clone, on its own database, on its own dynamically-assigned host port,
with no collisions. `ac.sh` orchestrates that.

## Quick start

```bash
# Boot a new isolated session named "spike" (first run is slow: bundle + db).
.agent-containers/ac.sh clone spike

# See its assigned host port and health.
.agent-containers/ac.sh status spike

# Attach the Claude Code tmux window (if `claude` is installed).
.agent-containers/ac.sh attach spike

# Tail the Rails log.
.agent-containers/ac.sh logs spike

# Tear it all down (removes the postgres volume too).
.agent-containers/ac.sh destroy spike
```

`ac.sh` commands: `clone`, `status`, `open`, `attach`, `logs`, `stop`, `destroy`.
Run `.agent-containers/ac.sh` with no arguments for the full list. Sessions clone
into `~/.zimmer-dev-sessions/<name>` by default (override with
`AC_WORKSPACE_DIR`).

## Manual setup (no `ac.sh`)

If you just want one stack against your current checkout. Note this is a **single
shared stack** (project `zimmer-dev-local`) — for running several isolated
instances in parallel, use `ac.sh`, which gives each its own project and port.

```bash
cd <repo root>

# Build + start db, redis, and the app workspace (app runs `sleep infinity`).
# APP_PORT=0 picks a random free host port; set APP_PORT=3000 to pin it.
APP_PORT=3000 docker compose -f .agent-containers/docker-compose.dev.yml up -d --build

# One-time prepare: bundle install + create/migrate both databases.
docker compose -f .agent-containers/docker-compose.dev.yml exec app .agent-containers/setup.sh

# Start the Rails web server + Tailwind watcher (backgrounded via nohup).
docker compose -f .agent-containers/docker-compose.dev.yml exec app .agent-containers/run.sh

# Confirm it's up.
curl -fsS http://localhost:3000/up && echo " UP"
```

Find the assigned port when you used `APP_PORT=0`:

```bash
docker compose -f .agent-containers/docker-compose.dev.yml port app 3000
```

## Teardown — always use `-v`

The Postgres data lives in a **named volume** (`postgres_data`). A plain
`docker compose down` leaves it behind; over many sessions those orphaned volumes
pile up. Always tear down with `-v`:

```bash
docker compose -f .agent-containers/docker-compose.dev.yml down -v
```

`ac.sh destroy` and `ac.sh stop` do the right thing (`destroy` uses `-v`).

### Two automatic backstops

You do not have to remember teardown for agent sessions — Zimmer reaps stacks two
ways, and both rely on every stack's project name starting with `zimmer-dev-`:

- **Path-based, on clone cleanup** — `DockerComposeCleanupService`
  (`app/services/docker_compose_cleanup_service.rb`) runs
  `docker compose -f <clone>/.agent-containers/docker-compose.dev.yml down -v`
  when a Zimmer-managed clone is cleaned up. With no `-p`, it targets the compose
  file's own `name:` (`zimmer-dev-local`) — i.e. a stack you started the manual
  way inside that clone. (An `ac.sh` stack lives in its own separate clone under
  `~/.zimmer-dev-sessions/`, which Zimmer never cleans up, so this path never
  needs to reach it — `ac.sh destroy` and the age-based reaper do.)
- **Age-based, every 6 h** — `DockerCleanupJob`
  (`app/jobs/docker_cleanup_job.rb`) stops any Compose project whose name starts
  with a `DEV_SERVER_PREFIXES` entry (`zimmer-dev-`) and has been running longer
  than `MAX_DEV_SERVER_AGE`. This matches **both** `zimmer-dev-local` (manual) and
  `zimmer-dev-<name>` (ac.sh), so it catches long-lived stacks either other path
  might leak.

⚠️ If you change the compose project name/prefix in `ac.sh` or the compose file,
change `DockerCleanupJob::DEV_SERVER_PREFIXES` in the same commit, or the age-based
reaper stops matching and stacks leak.

## Logs

`run.sh` starts each process under `nohup`, writing to `/app/.logs/` (mounted from
the repo, so also visible on the host under `.logs/`, which is `.gitignore`d):

- `.logs/app.log` — the Rails web server
- `.logs/css.log` — the Tailwind watcher

```bash
.agent-containers/ac.sh logs <name> app   # or: css
```

## Auth (credentials the container borrows from your host)

`docker-compose.dev.yml` bind-mounts two host directories into the `app`
container so it inherits your logins:

- `~/.claude` → `/root/.claude` — Claude Code OAuth session
- `~/.config/gh` → `/root/.config/gh` — GitHub CLI token (also brokers `git`
  push/pull over HTTPS via the `gh auth git-credential` helper baked into the
  image)

Both are optional: the stack boots without them. Only interactive agent work and
opening PRs need them.

## Networking

- The app listens on container port **3000**; the host port is dynamic
  (`APP_PORT`, default `0` → random). One stack per session means no port
  contention.
- Inside the compose network, the app reaches Postgres at `db:5432` and Redis at
  `redis:6379` — that wiring lives in [`.env.dev`](.env.dev).
- `/var/run/docker.sock` is mounted in so a session can drive sibling containers.

## Services

| Service | Image | Purpose | Healthcheck |
| --- | --- | --- | --- |
| `app`   | built from `Dockerfile.dev` | Rails 8 web + Tailwind watcher; long-lived workspace (`sleep infinity`) | via `/up` after `run.sh` |
| `db`    | `postgres:16` | `zimmer_development` + `zimmer_development_cable` | `pg_isready` |
| `redis` | `redis:7-alpine` | cache + Action Cable | `redis-cli ping` |

## Design notes

- **Why not `bin/dev`/foreman inside the container?** foreman forwards signals to
  its whole process group and exits with the launching shell, which fights with
  `nohup` and `docker compose exec`. `run.sh` starts the two `Procfile.dev`
  processes directly under `nohup` instead. Same processes, container-friendly
  lifecycle.
- **No worker process.** In development GoodJob runs `:async` in-process with
  Puma (`config/environments/development.rb`), so there is nothing to start beyond
  `web` and `css`. Production/staging use a separate `good_job start` worker.
- **Gems install to the image's bundle path, not the mounted repo.** The `ruby`
  base image sets `BUNDLE_APP_CONFIG`/`BUNDLE_PATH` to `/usr/local/bundle`, which
  overrides the repo's `.bundle/config`. That's deliberate: it keeps
  container-compiled native gems out of the bind-mounted `vendor/bundle`, so a
  containerized `bundle install` never clobbers a host-side one (which matters if
  your host isn't Linux). Gems persist across container restarts but are
  reinstalled on a rebuild.
- **`.env.dev` is committed on purpose.** It holds only service wiring, no
  secrets. Secrets arrive through the mounted credentials or your own runtime env.

See [`VERIFY.md`](VERIFY.md) for the verification playbook.
