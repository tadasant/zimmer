---
name: zimmer-start-dev-server
title: Start the Zimmer Dev Server
description: >
  Bring up a local Zimmer instance (Rails 8 + Tailwind watcher via foreman) to
  develop against, exercise a change by hand, or take screenshots. Covers the
  Postgres + Redis prerequisites the app does NOT provision for you, the
  `bin/dev` vs `bin/setup` split, port handling, and the failure modes that look
  like a broken app but are really a missing service. Use before any change that
  needs to be verified in a running app rather than only in tests.
user-invocable: true
---

# Start the Zimmer Dev Server

Zimmer is a Rails 8 app (Ruby 3.4.6) on PostgreSQL + Redis, with Hotwire and a
Tailwind watcher. `bin/dev` runs it under foreman via `Procfile.dev`.

## Want the whole stack in Docker instead?

If you'd rather not provision Postgres and Redis yourself, there is a fully
containerized dev environment at `.agent-containers/` (app + Postgres + Redis via
`docker compose`, orchestrated by `.agent-containers/ac.sh`). It's the better
choice for running many isolated sessions in parallel. See
`.agent-containers/README.md`. The rest of this skill covers the host-process
`bin/dev` flow.

## Prerequisites the host-process flow does NOT set up for you

`bin/dev` runs on your host. Nothing in `bin/setup` or `bin/dev` will install or
start Postgres or Redis — you must have both running yourself. This is the single
most common reason the dev server "doesn't work". (The containerized environment
above provisions both for you.)

- **PostgreSQL 14+** on `localhost:5432`. `config/database.yml` reads discrete
  env vars, **not** `DATABASE_URL`: `DATABASE_HOST` (default `localhost`),
  `DATABASE_PORT` (default `5432`), `DATABASE_USERNAME` (default `$USER`),
  `DATABASE_PASSWORD`, `DATABASE_SSLMODE` (default `prefer`). Setting
  `DATABASE_URL` alone does nothing.
- **Redis.** `bin/dev` only *warns* if Redis is down — it does not fail. The app
  then boots and then misbehaves at runtime (Action Cable / GoodJob), which reads
  as an app bug. Start it first.

Quick container fallback if you have Docker but no local services:

```bash
docker run -d --name zimmer-pg -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres \
  -p 5432:5432 postgres:16
docker run -d --name zimmer-redis -p 6379:6379 redis:7
export DATABASE_USERNAME=postgres DATABASE_PASSWORD=postgres
```

## First run

```bash
bundle install
cp .env.example .env      # then set ANTHROPIC_API_KEY
bin/rails db:setup        # creates zimmer_development + zimmer_development_cable
bin/dev                   # http://localhost:3000
```

`bin/setup` is the one-shot version: it runs `bundle check || bundle install`,
`bin/rails db:prepare`, `bin/rails log:clear tmp:clear`, then execs `bin/dev`.
Pass `bin/setup --skip-server` to prepare without booting.

## Running it

```bash
bin/dev                   # foreman -f Procfile.dev, port 3000
PORT=4000 bin/dev         # explicit port
PORT=0 bin/dev            # random free port (useful when 3000 is taken)
```

`Procfile.dev` starts exactly two processes:

- `web: bin/rails server`
- `css: bin/rails tailwindcss:watch` (in a restart loop)

There is **no worker process in development** — GoodJob runs in `:async` mode
inside the Rails process. Do not go looking for a missing `worker:` line; jobs
run in-process. (Production/staging use `bundle exec good_job start`.)

`bin/dev` is not gentle about ports: it `pkill`s any existing
`foreman ... Procfile.dev` and kills whatever process holds `$PORT`
(`lsof -ti:$PORT | xargs kill -9`) before starting. That's intentional — but it
means a stray `bin/dev` in another terminal will be killed out from under you.

## Confirming it is actually up

Don't trust "server started" in the log. Hit the health endpoint and a real page:

```bash
curl -sf http://localhost:3000/up && echo "UP"
curl -sI http://localhost:3000/sessions | head -1
```

`/up` is the Rails health check — it proves the process is listening and the DB
connection works. It does **not** prove Redis, Tailwind, or Action Cable are
healthy. If the UI loads but live updates never arrive, suspect Redis/Action
Cable, not the view.

## Failure modes, in the order you'll hit them

| Symptom | Cause | Fix |
| --- | --- | --- |
| `ActiveRecord::ConnectionNotEstablished ... port 5432 failed: Connection refused` | Postgres not running | Start Postgres |
| `PG::ConnectionBad: FATAL: role "..." does not exist` | `DATABASE_USERNAME` defaults to `$USER` | Set `DATABASE_USERNAME`/`DATABASE_PASSWORD` in `.env` |
| `ActiveRecord::NoDatabaseError` | DB never created | `bin/rails db:setup` (or `db:prepare`) |
| Page loads, live updates never arrive | Redis down — `bin/dev` only warned | Start Redis, restart `bin/dev` |
| Styles missing / stale | Tailwind watcher died | Check the `css:` process in the foreman output |
| Port already in use | Another server outside foreman's reach | `PORT=0 bin/dev` |

## Taking screenshots / driving the UI

The Playwright e2e scripts under `test/e2e/` are plain Node scripts (no test
runner, no npm script) and drive a running dev server:

```bash
BASE_URL=http://localhost:3000 node test/e2e/chat_bubble_test.js
```

They are **not** run by CI. Available: `account_rotation_test.js`,
`chat_bubble_test.js`, `joystick_menu_test.js`, `skills_catalog_test.js`. For
screenshots to embed in a PR, drive the running server with Playwright and upload
via a remote-filesystem MCP server if one is available.

## Related

- `skills/zimmer-run-tests` — the test tiers, and what CI actually runs.
- `skills/zimmer-deploy-staging` — exercising a branch on a real deployed box.
