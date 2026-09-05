---
title: Booting the app inside a session
description: How an agent session runs the Zimmer dev server, why bin/dev cannot work there, and what has to exist on the host for bin/agent-dev to succeed.
---

An agent session that changes a screen should be able to look at the screen. For a long
time it could not, and the reason was not a missing skill or a missing instruction — the
host it runs on had no database on it anywhere the session could reach.

`bin/agent-dev` is the boot path that works from inside a session. This page is what it
does, what has to exist for it to work, and why the obvious alternatives don't.

## Where a session actually runs

A session is **not** its own container. `AgentSessionJob` runs inside the Kamal **worker**
container and spawns the agent CLI as a child process there, in a clone under
`/home/rails/.zimmer/clones/`. So the session inherits that container's constraints:

| | |
| --- | --- |
| User | uid 1000 (`rails`), no root, no sudo |
| Docker | `/usr/bin/docker` exists, and `/var/run/docker.sock` is mounted — but usable only if the host grants the worker the socket's group |
| Postgres client | none — no `psql`, no `pg_isready`, no server binaries. Only `libpq` and the `pg` gem |
| Network | the Kamal Docker bridge. Sibling accessories resolve by name (`zimmer-redis`, `zimmer-devdb`) |

Two consequences follow, and they are the whole story:

1. **A session cannot reliably start a database for itself.** Not with a package manager
   (no root), not from the image (no Postgres binaries), and not with Docker on a host
   that has not granted the worker the socket's group. The database has to already be
   running and reachable. A shared accessory is also simply the better answer than one
   Postgres per clone.
2. **`bin/dev` cannot work there.** It assumes Postgres on `localhost`, Redis on
   `localhost`, and `foreman` — which is in the `:development` gem group the deployed
   image does not install.

## What `bin/agent-dev` does

```bash
bin/agent-dev                 # pick a free port in 3000..3099, boot
PORT=4000 bin/agent-dev       # explicit port
bin/agent-dev --skip-server   # prepare the bundle + databases, don't boot
```

In order:

