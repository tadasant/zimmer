# Zimmer

**Zimmer is a self-hostable orchestrator for AI coding agents.** It gives you a web
UI and background workers to spawn, monitor, and manage long-running coding-agent
sessions (Claude Code and OpenAI Codex today), stream their transcripts in real
time, and drive everything through a REST API.

It is a Rails 8 application (Ruby 3.4, PostgreSQL, Redis, GoodJob, Hotwire, Tailwind),
packaged as a Docker image and deployable to a single DigitalOcean droplet behind a
Tailscale VPN with one manually-triggered workflow.

> **Status:** early but real — the full test suite is green in CI and the app is
> verified end-to-end (dev, container image, and a live Tailscale-gated staging box).
> Expect rough edges; see [Known limitations](#known-limitations).

---

## Table of contents

- [Features](#features)
- [Quick start (development)](#quick-start-development)
- [Running with Docker](#running-with-docker)
- [Deploying](#deploying)
- [Configuration (environment variables)](#configuration-environment-variables)
- [Integrations](#integrations)
- [Architecture](#architecture)
- [Image versioning & retention](#image-versioning--retention)
- [Extensions](#extensions)
- [Documentation index](#documentation-index)
- [Documentation](#documentation)
- [Development & contributing](#development--contributing)
- [Known limitations](#known-limitations)
- [License](#license)

---

## Features

- **Agent sessions** with a clear state machine (`waiting → running → needs_input →
  failed / archived`).
- **Multiple agent runtimes** — Claude Code and OpenAI Codex, behind a pluggable
  runtime registry.
- **Real-time transcript streaming** over Hotwire/Turbo, with vendor-neutral
  (OpenTranscripts) transcript storage.
- **REST API** (`/api/v1`) for programmatic session control, also rendered at `/api_docs`.
- **MCP server management** — configure Model Context Protocol servers per session,
  including OAuth-authenticated ones, with automatic token refresh.
- **MCP elicitation** support (interactive approval prompts from MCP servers).
- **AIR catalog** integration — agent roots, skills, plugins, MCP servers, hooks, and
  references resolved from a self-contained local catalog.
- **Removable extensions** for optional behavior kept out of the core image.
- **Background jobs** via GoodJob (session execution, cleanup, token rotation) with a
  dashboard at `/jobs`.
- **Observability** — structured error reporting to Sentry/GlitchTip and OTLP log
  export.

📖 **Full documentation: [zimmer.tadasant.com](https://zimmer.tadasant.com/)** — architecture, philosophy,
diagrams, the REST API reference, the AIR chapter, and a candid
[Known limitations](https://zimmer.tadasant.com/limitations/) page.

## Quick start (development)

Prerequisites: Ruby 3.4.6, PostgreSQL 14+, Redis, Node.js.

```bash
bundle install
cp .env.example .env          # then set ANTHROPIC_API_KEY
bin/rails db:setup
bin/dev                        # Rails + Tailwind watcher + GoodJob (async) — http://localhost:3000
```

Run on a random free port with `PORT=0 bin/dev`.

## Running with Docker

The production image is published to `ghcr.io/tadasant/zimmer`. It builds `FROM` a
base image (`ghcr.io/tadasant/zimmer-base`) that carries the heavy dependencies
(Node, Playwright, `gh` CLI, `uv`, Docker CLI). Build the base once via the **Build
base image** workflow, then every push to `main` publishes a versioned app image
(see [Image versioning](#image-versioning--retention)).

```bash
docker run -d -p 80:80 \
  -e SECRET_KEY_BASE=$(openssl rand -hex 64) \
  -e DATABASE_HOST=your-postgres -e DATABASE_USERNAME=zimmer -e DATABASE_PASSWORD=... \
  -e REDIS_URL=redis://your-redis:6379/0 \
  ghcr.io/tadasant/zimmer:latest
```

The container's entrypoint runs `db:prepare` on boot and serves on port 80 via
Thruster. The app reads discrete `DATABASE_HOST/PORT/USERNAME/PASSWORD` variables
(not a `DATABASE_URL`).

## Deploying

Zimmer is designed to run on a **single DigitalOcean droplet on a Tailscale VPN**, so
the UI is reachable only by you and your CI — there is no public app ingress (the
cloud firewall allows only SSH + the Tailscale UDP port). The infrastructure is fully
defined in Terraform under [`infra/terraform`](infra/terraform), and the deploy is a
manually-triggered (`workflow_dispatch`) GitHub Actions workflow that builds the
image, applies the IaC, joins the tailnet, and health-checks the app over the VPN.

- **Walkthrough:** [Deploying](https://zimmer.tadasant.com/operate/deploying/)
- **Secrets & one-time provisioning:** [Provisioning](https://zimmer.tadasant.com/operate/provisioning/)
- **IaC reference:** [infra/terraform/README.md](infra/terraform/README.md)

Required GitHub Actions secrets for the staging deploy: `DIGITALOCEAN_ACCESS_TOKEN`,
`TAILSCALE_AUTH_KEY` (a reusable, tagged tailnet key for the droplet), `TS_CI_AUTHKEY`
(a `tag:ci` key for the runner), `GHCR_PULL_TOKEN` (while the image package is
private), and `STAGING_SECRET_BASE`.

## Configuration (environment variables)

Everything is configured through environment variables — no secrets in git.

### Core

| Variable | Purpose |
|---|---|
| `ANTHROPIC_API_KEY` | Claude API key (development). |
| `SECRET_KEY_BASE` | Rails secret (required in production). |
| `RAILS_ENV` | `development` / `production`. |
| `PORT` | HTTP port (`0` = random free port). |
| `WEB_CONCURRENCY` | Number of Puma workers. |
| `RAILS_LOG_LEVEL` | `debug` … `fatal`. |
| `AIR_CONFIG` | Path to the AIR catalog `air.json` (defaults to the in-image catalog). |

### Database & Redis

| Variable | Default | Purpose |
|---|---|---|
| `DATABASE_HOST` | `localhost` | Postgres host. |
| `DATABASE_PORT` | `5432` | Postgres port. |
| `DATABASE_USERNAME` | `$USER` | Postgres user. |
| `DATABASE_PASSWORD` | — | Postgres password. |
| `REDIS_URL` | `redis://localhost:6379` | Redis connection. |
| `REDIS_POOL_SIZE` | — | Redis connection pool size. |

### Background jobs (GoodJob)

`GOOD_JOB_EXECUTION_MODE`, `GOOD_JOB_MAX_THREADS`, `GOOD_JOB_DEFAULT_THREADS`,
`GOOD_JOB_AGENTS_THREADS`, `GOOD_JOB_POLLERS_THREADS`, `RAILS_MAX_THREADS`.

### Process management

`PROCESS_KILL_TIMEOUT`, `PROCESS_TERM_TIMEOUT`, `PROCESS_POLL_INTERVAL`,
`PROCESS_ENABLE_METRICS`, `PROCESS_LOG_OPERATIONS`, `PROCESS_REGISTRY_CLEANUP_AGE`,
`EXECUTION_REPOS_DIR`, `AGENT_SCRATCH_DIR` (durable per-session scratch base).

### Observability (all optional — no-ops when unset)

| Variable | Purpose |
|---|---|
| `SENTRY_DSN_BACKEND` | DSN for backend error tracking (Sentry / self-hosted GlitchTip). |
| `OTEL_LOGS_EXPORTER_ENDPOINT` | OTLP/HTTP endpoint for shipping WARN/ERROR/FATAL logs. |
| `OTEL_LOGS_EXPORTER_BEARER_TOKEN` | Bearer token for the OTLP endpoint (both must be set to enable). |
| `OTEL_SERVICE_NAME` | `service.name` resource attribute (default `zimmer`). |

## Integrations

- **MCP (Model Context Protocol) servers** — attach tools to agent sessions,
  including OAuth-authenticated servers with automatic token refresh/rotation.
  [MCP servers](https://zimmer.tadasant.com/air/mcp-servers/) · [MCP server OAuth](https://zimmer.tadasant.com/auth/mcp-oauth/)
- **Claude Code & Codex auth** — OAuth tokens + account rotation per runtime.
  [Agent harness credentials](https://zimmer.tadasant.com/auth/harness/)
- **OpenTelemetry logs** — WARN/ERROR/FATAL `Rails.logger` lines and terminal job
  failures are shipped over OTLP/HTTP (e.g. to VictoriaLogs/Grafana) with
  `service.name` + `deployment.environment` resource attributes, so you can alert on
  errors. Enabled only when both `OTEL_LOGS_EXPORTER_*` vars are set.
- **Sentry / GlitchTip** — web-request, background-job, and swallowed-lifecycle
  exceptions are reported via `ErrorReporter` when `SENTRY_DSN_BACKEND` is set.
- **Tailscale** — the deployment model; the app is reachable only over your tailnet.
- **DigitalOcean** — the reference host, fully defined in Terraform.

## Architecture

- **Rails 8** app: controllers (`app/controllers`), background jobs (`app/jobs`,
  chiefly `AgentSessionJob`), models (`Session`, `Log`, …), and service objects
  (`app/services`).
- **Pluggable runtimes** — a `RuntimeRegistry` maps a session's `agent_runtime` to a
  bundle of role classes (CLI adapter, transcript source/normalizer, MCP status
  detector, auth provider, …). See [Adding an agent harness](https://zimmer.tadasant.com/extend/agent-harness/).
- **Extensions** — self-contained, individually-deletable bundles of optional behavior
  that plug into core seams without core naming them. See [Extensions](https://zimmer.tadasant.com/extend/extensions/).
- **AIR catalog** — agent roots / skills / plugins / MCP servers / hooks / references
  resolved via the public `@pulsemcp/air` CLI from `air.json` and the top-level
  artifact indexes (`skills/skills.json`, `roots.json`, `mcp.json`,
  `plugins/plugins.json`, `hooks/hooks.json`, `references/references.json`), fully
  offline by default. Skills in `skills/` are Zimmer-specific and are injected
  automatically into sessions on the `zimmer` root via `default_in_roots`.
- **Isolated execution** — each session runs in its own git clone with a durable
  per-session scratch directory.

## Image versioning & retention

`VERSION` holds a floor semver (e.g. `0.1.0`). On every push to `main` the **Release
image** workflow publishes `ghcr.io/tadasant/zimmer:MAJOR.MINOR.PATCH` where the patch
auto-increments per commit; cut a minor/major bump by editing `VERSION` in a PR. A
scheduled retention workflow prunes GHCR to ≤50 versions with a tiered policy (latest
per major → latest per minor → latest 20 patches in the lead minor → mod-10 cadence
for the rest), whose selection logic is unit-tested in
[`scripts/ghcr_retention.rb`](scripts/ghcr_retention.rb).

## Extensions

Extensions live in `app/extensions/<id>/` but are **not** baked into the core image.
The registry auto-skips a missing extension directory and falls back to native
behavior, so operators opt in per extension:

```bash
scripts/install-extension.sh --list
scripts/install-extension.sh mcp_tool_search --container zimmer
```

See [Extensions](https://zimmer.tadasant.com/extend/extensions/) for the contract, the install script, and how
to write one.

## Documentation

The full documentation site lives in [`docs/`](docs) (Astro Starlight) and is published at
**[zimmer.tadasant.com](https://zimmer.tadasant.com/)**.

- **Start here** — [What Zimmer is](https://zimmer.tadasant.com/intro/what-zimmer-is/) ·
  [Philosophy](https://zimmer.tadasant.com/intro/philosophy/) · [Architecture](https://zimmer.tadasant.com/intro/architecture/)
- **Using it** — [Run it locally](https://zimmer.tadasant.com/start/local/) ·
  [Your first session](https://zimmer.tadasant.com/start/first-session/) ·
  [Configuration](https://zimmer.tadasant.com/start/configuration/)
- **Sessions** — [Lifecycle](https://zimmer.tadasant.com/sessions/lifecycle/) ·
  [Goals](https://zimmer.tadasant.com/sessions/goals/) · [Triggers](https://zimmer.tadasant.com/sessions/triggers/) ·
  [Transcripts](https://zimmer.tadasant.com/sessions/transcripts/) · [Elicitation](https://zimmer.tadasant.com/sessions/elicitation/)
- **AIR** — [The mental model](https://zimmer.tadasant.com/air/overview/) ·
  [How Zimmer consumes it](https://zimmer.tadasant.com/air/zimmer-integration/) ·
  [Agent roots](https://zimmer.tadasant.com/air/agent-roots/)
- **Extending** — [REST API](https://zimmer.tadasant.com/extend/rest-api/) ·
  [Adding an agent harness](https://zimmer.tadasant.com/extend/agent-harness/) ·
  [Extensions](https://zimmer.tadasant.com/extend/extensions/)
- **Operating** — [Deploying](https://zimmer.tadasant.com/operate/deploying/) ·
  [Provisioning](https://zimmer.tadasant.com/operate/provisioning/) ·
  [Background jobs](https://zimmer.tadasant.com/operate/background-jobs/) ·
  [Testing](https://zimmer.tadasant.com/operate/testing/)
- **⚠️ [Known limitations](https://zimmer.tadasant.com/limitations/)** — the bugs, the brittleness, and the
  open questions. Read this one.

**Contributing:** [CONTRIBUTING.md](CONTRIBUTING.md) · agent instructions in
[AGENTS.md](AGENTS.md) / [CLAUDE.md](CLAUDE.md).

Docs are updated in the same PR as the behavior change — see the table in
[AGENTS.md](AGENTS.md#documentation-lives-in-docs--update-it-in-the-same-pr).

## Development & contributing

```bash
bundle exec rubocop         # lint
bin/brakeman -q             # security scan
bin/rails test              # unit + integration (system tests excluded)
```

CI runs lint, Brakeman, a lockfile check, the retention-logic unit tests, the docs-site
build, and the full test suite on every PR. Please read [CONTRIBUTING.md](CONTRIBUTING.md)
and [Testing philosophy](https://zimmer.tadasant.com/operate/testing/) first.

## Known limitations

- **Staging tfstate is ephemeral.** The deploy reaps prior resources before each apply
  so re-runs are idempotent, but for principled reconcile-based updates configure a
  remote Terraform backend (DO Spaces) — see [Provisioning](https://zimmer.tadasant.com/operate/provisioning/).
- **Single-node.** Zimmer targets one droplet; there is no built-in HA/clustering.
- **Branch protection** on a private free-plan GitHub repo requires GitHub Pro (the
  `main` ruleset is provided at `.github/rulesets/main.json`).

## License

MIT — see [LICENSE](LICENSE).
