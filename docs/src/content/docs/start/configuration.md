---
title: Configuration reference
description: Every config file and environment variable, what reads it, and which ones the shipped deploy forgets to set.
sidebar:
  order: 3
---

## The config files

| File | What it is | Read by |
| --- | --- | --- |
| `air.json` | The AIR catalog wiring (dev/test) | `AirCatalogService` via the AIR CLI |
| `air.production.json` | Same, for the in-image catalog (prod/staging) | ditto |
| `roots.json` | Agent root definitions | `AgentRootsConfig` |
| `mcp.json` | MCP server registry | `ServersConfig` |
| `skills/skills.json` | Skill index | `SkillsConfig` |
| `plugins/plugins.json` | Plugin index | `PluginsConfig` |
| `hooks/hooks.json` | Hook index | `HooksConfig` |
| `references/references.json` | Reference index | `ReferencesConfig` |
| `config/goals.json` | Goal / stop-condition catalog | `GoalsConfig` |

:::caution[Never parse the AIR indexes directly]
The six artifact indexes are AIR's input; the resolved tree is Zimmer's data model. The resolved tree differs from
the raw index: references are canonicalized, `default_in_roots` is inverted into per-root defaults
*and then deleted*, and paths are absolutized.

Everything in Zimmer reads them through `AirCatalogService`. Code that reads `roots.json` with
`JSON.parse` is code that will be subtly wrong.
:::

`config/goals.json` is the exception — it's a plain static file that `GoalsConfig` reads directly, outside AIR.

## Environment variables

### Required in production

| Var | Purpose | Set by the shipped deploy? |
| --- | --- | --- |
| `SECRET_KEY_BASE` | Rails secret | ✅ (Kamal) |
| `DATABASE_HOST` / `_PORT` / `_USERNAME` / `_PASSWORD` / `_SSLMODE` | Postgres | ✅ (Kamal) |
| `REDIS_URL` | Cache | ✅ (Kamal) |
| `API_KEYS` | REST API auth | ✅ (Kamal) |
| `APP_HOST` | MCP OAuth redirect URI, and the mailer link host | ✅ (Kamal) |
| `ZIMMER_PROD_BASE_URL` / `ZIMMER_STAGING_BASE_URL` | Externally-reachable base URL of this instance (e.g. `https://zimmer.your-domain.com`). `AppUrl` resolves it to build every absolute link Zimmer emits — session URLs in the orchestrator system prompt, "View trigger in Zimmer" alert links, MCP tool output. **Set this**: when unset it falls back to a non-functional `zimmer.example.com` placeholder and generated links break. The shipped deploy sets it in `config/deploy.{production,staging}.yml`; a self-hosted instance must set it to its own host | ✅ (Kamal) |
| `RAILS_MASTER_KEY` | Rails credentials | ✅ in a self-hosted production config; on staging it is [optional, and degrades silently when absent](/limitations/#rails_master_key-is-optional-on-staging-and-silently-degrades-when-absent) |
| `SLACK_BOT_TOKEN` | Slack triggers, the channel picker, and `AlertService` | via `mcp_secrets` (encrypted credentials); ENV is the fallback |
| `ENG_ALERTS_SLACK_CHANNEL_ID` | the channel `AlertService` posts to | via `mcp_secrets`; ENV is the fallback |
| `SLACK_BOT_MENTION_ALLOWED_USER_IDS` | comma-separated Slack user IDs allowed to fire `bot_mention` triggers. **Blank or unset means everyone** — see [the caveat](/limitations/#anyone-in-the-workspace-can-trigger-an-agent-via-bot-mention-by-default) | via `mcp_secrets`; ENV is the fallback |

The env, secrets, and data-store wiring all live in `config/deploy.*.yml` and `.kamal/secrets.*`,
not in Terraform — Terraform only provisions the host.

### Agent + tooling

| Var | Purpose |
| --- | --- |
| `ANTHROPIC_API_KEY` | Claude Code, when not using OAuth |
| `ANTHROPIC_BASE_URL` | Test-only; triggers reading the OAuth token off disk and passing it as an API key |
| `CODEX_HOME` | Codex config dir. Default `~/.codex` |
| `CLAUDE_CONFIG_DIR` | Login isolation only (a scratch dir during the login flow) |
| `AIR_CONFIG` | Which `air.json` to resolve. Always wins over the per-environment default. |
| `AIR_CATALOG_REF` | Staging-only catalog pinning |

### Paths

| Var | Default |
| --- | --- |
| `AGENT_CLONES_DIR` | `~/.zimmer/clones` |
| `AGENT_SCRATCH_DIR` | per-session durable scratch |
| `REPO_BASE_PATH` | `tmp/repos` (bare repos) |
| `EXECUTION_REPOS_DIR` | — |

### Concurrency and logging

`WEB_CONCURRENCY`, `RAILS_MAX_THREADS`, `REDIS_POOL_SIZE`, `RAILS_LOG_LEVEL`, `PIDFILE`, `PROCESS_*`.

Worker concurrency is per queue: `GOOD_JOB_AGENTS_THREADS`, `GOOD_JOB_POLLERS_THREADS`,
`GOOD_JOB_TRIGGERS_THREADS`, `GOOD_JOB_DEFAULT_THREADS`. Each of those threads can hold a database
connection for the whole life of a job, so they size the ActiveRecord pool too — raising one raises
the number of connections the database must be able to serve. `DB_POOL` and `CABLE_DB_POOL` override
the derived pools directly, but read [the connection
budget](/operate/deploying/#the-database-connection-budget) before you do.

### Observability

`SENTRY_DSN_BACKEND`, `OTEL_SERVICE_NAME`, `OTEL_LOGS_EXPORTER_ENDPOINT`,
`OTEL_LOGS_EXPORTER_BEARER_TOKEN`.

### MCP server secrets

Consumed as `${VAR}` placeholders in `mcp.json`, resolved by `SecretsLoader` at prepare time:
`FLY_IO_API_TOKEN`, `OP_SERVICE_ACCOUNT_TOKEN`, `GITHUB_API_TOKEN`, …

`SecretsLoader` resolves in this order: `XOauthTokenVendor` → Rails credentials (`mcp_secrets`) →
`ENV`.

## Settings you change in the UI

`/settings` writes to a single `AppSetting` row:

- **Default runtime** (`claude_code` | `codex`) and default model.
- **Extension toggles** — the `extension_states` JSONB map. See [Extensions](/extend/extensions/).
- Catalog refresh controls.

:::caution[The global default runtime is ignored by the API unless you pass an `agent_root`]
`Api::V1::SessionsController#create` only consults `AppSetting.default_runtime` through
`AgentRootsConfig`. With no `agent_root` param, it returns early and the runtime is the database
column default — `claude_code`.

Set the global default to `codex`, create a session via the API without an `agent_root`, and you get
Claude Code. The old `docs/REST_API.md` documented the intended chain; the behavior above is the actual one.
:::

## Hard-coded limits

| Limit | Value |
| --- | --- |
| Prompt max length | 500,000 chars |
| Session notes max | 50,000 chars |
| Search query max | 1,000 chars |
| MCP servers per session | 50 |
| Skills / hooks per session | 100 each |
| Plugins per session | 50 |
| API pagination | default 25, max 100 |
| MCP server startup timeout | 180,000 ms (3 min) |
| Elicitation expiry | 10 minutes |
| `needs_input` push debounce | 60 seconds |
| Trash retention (dirty clones) | 4 days |
| Large-prompt stream-json threshold | 100 KB |
