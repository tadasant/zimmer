---
title: Run it locally
description: Get Zimmer running on your machine — prerequisites, setup, and the env vars that actually matter.
sidebar:
  order: 1
---

## Prerequisites

- **Ruby 3.4.6** (see `.ruby-version`)
- **PostgreSQL 14+**
- **Redis**
- **Node.js** (for the AIR CLI and `npx`-based MCP servers)
- The **`claude`** and/or **`codex`** CLI, logged in
- **`gh`** CLI, logged in (agents use it to open PRs)

## Setup

```bash
bundle install
cp .env.example .env          # then set ANTHROPIC_API_KEY
bin/rails db:setup
bin/dev                       # → http://localhost:3000
```

`bin/setup` does the same thing plus `bundle check`, `db:prepare`, and `log:clear`, then execs
`bin/dev`. Use `PORT=0 bin/dev` for a random port.

`bin/dev` installs foreman if it's missing, warns (non-fatally) if `redis-cli ping` fails, kills any
stale foreman or port-3000 processes, and starts `Procfile.dev`:

```
web: bin/rails server
css: while true; do bin/rails tailwindcss:watch || sleep 5; done
```

:::note[There is no worker line in Procfile.dev — that's correct]
In development, GoodJob runs in `:async` mode in-process with Puma
(`config/environments/development.rb`). Jobs and cron work.

In production and staging, `execution_mode = :external` and a separate `bundle exec good_job start`
process is required — which the
[shipped Terraform does not provide](/limitations/#the-shipped-terraform-provisions-no-job-worker).
:::

## Two databases

`config/database.yml` and `config/cable.yml` expect two databases per environment:
`zimmer_development` and `zimmer_development_cable`. The second is Action Cable's, via
`solid_cable`. `bin/rails db:setup` creates both.

## Environment variables

Everything in `.env.example` is commented out except `RAILS_ENV=development`. The ones that matter:

| Var | What for |
| --- | --- |
| `DATABASE_HOST` / `_PORT` / `_USERNAME` / `_PASSWORD` | Postgres. Postgres.app users want `5450`. |
| `REDIS_URL` | Cache. `redis://localhost:6379` |
| `ANTHROPIC_API_KEY` | Claude Code, if not using OAuth |
| `API_KEYS` | Comma-separated keys for the REST API. Unset ⇒ the API 401s on everything. |
| `APP_HOST` | The MCP OAuth redirect host. Unset ⇒ defaults to `localhost:3000`. |
| `RAILS_MASTER_KEY` | Unlocks Rails credentials (`mcp_secrets`, `mcp_oauth_clients`) |
| `AIR_CONFIG` | Override which `air.json` the catalog resolves from |
| `AGENT_CLONES_DIR` | Where session clones go. Default `~/.agent-orchestrator/clones` |
| `GOOD_JOB_MAX_THREADS` | Worker concurrency |

`gh` and the agent CLIs authenticate via OAuth (`gh auth login`, `claude /login`), not env vars.

## First run: the catalog

On boot, `config/initializers/air_catalog.rb` runs `AirCatalogService.refresh!`, which lazily
`npm install`s the AIR CLI (pinned to `0.13.0`) into `AIR_INSTALL_DIR` and then shells out to
`air resolve`. The first boot is slow because of that install.

If the catalog fails to resolve, the app downgrades to a warning and serves a stale snapshot —
but the test suite is less forgiving. See below.

## Running tests

```bash
bin/rails test test/models/session_test.rb    # targeted — do this
bin/rails test                                # the whole suite
bin/rubocop                                   # lint
bin/brakeman                                  # security scan
```

Run targeted tests locally and let CI run the full suite.

:::caution[If the whole suite suddenly goes red, suspect the catalog]
`test/test_helper.rb` pre-warms the AIR catalog at boot, before `parallelize` forks its workers.
So a catalog that doesn't resolve doesn't fail one test — it fails every test that creates a
session, all at once, with `ActiveRecord::RecordInvalid`.

A wave of `RecordInvalid` across unrelated session tests almost always means a broken catalog, not a
broken model. Check `air resolve` before you debug your change.
:::

## System tests do not run in CI

`.github/workflows/ci.yml` runs "unit + integration; system tests excluded." The browser suite
never runs on a PR. Combined with the four open UI bugs (issues #12–#15), that's the obvious hole —
see [Testing philosophy](/operate/testing/).
