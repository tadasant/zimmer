---
title: The REST API
description: Every endpoint, re-derived from routes.rb and the controllers — including the six resources the old reference omitted.
sidebar:
  order: 1
---

Base URL `/api/v1`. Authentication is the `X-API-Key` header, compared against
`ENV["API_KEYS"]` (comma-separated) with a constant-time comparison.

:::tip[Agents should use MCP, not this]
Zimmer also serves a native MCP endpoint at `POST /mcp` — same API key, same service objects, 18
tools. If the caller is an agent rather than a script, that is the surface to point it at.
→ [Zimmer's MCP server](/extend/mcp-server/).
:::

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
| `POST` | `/sessions/refresh_all` | → `{message, refreshed, restarted, continued, errors}`. Max 50 restarts/continues |
| `POST` | `/sessions/bulk_archive` | `session_ids[]` |
| `PATCH` | `/sessions/:id/mcp_servers` | max 50, validated against the catalog |
| `PATCH` | `/sessions/:id/catalog_skills` · `/catalog_hooks` · `/catalog_plugins` | max 100 / 100 / 50 |
| `PATCH` | `/sessions/:id/model` | validated against `ModelCatalog` for the session's runtime |
| `PATCH` | `/sessions/:id/notes` | `session_notes` ≤ 50,000 |
| `PATCH` | `/sessions/:id/heartbeat` | `enabled` and/or `interval_seconds` (30–86,400) |
| `PATCH` | `/sessions/:id/set_category` | blank clears |
| `POST` | `/sessions/:id/toggle_favorite` | |
| `GET` | `/sessions/:id/transcript` | `format=text` → `text/plain`, else `{transcript_text}` |

### Creating a session

Permitted params: `agent_root`, `agent_runtime`, `prompt`, `git_root`, `branch`, `subdirectory`,
`title`, `slug`, `goal`, `execution_provider`, `is_autonomous`, `parent_session_id`,
`auto_compact_window`, `mcp_servers[]`, `catalog_skills[]`, `catalog_hooks[]`, `catalog_plugins[]`,
`config{}`, `custom_metadata{}`.

`agent_root` is not a Session column — it names a catalog entry that expands into `git_root`,
`branch`, `subdirectory` and the catalog defaults, and is recorded as `metadata.agent_root_key`. An
invalid one → `422 {"error": "Invalid agent_root"}`.

The `AgentSessionJob` is enqueued only if `prompt` is present.

#### Which runtime and model you get

One chain, whether or not you name an `agent_root`:

```
request param  →  agent root's declared value  →  AppSetting (the Settings page)  →  hardcoded default
```

With no `agent_root` there is simply no root tier and the chain falls through to `AppSetting`, so a
rootless API spawn honors the global defaults the Settings page presents. A model that isn't valid
for the resolved runtime — a root pinning `opus` on a `codex` spawn, say — self-heals to the global
default for that runtime rather than persisting something the harness can't run. `config.model` is
always explicitly set on the created session.

### `session_json`

`id`, `slug`, `title`, `status`, `agent_runtime`, `prompt`, `git_root`, `branch`, `subdirectory`,
`execution_provider`, `goal`, `mcp_servers`, `all_mcp_servers`, `injected_mcp_servers`,
`catalog_skills`, `catalog_hooks`, `catalog_plugins`, `config`, `metadata`, `custom_metadata`,
`is_autonomous`, `heartbeat_enabled`, `heartbeat_interval_seconds`, `auto_compact_window`,
`category_id`, `category{}`, `session_id`, `job_id`, `running_job_id`, `archived_at`, `trash_after`,
`created_at`, `updated_at`, `session_notes`, `session_notes_updated_at`, `favorited`.

Every response with a `session` key renders it through the same serializer
(`ApiSessionSerialization`), including `POST /enqueued_messages/:id/interrupt` — `session` means one
shape everywhere on the surface.

## Triggers

`GET /triggers` (filters `condition_type`, `status`) · `GET /triggers/:id` (+ `recent_sessions`,
limit 10) · `POST` · `PATCH` · `DELETE` · `POST /triggers/:id/toggle` · `GET /triggers/channels`
(Slack; 503 when Slack is unconfigured).

Conditions are nested via `trigger_conditions_attributes`. The web UI's `triggers#invoke` route has
no API equivalent.

`max_sessions_per_minute` (integer, nullable) sets the trigger's [burst
cap](/sessions/triggers/#burst-control); `null` — the default — means unbounded. The trigger payload
also reports `bursting`, true while the trigger is inside a burst and spawning nothing.

## Notifications

`GET /notifications` (`status=read|unread`) · `GET /notifications/:id` ·
`GET /notifications/badge` → `{pending_count}` · `PATCH /notifications/:id/mark_read` ·
`PATCH /notifications/mark_all_read` · `DELETE /notifications/:id/dismiss` (422 if unread) ·
`DELETE /notifications/dismiss_all_read` · `POST /notifications/push` (`session_id` + `message`).

## Health

`GET /health` → `{health_report, timestamp, rails_env, ruby_version}` ·
`POST /health/cleanup_processes` · `POST /health/retry_sessions` ·
`POST /health/archive_old` (`days`, clamped 1–365, default 7).

:::caution[The only rate limit in the API lives here]
The three `POST`s share `HealthActionCooldown::COOLDOWN = 30.seconds` — and share it with the MCP
`action_health` tool — keyed in `Rails.cache` as
`health_api_rate_limit:<action>:<digest>`, where `<digest>` is a SHA-256 of the presented
`X-API-Key`. The cooldown is therefore per action **and** per key — your cleanup does not throttle
anyone else's — and the raw key never appears in a cache key. Exceeded →
`429 {"error": "Rate limited", "retry_after": 30}`.

The limiter fails closed. If `Rails.cache` is a null store the cooldown cannot be enforced, so the
three `POST`s return `503 {"error": "Rate limiting unavailable"}` rather than running unthrottled.
`GET /health` is unaffected. See
[the limitation](/limitations/#the-only-rate-limit-is-on-the-health-endpoints-and-it-needs-a-real-cache).
:::

## Elicitations

- `POST /elicitations` — **UNAUTHENTICATED**. Requires `_meta["com.pulsemcp/request-id"]` and
  `message`. → 201.
- `GET /elicitations/:request_id` — **UNAUTHENTICATED**. Auto-expires past `expires_at`.
- `PATCH /elicitations/:id/respond` — authenticated. `action_type` ∈ `accept | decline`, optional
  `content`. `:id` is either the `request_id` or the numeric primary key, so the identifier you
  already hold — from a poll response or from the web UI's own `/elicitations/:id/respond` route —
  works here too.

`show` stays `request_id`-only on purpose: it is unauthenticated for the poll protocol, and
accepting a primary key there would turn it into a sequential-id enumeration of every elicitation.

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

One endpoint lives outside `/api/v1`: `GET /api/secrets/keys` → `{secrets: [{name, description}]}`,
the secret-name autocomplete. It returns *names and descriptions*, never values, and it sits behind
the same `X-API-Key` gate as everything else.

### The plain-text transcript

`transcript_text` is a rendered reading copy, not the raw transcript — for that, use
`GET /sessions/:id?include_transcript=true`.

Every entry is rendered. Entries the renderer has no special layout for (`system`, `result`,
`summary`, anything a future harness emits) are labeled and dumped rather than dropped. Content that
arrives as an array of blocks is rendered block by block — `text`, `thinking`, `image`, `tool_use`,
`tool_result`, and pretty JSON for anything else. Tool results are truncated to 500 characters.

## Errors

One shape, everywhere:

```jsonc
{
  "error":    "Validation failed",                              // short label
  "message":  "Title can't be blank, Slug is invalid",          // always a String
  "messages": ["Title can't be blank", "Slug is invalid"]       // always an Array of String
}
```

`message` is `messages.join(", ")`. Read whichever suits you; neither needs a type check. A handful
of responses carry an extra top-level key alongside these — `retry_after` on the health 429.

**Status codes in use:** 200 · 201 · 202 (follow-up queued) · 204 · 400 (search only) · 401 · 404 ·
409 (follow-up position collision, interrupt races) · 422 · 429 (health cooldown) · 500 · 503 (Slack
unconfigured; health maintenance refused because no usable cache store is configured).

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
