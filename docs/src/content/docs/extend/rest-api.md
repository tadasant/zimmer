---
title: The REST API
description: Every endpoint, re-derived from routes.rb and the controllers — including the six resources the old reference omitted.
sidebar:
  order: 1
---

Base URL `/api/v1`. Authentication is the `X-API-Key` header, compared against
`ENV["API_KEYS"]` (comma-separated) with a constant-time comparison.

:::caution[API keys have no scope, no identity, and no audit trail]
A key is an opaque string. Any valid key can do anything to any session, trigger, or category. Keys are
memoized per request from ENV, so rotation requires a restart. There is no record of which key did what.
:::

## Sessions

`:id` resolves slug first, then numeric id.

| Method | Path | Notes |
| --- | --- | --- |
| `GET` | `/sessions` | filters: `status`, `agent_runtime`, `show_archived`, `page`, `per_page` |
| `GET` | `/sessions/search` | `q` required (≤1000 chars), `search_contents=true`. Missing/oversized `q` → 400 (the only 400 in the API) |
| `GET` | `/sessions/:id` | `include_transcript=true` adds the raw transcript |
| `POST` | `/sessions` | → 201. See below. |
| `PATCH` | `/sessions/:id` | permits only `title`, `slug`, `goal`, `is_autonomous`, `custom_metadata` |
| `DELETE` | `/sessions/:id` | → 204 |
| `POST` | `/sessions/:id/archive` | → `{session, message, trash_after}` |
| `POST` | `/sessions/:id/unarchive` | → `{session, clone_restored, message}` |
| `POST` | `/sessions/:id/follow_up` | `prompt` (≤500,000), `goal`, `force_immediate`. 202 if the session is running (queued); 200 otherwise |
| `POST` | `/sessions/:id/pause` | running only |
| `POST` | `/sessions/:id/sleep` | `needs_input` → sleeps; `running` → sets `pending_sleep` |
| `POST` | `/sessions/:id/restart` | |
| `POST` | `/sessions/:id/fork` | `message_index` required → 201 |
| `POST` | `/sessions/:id/refresh` | re-read transcript from disk |
| `POST` | `/sessions/refresh_all` | max 50 sessions |
| `POST` | `/sessions/bulk_archive` | `session_ids[]` |
| `PATCH` | `/sessions/:id/mcp_servers` | max 50, validated against the catalog |
| `PATCH` | `/sessions/:id/catalog_skills` · `/catalog_hooks` · `/catalog_plugins` | max 100 / 100 / 50 |
| `PATCH` | `/sessions/:id/model` | validated against `ModelCatalog` for the session's runtime |
| `PATCH` | `/sessions/:id/notes` | `session_notes` ≤ 50,000 |
| `PATCH` | `/sessions/:id/heartbeat` | `enabled` and/or `interval_seconds` (30–86,400) |
| `PATCH` | `/sessions/:id/set_category` | blank clears |
| `POST` | `/sessions/:id/toggle_favorite` | |
| `GET` | `/sessions/:id/transcript` | `format=text` → `text/plain` |

### Creating a session

Permitted params: `agent_runtime`, `prompt`, `git_root`, `branch`, `subdirectory`, `title`, `slug`,
`goal`, `execution_provider`, `is_autonomous`, `parent_session_id`, `auto_compact_window`,
`mcp_servers[]`, `catalog_skills[]`, `catalog_hooks[]`, `catalog_plugins[]`, `config{}`,
`custom_metadata{}`.

