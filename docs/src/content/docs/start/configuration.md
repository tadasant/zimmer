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
| `API_KEYS` | REST API and MCP auth. Each entry gets a named row the first time it is used; revoke one, or mint more, on `/settings/api_keys` | ✅ (Kamal) |
| `SUPERVISOR_PASSWORD` | The HTTP Basic realm in front of `/supervisor`, the API keys page (`/settings/api_keys`), **and the mutating `POST /health/*` maintenance actions**. **Fails closed** — unset or blank means every Administrate dashboard, the API keys page, *and* the health page's Clean Up / Retry / Trash / Halt queues / Re-arm buttons return 401, including for you. The read-only health dashboard, `/up`, and `POST /health/exit_queue_recovery_mode` stay open regardless, and every gated action has a `POST /api/v1/health/*` sibling behind `API_KEYS`. Optional `SUPERVISOR_USERNAME` defaults to `supervisor` | ❌ — seed it into your deploy secrets, then add it to `env.secret` in `config/deploy.*.yml` |
| `APP_HOST` | MCP OAuth redirect URI, and the mailer link host | ✅ (Kamal) |
| `ZIMMER_PROD_BASE_URL` / `ZIMMER_STAGING_BASE_URL` | Externally-reachable base URL of this instance (e.g. `https://zimmer.your-domain.com`). `AppUrl` resolves it to build every absolute link Zimmer emits — session URLs in the orchestrator system prompt, "View trigger in Zimmer" alert links, MCP tool output. **Set this**: when unset it falls back to a non-functional `zimmer.example.com` placeholder and generated links break. The shipped deploy sets it in `config/deploy.{production,staging}.yml`; a self-hosted instance must set it to its own host | ✅ (Kamal) |
| `RAILS_MASTER_KEY` | Rails credentials | ✅ in a self-hosted production config; on staging it is [optional, and degrades silently when absent](/limitations/#rails_master_key-is-optional-on-staging-and-silently-degrades-when-absent) |
| `SLACK_BOT_TOKEN` | Slack triggers and the channel picker | via `mcp_secrets` (encrypted credentials); ENV is the fallback |
| `ENG_ALERTS_SLACK_CHANNEL_ID` | the operational alert channel. Zimmer does not post there — [the obs pipeline does](/operate/background-jobs/#alerts), through its own webhook — it reads this id only to recognize the channel and keep [passive listening](/sessions/triggers/) from treating a page as a conversation | via `mcp_secrets`; ENV is the fallback |
| `SLACK_BOT_MENTION_ALLOWED_USER_IDS` | comma-separated Slack user IDs allowed to fire `bot_mention`, `dm_message` and passive-listening triggers. **Blank or unset means everyone** — see [the caveat](/limitations/#anyone-in-the-workspace-can-trigger-an-agent-via-bot-mention-by-default) | via `mcp_secrets`; ENV is the fallback |
| `ZIMMER_GIT_USER_NAME` / `ZIMMER_GIT_USER_EMAIL` | the `user.name` / `user.email` every agent session commits with, written into the container's `~/.gitconfig` at boot. **Set both or neither** — Zimmer will not invent the missing half, and without them a session's first `git commit` fails with `Author identity unknown` ([why there is no default](/limitations/#a-deployment-that-configures-no-git-identity-still-cannot-commit)). Every commit a session makes is authored as this identity, so pick one you are content to see in `git log`. See [the git identity an agent session commits with](/operate/provisioning/#the-git-identity-an-agent-session-commits-with) | not set; sessions cannot commit until it is |
| `ZIMMER_ADMIN_USER` | the `users.key` of the human responsible for web UI actions, since Zimmer has no login. Unset falls back to `tadasant`; a value naming no row means web-UI [human messages](/sessions/hierarchy-and-human-messages/#who-is-the-admin) record nothing rather than guessing an author | not set; the default is the seeded admin |

The env, secrets, and data-store wiring all live in `config/deploy.*.yml` and `.kamal/secrets.*`,
not in Terraform — Terraform only provisions the host.

### Agent + tooling

| Var | Purpose |
| --- | --- |
| `ANTHROPIC_API_KEY` | Claude Code, when not using OAuth |
| `ANTHROPIC_BASE_URL` | Test-only; triggers reading the OAuth token off disk and passing it as an API key |
| `CODEX_HOME` | Codex config dir. Default `~/.codex` |
| `PI_CODING_AGENT_DIR` | Pi config dir (`auth.json`, `models.json`, `settings.json`). Default `~/.pi/agent`, and set explicitly in `Dockerfile.base` so every container agrees. `PiRuntimeAdapter` exports it to the spawned process |
| `PI_EXTENSIONS_DIR` | Where the [Pi extensions](/sessions/runtimes/#pi-brings-no-mcp-hooks-or-plugins-of-its-own) are installed. Default `/opt/pi-extensions`; CI runners that cannot write there redirect it |
| `OPENROUTER_API_KEY` | Pi's provider credential. Normally set through the Inference page's Pi tab rather than here — see [Runtimes](/sessions/runtimes/#credentials) |
| `CLAUDE_CONFIG_DIR` | Login isolation only (a scratch dir during the login flow) |
| `AIR_CONFIG` | Which `air.json` to resolve. Always wins over the per-environment default. |
| `AIR_CATALOG_REF` | Staging-only catalog pinning: rewrites every `github://tadasant/zimmer-catalog/…` URI in the **in-image** `air.production.json` to pin that ref. It is read inside the `AIR_CONFIG` fallback, so setting `AIR_CONFIG` bypasses it entirely — and `air.production.json` declares no `github://` URIs, so as shipped it pins nothing on any deployment and staging warns at boot and resolves the catalog unrewritten. See [Catalog pinning is real code for a catalog this deployment does not run](/limitations/#catalog-pinning-is-real-code-for-a-catalog-this-deployment-does-not-run) |
| `ELICITATION_EXPIRATION_MINUTES` | How long a new [elicitation](/sessions/elicitation/#expiry) (an MCP server's approval request) stays answerable, in minutes. Default 60. An MCP server that sends its own `_meta["com.pulsemcp/expires-at"]` keeps it; this sets the default for everything else. Blank is treated as unset; a non-numeric or zero/negative value is logged and ignored; anything above the 7-day ceiling is clamped |
| `X_OAUTH_REDIRECT_URI` | Where X sends the operator after the consent that `/supervisor` starts, on both the consent request and the token exchange. Default `http://localhost:8080/callback`, where nothing listens, so the operator pastes the redirect URL back. Set it to `https://<APP_HOST>/supervisor/x_oauth/callback` and the flow finishes on its own. Whatever you set must already be registered on the X app — that registration is a manual step on X's developer portal. See [X (Twitter) is minted from `/supervisor`](/auth/mcp-oauth/#x-twitter-is-minted-from-supervisor) |
| `ZIMMER_CONTENT_SEARCH_BUDGET_SECONDS` | Wall-clock ceiling for one transcript content search (`search_contents`), in seconds. Default 20, chosen to sit under kamal-proxy's 30-second target timeout — raising it past that trades a structured "scan incomplete" answer for a 504. Zero means "stop before the first chunk"; a negative value is ignored. See [Searching transcript contents](/extend/rest-api/#searching-transcript-contents) |
| `ZIMMER_CONTENT_SEARCH_CHUNK_SIZE` | How many sessions one content-search statement reads at a time. Default 100. Smaller chunks make the budget finer-grained at the cost of more round trips |

### Paths

| Var | Default |
| --- | --- |
| `AGENT_CLONES_DIR` | `~/.zimmer/clones` |
| `AGENT_TRANSCRIPT_ARCHIVE_DIR` | `~/.zimmer/transcript_archives` — where `TranscriptArchiveJob` writes `latest.zip`. A sibling of the clones dir, and on the same `zimmer_data` volume, because the job runs in the `worker` container and every reader of the archive is an HTTP route in `web`. Point it somewhere both roles mount, or the reader stops seeing the writer |
| `AGENT_SCRATCH_DIR` | per-session durable scratch |
| `REPO_BASE_PATH` | `tmp/repos` (bare repos) |

### Concurrency and logging

`WEB_CONCURRENCY`, `RAILS_MAX_THREADS`, `REDIS_POOL_SIZE`, `RAILS_LOG_LEVEL`, `PIDFILE`, `PROCESS_*`.

Worker concurrency is per queue: `GOOD_JOB_AGENTS_THREADS`, `GOOD_JOB_POLLERS_THREADS`,
`GOOD_JOB_MAINTENANCE_THREADS`, `GOOD_JOB_TRIGGERS_THREADS`, `GOOD_JOB_AUTH_THREADS`,
`GOOD_JOB_INFERENCE_THREADS`, `GOOD_JOB_DEFAULT_THREADS`. Each of those threads can hold a database
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

- **Default runtime** (`claude_code` | `codex` | `pi`) and default model. See
  [Runtimes](/sessions/runtimes/).
- **Extension toggles** — the `extension_states` JSONB map. See [Extensions](/extend/extensions/).
- Catalog refresh controls.

:::caution[The MCP `start_session` tool skips the global default when you name no agent root]
The REST API honors the whole chain: `Api::V1::SessionsController#resolve_agent_root_defaults!`
runs whether or not `agent_root` was given, so a rootless `POST /api/v1/sessions` picks up both
values set here (pinned by `sessions_controller_contract_test.rb`, "create without agent_root
honors the global default runtime and model").

The MCP `start_session` tool does not. It reaches `apply_agent_root_defaults!` only
`if agent_root_name`, so a rootless MCP spawn falls through to the database column default —
`claude_code`. Set the global default to `codex` or `pi`, start a session over MCP with no
`agent_root`, and you get Claude Code.
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
| Elicitation expiry ceiling (`ELICITATION_EXPIRATION_MINUTES`) | 7 days |
| `needs_input` push debounce | 60 seconds |
| Trash retention (dirty clones) | 4 days |
| Large-prompt stream-json threshold | 100 KB |