1. **Repairs the bundle.** `bundle check`, and when it fails, an install into `vendor/bundle`
   preceded by `bundle config unset --local path` and followed by `bundle config set --local path
   vendor/bundle`. The re-point matters: a clone
   whose `Gemfile.lock` matches the image's shares the image's read-only `/usr/local/bundle`, so
   a checkout that has since changed the Gemfile cannot install into it. The pin goes last so a
   failed install cannot strand the clone on an empty directory. See
   [Giving a clone its gems](/operate/background-jobs/#giving-a-clone-its-gems).
2. **Points at the dev Postgres** — `zimmer-devdb` by default, overridable with
   `ZIMMER_DEV_DB_HOST` / `_PORT` / `_USERNAME` / `_PASSWORD` / `_SSLMODE`.
3. **Derives a per-clone database name** from the clone directory and exports it as
   `DATABASE_NAME`.
4. **Preflights the connection** with a TCP probe, so "no Postgres on this host" is one
   line rather than a Rails backtrace.
5. **`db:prepare`**, then a one-shot `tailwindcss:build` (no watcher, no foreman).
6. **Starts `bin/rails server`** on a free port, binding `0.0.0.0`.

Confirm it with the health endpoint rather than a "server started" line:

```bash
curl -sf http://localhost:$PORT/up && echo UP
```

## The three things that used to break it

### There was no Postgres on the host at all

Production's database is the off-droplet DigitalOcean Managed cluster; nothing on the
droplet's Docker bridge listened on 5432. The fix is a Kamal accessory, `devdb`, declared
in both `config/deploy.production.yml` and `config/deploy.staging.yml`: a `postgres:16`
with clear credentials (`zimmerdev`/`zimmerdev`), reachable only on the private bridge,
holding nothing but scratch `zimmer_dev_<clone>` databases.

It is deliberately **volume-less**. Sessions come and go, each leaving a pair of
databases behind; a durable volume would accumulate them forever, and a restart that
should clean the slate wouldn't.

It is deliberately **not** staging's `db` accessory. That one holds staging's own data on
a durable volume, and a session running a feature branch's migrations has no business in
it.

:::note[The deploy boots it on both destinations — no manual step is owed]
Bare `kamal deploy` does not boot accessories. That is a true Kamal fact, and it is
where a recurring wrong conclusion about this deployment comes from, because **neither
destination deploys with bare `kamal deploy`.** Staging's `deploy-staging.yml` runs
`kamal accessory boot all -d staging` immediately before its deploy; production is
deployed from the private companion repo, whose `zimmer-deploy-prod.yml` runs
`kamal accessory boot all -d production` immediately before its deploy, unconditionally.
So the first deploy after a destination declares `devdb` creates it, and nobody is owed a
setup command.

Later deploys skip it: `accessory boot` looks for an existing container (`docker ps -a`)
and leaves the host alone if one is there. That is what makes running it every time free,
and it is also why a `devdb` that stops is not revived by deploying again
([#419](https://github.com/tadasant/zimmer/issues/419)). A preflight failure means the
accessory is not running right now, so the next step is `kamal accessory details devdb -d
<dest>` from an operator shell, not a setup command.
:::

### Every clone shares one database server

`config/database.yml` reads `DATABASE_NAME` in development and test, defaulting to the
historical literals when it is unset (every laptop, and CI, are unaffected). Set, it moves
all four names — `<name>`, `<name>_cable`, `<name>_test`, `<name>_test_cable`.

The test pair matters: `db:prepare` in development creates the test databases too, so
namespacing only the development pair would leave every session colliding on
`zimmer_test`. Postgres truncates identifiers past 63 bytes silently, so `bin/agent-dev`
caps what it sets at 52.

### `DATABASE_SSLMODE` leaked into the session

`CliSpawnEnv` strips `DATABASE_*` and `BUNDLE_*` from the spawned agent's environment so a
session resolves its own configuration instead of Zimmer's. `DATABASE_SSLMODE` was missing
from that list. Production sets it to `require`; every local Postgres ships with
`ssl = off`; libpq's answer to that pairing is a refused connection that reads like a
broken database rather than a leaked variable. It is cleared now, which is what leaves
`bin/agent-dev` free to export `disable` in its own shell. (Separately, a clone that sets
any of these in its own `.env` still wins over the clearing — that is by design, and not
the mechanism the script relies on.)

## What it does not give you

- **No worker process.** GoodJob runs `:async` inside the Rails process in development.
- **No CSS watcher.** `tailwindcss:build` runs once. Re-run it after changing styles.
- **Redis is the deployment's.** `REDIS_URL` is inherited and points at the real
  `zimmer-redis`; development's cache store selects database 1 while the deployment uses
  0, so they land in different logical databases.
- **A booted dev app holds real credentials.** `RAILS_MASTER_KEY` and the session's
  environment are present. It is not a sandbox. It binds `127.0.0.1` by default for that
  reason; `BINDING=0.0.0.0` would offer it to every other container on the Kamal bridge.

:::caution[A dev boot runs the development cron schedule]
`config/environments/development.rb` sets `config.good_job.enable_cron = true`, and
GoodJob runs `:async` in-process — so booting the app on a live host starts every job
`CronSchedule.for(:development)` resolves to (see
[Background jobs](/operate/background-jobs/#what-runs-where)) against a database that is
*empty*, on a filesystem that is not.

"Empty database, nothing to act on" is the wrong intuition for the set-difference
sweeps. `OrphanCloneFilesystemCleanupJob` defines an orphan as a directory under
`~/.zimmer/clones` with no owning `Session` row, and `StaleCloneCleanupJob` — which *is*
on the development schedule — does the same for the four per-session roots beside it
(scratch, the Claude config dir, the two prompt-attachment trees). An empty database
makes *every* one of those look orphaned. They are safe here only because of a specific
fence — `SWEEPS_DEFAULT_DURABLE_ROOT = %w[production staging]` and
`inside_default_durable_root?` make them refuse to sweep the default root when
`Rails.env` is development. That fence, not the empty database, is what protects other
sessions' clones and scratch. A new cron job that sweeps the filesystem needs its own.
:::

## Taking screenshots

Playwright's browsers are in the image. Drive the running server directly with
`PLAYWRIGHT_BROWSERS_PATH=/opt/playwright`:

```js
const { chromium } = require('/usr/lib/node_modules/playwright-stealth-mcp-server/node_modules/playwright-core');
const b = await chromium.launch();
const p = await b.newPage({ viewport: { width: 1280, height: 900 } });
await p.goto(`http://localhost:${PORT}/`, { waitUntil: 'networkidle' });
await p.screenshot({ path: '/tmp/shot.png' });
await b.close();
```

The `test/e2e/` scripts are plain Node scripts against `BASE_URL` and are not run by CI.