One more: `agent_root`, which is read directly from `params`, *outside* the strong-params permit list.
An invalid one → `422 {"error": "Invalid agent_root"}`. Tracked in [#81](https://github.com/tadasant/zimmer/issues/81).

The `AgentSessionJob` is enqueued only if `prompt` is present.

:::caution[Without `agent_root`, the Settings-page defaults are silently ignored]
With no `agent_root`, `resolve_agent_root_defaults!` returns early: the runtime falls back to the DB
column default (`claude_code`) and the model goes straight to `ModelCatalog.default_for(runtime)`.
`AppSetting`'s global defaults are never consulted.
:::

### `session_json`

`id`, `slug`, `title`, `status`, `agent_runtime`, `prompt`, `git_root`, `branch`, `subdirectory`,
`execution_provider`, `goal`, `mcp_servers`, `all_mcp_servers`, `injected_mcp_servers`,
`catalog_skills`, `catalog_hooks`, `catalog_plugins`, `config`, `metadata`, `custom_metadata`,
`is_autonomous`, `heartbeat_enabled`, `heartbeat_interval_seconds`, `auto_compact_window`,
`category_id`, `category{}`, `session_id`, `job_id`, `running_job_id`, `archived_at`, `trash_after`,
`created_at`, `updated_at`, `session_notes`, `session_notes_updated_at`, `favorited`.

:::note[`session` doesn't always mean the same shape]
`POST /enqueued_messages/:id/interrupt` returns a six-field subset under the same `session` key.
The `session` key returns a different shape from each.
:::

## Triggers

`GET /triggers` (filters `condition_type`, `status`) · `GET /triggers/:id` (+ `recent_sessions`,
limit 10) · `POST` · `PATCH` · `DELETE` · `POST /triggers/:id/toggle` · `GET /triggers/channels`
(Slack; 503 when Slack is unconfigured).

Conditions are nested via `trigger_conditions_attributes`. The web UI's `triggers#invoke` route has
no API equivalent.

## Notifications

`GET /notifications` (`status=read|unread`) · `GET /notifications/:id` ·
`GET /notifications/badge` → `{pending_count}` · `PATCH /notifications/:id/mark_read` ·
`PATCH /notifications/mark_all_read` · `DELETE /notifications/:id/dismiss` (422 if unread) ·
`DELETE /notifications/dismiss_all_read` · `POST /notifications/push` (`session_id` + `message`).

## Health

`GET /health` → `{health_report, timestamp, rails_env, ruby_version}` ·
`POST /health/cleanup_processes` · `POST /health/retry_sessions` ·
`POST /health/archive_old` (`days`, clamped 1–365, default 7).

:::caution[The only rate limit in the API lives here — and it's global]
The three `POST`s share a `CLEANUP_COOLDOWN = 30.seconds`, keyed in `Rails.cache` as
`health_api_rate_limit:<action>`. That key is not scoped to an API key, so one client's cleanup
locks out every other client for 30 seconds. Exceeded → `429 {"error": "Rate limited", "retry_after": 30}`.

It also silently no-ops if `Rails.cache` is a null store.
:::

## Elicitations

- `POST /elicitations` — **UNAUTHENTICATED**. Requires `_meta["com.pulsemcp/request-id"]` and
  `message`. → 201.
- `GET /elicitations/:request_id` — **UNAUTHENTICATED**. Auto-expires past `expires_at`.
- `PATCH /elicitations/:request_id/respond` — authenticated. `action_type` ∈ `accept | decline`.

The first two skip auth because the MCP child process has no API key. See
[Elicitation](/sessions/elicitation/).

Note the parameter is `action_type`, not `action` — `action` is a Rails reserved param.

## The rest

| Resource | Endpoints |
| --- | --- |
| **Logs** | Full CRUD at `/sessions/:session_id/logs[/:id]`, `level` filter |
| **Subagent transcripts** | Full CRUD at `/sessions/:session_id/subagent_transcripts[/:id]` |
| **Enqueued messages** | CRUD + `PATCH :id/reorder` + `POST :id/interrupt` |
| **Categories** | CRUD + `POST /categories/reorder` |
| **CLIs** | `GET /clis/status` · `POST /clis/refresh` · `POST /clis/clear_cache` |
| **Transcript archive** | `GET /transcript_archive/download` (zip) · `/status` |
| **Config (read-only)** | `GET /configs` · `GET /mcp_servers` · `GET /skills` |

:::danger[`GET /api/secrets/keys` has no authentication]
`Api::SecretsController` inherits `ApplicationController`, not `Api::BaseController`, so it is
outside the API-key gate entirely. It returns `{secrets: [{name, description}]}` — secret *names and
descriptions*, not values.

Since [the web UI has no auth either](/auth/overview/#1-human--zimmer-there-is-no-authentication),
this is public to anyone who can reach the host.
:::

## Errors

Three shapes, inconsistently applied:

```jsonc
{"error": "Not Found", "message": "The requested resource was not found"}   // string
{"error": "Validation failed", "messages": ["Title can't be blank"]}        // plural key, array
{"error": "...", "message": ["..."]}                                        // singular key, ARRAY value
```

That third one comes from `Api::BaseController#unprocessable_entity` (the `RecordInvalid` rescue).
Parse defensively. Tracked in [#82](https://github.com/tadasant/zimmer/issues/82).

**Status codes in use:** 200 · 201 · 202 (follow-up queued) · 204 · 400 (search only) · 401 · 404 ·
409 (follow-up position collision, interrupt races) · 422 · 429 (health cooldown) · 500 · 503 (Slack
unconfigured).

:::note[Missing required params return 422]
`follow_up` without a prompt, `fork` without `message_index`, `bulk_archive` without `session_ids`,
`notifications/push` without a message — all **422**. The only 400 in the API is a missing or
oversized search `q`.
:::

## Keeping this page honest

`app/controllers/api/AGENTS.md` requires that both doc surfaces — this page and
`app/views/api_docs/show.html.erb` (the in-app `/api_docs` page) — be updated with every endpoint
change. Both had drifted. `app/views/api_docs/show.html.erb` is still missing triggers,
notifications, health, clis, and transcript_archive.

There is no generated OpenAPI spec. If you change a route, change this page in the same PR.
