---
title: The REST API
description: Every endpoint, re-derived from routes.rb and the controllers. The one reference for the REST API.
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

## Quick start

Every snippet below assumes these two:

```bash
API_KEY="your_api_key"
BASE_URL="https://your-zimmer-host/api/v1"
```

```bash
# Create a session on a configured agent root
curl -X POST "$BASE_URL/sessions" \
  -H "X-API-Key: $API_KEY" -H "Content-Type: application/json" \
  -d '{"agent_root": "zimmer", "prompt": "Fix the auth bug"}'

# Create one on an arbitrary repo instead
curl -X POST "$BASE_URL/sessions" \
  -H "X-API-Key: $API_KEY" -H "Content-Type: application/json" \
  -d '{"prompt": "Fix the auth bug", "git_root": "https://github.com/example/repo.git"}'

# List running sessions, search across transcripts, read one with its transcript
curl "$BASE_URL/sessions?status=running" -H "X-API-Key: $API_KEY"
curl "$BASE_URL/sessions/search?q=authentication&search_contents=true" -H "X-API-Key: $API_KEY"
curl "$BASE_URL/sessions/1?include_transcript=true" -H "X-API-Key: $API_KEY"

# Follow up, then archive (moves to trash)
curl -X POST "$BASE_URL/sessions/1/follow_up" \
  -H "X-API-Key: $API_KEY" -H "Content-Type: application/json" \
  -d '{"prompt": "Now add tests"}'
curl -X POST "$BASE_URL/sessions/1/archive" -H "X-API-Key: $API_KEY"
```

Spawn and poll, in Python:

```python
import requests, time

API_KEY = "your_api_key"
BASE_URL = "https://your-zimmer-host/api/v1"
headers = {"X-API-Key": API_KEY}

resp = requests.post(f"{BASE_URL}/sessions", headers=headers, json={
    "agent_root": "zimmer",
    "prompt": "Fix the auth bug",
})
session = resp.json()["session"]

while True:
    resp = requests.get(f"{BASE_URL}/sessions/{session['id']}", headers=headers)
    if resp.json()["session"]["status"] in ("needs_input", "failed", "archived"):
        break
    time.sleep(5)
```

And in JavaScript:

```javascript
const API_KEY = "your_api_key";
const BASE_URL = "https://your-zimmer-host/api/v1";
const headers = { "X-API-Key": API_KEY, "Content-Type": "application/json" };

const resp = await fetch(`${BASE_URL}/sessions`, {
  method: "POST",
  headers,
  body: JSON.stringify({ agent_root: "zimmer", prompt: "Fix the auth bug" }),
});
const { session } = await resp.json();

await fetch(`${BASE_URL}/sessions/${session.id}/follow_up`, {
  method: "POST",
  headers,
  body: JSON.stringify({ prompt: "Now add tests" }),
});
```

## Pagination

Most list endpoints take `page` and `per_page` (default 25, max 100) and answer with a `pagination`
object alongside the collection. `GET /categories` is the exception — it ignores both and returns
every category.

```jsonc
{
  "pagination": { "page": 1, "per_page": 25, "total_count": 312, "total_pages": 13 }
}
```

## Terminology

**Archived is "trash" in the UI, `archived` on the wire.** The status enum value is `archived` and
the column is `archived_at`; filters and status values never take `trash`. Only the prose moves —
archiving answers `"Session moved to trash"` and a `trash_after` timestamp saying when what the
archive retained gets cleaned up — preserved clone artifacts, the scratch directory, prompt
attachments. A clean clone is deleted well before that, at the end of the undo window.

**`git_root` is a string; `agent_root` is a catalog name.** `git_root` is a free-form repository URL
or local path stored on the session. `agent_root` names a preconfigured [agent
root](/air/agent-roots/) — `zimmer`, say — that resolves to a `git_root` plus defaults for `branch`,
`subdirectory`, `mcp_servers`, `catalog_skills`, `catalog_hooks`, `catalog_plugins`, and `model`.
Passing `agent_root` is the recommended way to spawn on a configured root.

## Sessions

`:id` resolves slug first, then numeric id.

| Method | Path | Notes |
| --- | --- | --- |
| `GET` | `/sessions` | filters: `status`, `agent_runtime`, `priority_class`, `genesis`, `show_archived`, `page`, `per_page`. Zimmer's own status-summary forks are never listed |
| `GET` | `/sessions/search` | `q` required (≤1000 chars), `search_contents=true`, plus the same `status` / `agent_runtime` / `priority_class` / `genesis` / `show_archived` filters as `/sessions`. Missing/oversized `q` → 400 (the only 400 in the API). Status-summary forks are never listed |
| `GET` | `/sessions/:id` | always returns top-level `status_summary`, `session_hierarchy` and `human_messages` beside `session`; `include_transcript=true` adds the raw transcript |
| `POST` | `/sessions` | → 201. See below. |
| `PATCH` | `/sessions/:id` | permits only `title`, `slug`, `goal`, `is_autonomous`, `scheduling_class`, `custom_metadata` |
| `DELETE` | `/sessions/:id` | → 204. Hard delete, not archive: the row and its associations go, and so do the session's [scratch directory and prompt attachments](/operate/background-jobs/#a-deleted-session-takes-its-directories-with-it) |
| `POST` | `/sessions/:id/archive` | from `waiting`, `running`, `needs_input`, or `failed` → `{session, message, trash_after}`. **422** while any message is still queued for the session, since archiving discards it; `force: true` overrides deliberately and the discarded messages are retired to `undelivered` — see [lifecycle](/sessions/lifecycle/) |
| `POST` | `/sessions/:id/unarchive` | → `{session, clone_restored, message}`. Recreates the clone directory and restores the transcript when they are gone, so the harness resumes where it left off |
| `POST` | `/sessions/:id/follow_up` | `prompt` (≤500,000), `goal` (≤50,000), `force_immediate`, `acting_session_id`. 202 if the session is running (queued); 200 otherwise. `goal` takes effect on every path — see below |
| `POST` | `/sessions/:id/pause` | running only → `needs_input` |
| `POST` | `/sessions/:id/sleep` | `needs_input` → sleeps; `running` → sets `pending_sleep` |
| `POST` | `/sessions/:id/restart` | clears stale retry metadata and re-queues the job; re-runs the whole setup pipeline if setup never finished (a failed clone, say) |
| `POST` | `/sessions/:id/fork` | `message_index` required → 201 |
| `POST` | `/sessions/:id/regenerate_status_summary` | → 202. Queues a forced rewrite of the [Status summary](/sessions/status-summary/); it forks the session and spends an agent turn, so it is asynchronous and must not be polled. 422 with the reason, rather than a 202 for work that cannot run, when there is nothing to summarize: no transcript, or a session that is itself a summary fork. An archived session is a normal candidate however long ago it was archived — the fork answers from the conversation, and gets an empty working directory when Zimmer has already reclaimed the clone |
| `POST` | `/sessions/:id/refresh` | re-read transcript from disk. A shorter filesystem transcript never overwrites a longer stored one — that happens when the clone was recreated at a new path, and the stored history wins |
| `POST` | `/sessions/refresh_all` | → `{message, refreshed, restarted, continued, errors}`. Max 50 restarts/continues. Sessions in a frozen category are parked and excluded |
| `POST` | `/sessions/bulk_archive` | `session_ids[]` → `archived_count` and any `errors`. A session with a queued message lands in `errors` and is left alone; `force: true` applies to the whole batch, not one member of it |
| `PATCH` | `/sessions/:id/mcp_servers` | max 50, validated against the catalog. Replaces the set; `[]` clears it and is recorded as deliberate, so the [backfill](/air/agent-roots/#omitting-a-list-is-not-the-same-as-asking-for-an-empty-one) does not restore the root's defaults |
| `PATCH` | `/sessions/:id/catalog_skills` · `/catalog_hooks` · `/catalog_plugins` | max 100 / 100 / 50 |
| `PATCH` | `/sessions/:id/model` | validated against `ModelCatalog` for the session's runtime |
| `PATCH` | `/sessions/:id/notes` | `session_notes` ≤ 50,000; empty string clears |
| `PATCH` | `/sessions/:id/heartbeat` | `enabled` and/or `interval_seconds` (30–86,400, default 60); omit either to leave it unchanged |
| `PATCH` | `/sessions/:id/set_category` | `category_id`; blank or omitted clears. Unknown id → 404 |
| `POST` | `/sessions/:id/toggle_favorite` | favorited sessions sort to the top of the dashboard |
| `GET` | `/sessions/:id/transcript` | `format=text` → `text/plain`, else `{transcript_text}` |

`force_immediate: true` on `follow_up` interrupts a running session and delivers the prompt now,
through the same race-free interrupt backend as the web UI's "Send Now" — exactly-once and
FIFO-ordered. When the interrupt can't be dispatched the staged message is discarded rather than
left half-queued, and the call answers 404, 409, 422, or 500.

`goal` on `follow_up` lands on every path — see
[Following up, and the `goal` that rides along](#following-up-and-the-goal-that-rides-along) below.

### Creating a session

Permitted params: `agent_root`, `agent_runtime`, `prompt`, `git_root`, `branch`, `subdirectory`,
`title`, `slug`, `goal`, `execution_provider`, `is_autonomous`, `parent_session_id`,
`auto_compact_window`, `scheduling_class`, `mcp_servers[]`, `catalog_skills[]`, `catalog_hooks[]`,
`catalog_plugins[]`, `config{}`, `custom_metadata{}`.

`branch` defaults to the root's `default_branch`, or `main`. `show_archived` and `search_contents`
default to false wherever they appear.

`priority_class` accepts `spot` or `priority`; `genesis` accepts one of `web_ui`, `slack`,
`github_issue`, `github_label`, `schedule`, `ao_event`, `api`, `unknown`. A session that carries no
`scheduling_class` of its own is classified from its genesis on read, so moving a genesis on Quotas
moves those sessions between the two `priority_class` values immediately — and the five trigger-backed
kinds are not movable that way at all (their class is set per trigger). An unrecognised value for
either filter is ignored rather than erroring.

`genesis` is not a permitted param on create and is never caller-supplied. A create that passes
`parent_session_id` inherits that parent's genesis; one that does not is recorded as `api`, which
classifies **spot**.

`scheduling_class` **is** caller-supplied, and takes precedence over whatever the genesis would give
the session. Send `spot` or `priority`; omit it and the session inherits its parent's explicit class
if it has one, and otherwise derives from its genesis. An unknown value is a `422` (unlike the
`priority_class`/`genesis` *filters* above, which ignore what they do not recognise — a filter that
matches nothing is not the same kind of mistake as a session created in the wrong class). It is also
permitted on `PATCH /sessions/:id`, which is how a spot session already held behind the quota gate is
moved to priority without touching the trigger that spawned it; send `null` to go back to derived.

See [Spot and priority](/sessions/spot-and-priority/). Every session object carries `genesis`,
`scheduling_class` (the explicit choice, usually `null`) and `priority_class` (the resolved answer).

`agent_root` is not a Session column — it names a catalog entry that expands into `git_root`,
`branch`, `subdirectory` and the catalog defaults, and is recorded as `metadata.agent_root_key`. An
invalid one → `422 {"error": "Invalid agent_root"}`.

**Omitting an artifact list is not the same as sending an empty one.** For `mcp_servers`,
`catalog_skills`, `catalog_hooks`, and `catalog_plugins`, leaving the key out takes the agent root's
defaults for that list, while sending an explicit `[]` creates the session with none of that
artifact. The two are different requests — see [omitted vs
`[]`](/air/agent-roots/#omitting-a-list-is-not-the-same-as-asking-for-an-empty-one) for the full rule
and for why an explicit `[]` survives to job start rather than being restored from the root's
defaults. Note that a form-encoded body cannot express an empty array; send JSON to request none.
Zimmer's own injected servers (`zimmer-self-session`) are added separately and still arrive.

`execution_provider` accepts exactly one value, `local_filesystem`; anything else is a `422`. It is a
column with one legal setting rather than a choice — every agent runs on the Zimmer host itself,
unsandboxed. See [Agents run unsandboxed on the app host](/limitations/#agents-run-unsandboxed-on-the-app-host).

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

`agent_runtime` must name a registered runtime; an unregistered value → 422.

Valid models are a property of the runtime, not the root (`ModelCatalog::MODELS`):

| Runtime | Models |
| --- | --- |
| `claude_code` | `opus` (default) · `sonnet` · `haiku` · `fable` |
| `codex` | `gpt-5.6-sol` (needs a ChatGPT login) · `gpt-5.6-terra` (default, needs a ChatGPT login) · `gpt-5.6-luna` (needs a ChatGPT login) · `gpt-5.5` (needs a ChatGPT login) · `gpt-5.4` (retires from ChatGPT sign-in August 31, 2026) · `gpt-5.4-mini` (retires from ChatGPT sign-in August 31, 2026) · `gpt-5.3-codex` (deprecated) · `gpt-5.2-codex` (deprecated) |

`PATCH /sessions/:id/model` validates against the list for the session's own runtime; anything else
→ `422 {"error": "Invalid model"}` with a message naming the valid ones.

### Following up, and the `goal` that rides along

`POST /sessions/:id/follow_up` has three delivery paths, and which one a request takes depends on
the session's status at the moment it arrives:

| Session status | What happens | Response |
| --- | --- | --- |
| `waiting` / `needs_input` | prompt is written to the session and `AgentSessionJob` is enqueued | 200 |
| `running` | prompt becomes a pending `EnqueuedMessage`, delivered when the turn ends | 202 |
| any of the three, with `force_immediate: true` | staged as an `EnqueuedMessage` and delivered through `Sessions::InterruptService`, terminating the running turn | 200 |

`goal` behaves identically on all three: **a non-blank goal is applied to the session, a blank or
omitted one leaves the session's existing goal alone.** The queued and interrupted paths carry it on
the `EnqueuedMessage` and `EnqueuedMessageProcessorService` applies it when it claims the message;
the direct path writes it alongside the prompt. A goal over `GOAL_MAX_LENGTH` (50,000) is rejected
with a 422 before anything is delivered, on every path.

### `acting_session_id`: declaring yourself as the caller

`follow_up`, and the enqueued-message `create` and `interrupt` endpoints, take an optional
`acting_session_id`. If you are an agent session driving *another* session, set it to your own id and
Zimmer records an "uncle" lineage edge marking you as a senior of the target — which widens that
session's hierarchy to include yours, so the human messages recorded in your hierarchy reach it as
`elsewhere` context.

It is self-declared and unverified, because the API key is shared by the whole fleet and identifies a
caller but not a session. Omit it and nothing is recorded; that is the right answer for a script or a
person with a curl command. The rules — including what happens when a junior calls back into its
senior — are in [Hierarchy and human
messages](/sessions/hierarchy-and-human-messages/#the-rules-including-inversion), and the provenance
consequences are in [Limitations](/limitations/).

There is no way to *clear* a goal through `follow_up` — a blank one means "leave it", not "remove
it". Use `PATCH /sessions/:id` with `goal: ""` for that. (The HTML endpoint behind the web follow-up
form reads a blank goal as a clear and an *absent* one as "leave it", a distinction the JSON API does
not draw. Nothing in the shipped UI sends the key either way; see
[the limitations page](/limitations/#a-follow-up-goal-can-set-but-never-clear).)

The MCP `action_session` tool's `follow_up` action takes the same `goal` parameter with the same
semantics.

### `session_json`

`id`, `slug`, `title`, `status`, `agent_runtime`, `prompt`, `git_root`, `branch`, `subdirectory`,
`execution_provider`, `goal`, `mcp_servers`, `all_mcp_servers`, `injected_mcp_servers`,
`catalog_skills`, `catalog_hooks`, `catalog_plugins`, `config`, `metadata`, `custom_metadata`,
`is_autonomous`, `heartbeat_enabled`, `heartbeat_interval_seconds`, `auto_compact_window`,
`genesis`, `scheduling_class`, `priority_class`, `category_id`, `category{}`, `session_id`, `job_id`,
`running_job_id`, `archived_at`, `trash_after`, `created_at`, `updated_at`, `session_notes`,
`session_notes_updated_at`, `favorited`.

Every response with a `session` key renders it through the same serializer
(`ApiSessionSerialization`), including `POST /enqueued_messages/:id/interrupt` — `session` means one
shape everywhere on the surface.

`GET /sessions/:id` returns three more top-level keys **alongside** `session`, never inside it —
precisely so the one-shape rule above keeps holding, since they cost queries the index would pay once
per card:

- `status_summary` — the cached "where things stand" blurb, or `null` when the session has never had
  one requested. `summary` and `messages_since_generated` are `null` until text exists; `state`
  (`idle`/`pending`/`ready`/`failed`), `generating` and `error` are always present, so a caller that
  asked for a regeneration can tell "still running" from "failed" without polling for text that may
  never arrive. `messages_since_generated` counts transcript events since the blurb was written —
  `0` means current. Reading it never generates one; see
  [The Status summary](/sessions/status-summary/).
- `session_hierarchy` — the lineage graph this session belongs to: `origin_session_id`,
  `root_session_ids`, `truncated`, `truncation_reason`, and `nodes[]` each with `id`, `title`,
  `agent_root`, `status`, `depth`, `parent_session_id`, `uncle_session_ids`, `current`, `genesis`
  and `priority_class`.
  `parent_session_id` is the **spawn** edge and means "spawned", NOT "most recently talked to".
  `uncle_session_ids` are the sessions that queued or interrupted this one and are therefore treated
  as additional seniors — self-declared by the caller, so a claim rather than a fact.
  `origin_session_id` is the spawn origin and stays single-valued; `root_session_ids` is every root
  the graph is drawn from, which uncle edges can make more than one. See
  [Hierarchy and human messages](/sessions/hierarchy-and-human-messages/).
- `human_messages` — the messages Zimmer knows a named human authored anywhere in that tree, each
  with `origin` (`here` — a human spoke to this session — or `elsewhere` — a human spoke to another
  session in the hierarchy), `author`, `author_display_name`, `channel`, `channel_label`,
  `authored_in_session_id`, `authored_in`, `entry_point`, `content` and `occurred_at`.

All three are unconditional on the show action — an empty `human_messages` means no human authored
anything in this hierarchy, which is a real answer; see
[Hierarchy and human messages](/sessions/hierarchy-and-human-messages/) for why absence is the point.

Five of those fields are easy to misread:

- **`all_mcp_servers` is the effective set** — selected + plugin-bundled + auto-injected. Read this
  one to learn what a session actually has wired.
- **`injected_mcp_servers` is only what Zimmer adds itself** (`zimmer-self-session`; `zimmer` for
  subagent roots). A strict subset, and not evidence of what is available.
- **`is_autonomous`** governs whether the session fires broadcast (unscoped) event triggers. It
  defaults to true; set it false for user-driven sessions that shouldn't trip global automation.
- **`category` is a four-key summary**, not the category resource below: `{id, name, position,
  is_frozen}`, or `null` when the session is Uncategorized.
- **`metadata` is Zimmer's own bookkeeping** — `clone_path`, `exit_status`, `agent_root_key`, and
  friends. `custom_metadata` is the one you own.

`heartbeat_enabled` defaults to false.

## Triggers

`GET /triggers` (filters `condition_type`, `status`) · `GET /triggers/:id` (+ `recent_sessions`,
limit 10) · `POST` · `PATCH` · `DELETE` · `POST /triggers/:id/toggle` ·
`POST /triggers/:id/invoke` · `GET /triggers/channels` (Slack; 503 when Slack is unconfigured).

Conditions are nested via `trigger_conditions_attributes`.

`POST /triggers/:id/invoke` fires the trigger now, without waiting for one of its conditions to
match — the same fire the Invoke button on the trigger page performs, through the same code path. The
session is linked to the trigger, counts toward `sessions_created_count`, and a reuse trigger follows
up its target session rather than spawning a new one. `status` is not consulted: a `disabled` trigger
can still be invoked, which is how you test one before enabling it — `status` governs whether the
trigger's own *conditions* fire it, not whether a caller may.

Send `variables` — an object keyed by the prompt template's placeholders (`link`, `text`, `author`,
`channel`, `event`, `repo`, `number`, `title`, `labels`) — to fill them in. Any other key is ignored,
a placeholder the template names but the request omits interpolates as an empty string, and
`{{time}}`/`{{date}}` fill themselves in. All of them take a string; `labels` also takes an array,
which is joined with commas.

```bash
curl -X POST https://zimmer.example.com/api/v1/triggers/12/invoke \
  -H "X-API-Key: $ZIMMER_API_KEY" -H "Content-Type: application/json" \
  -d '{"variables": {"link": "https://example.com/msg/1", "channel": "eng-alerts"}}'
```

`201 Created` returns `{trigger, session, burst_notice, message}` — `session` is the compact
`{id, slug, title, status, created_at}` shape `recent_sessions` uses, and `trigger` is the full
payload with its counters already updated. Two outcomes are not ordinary successes:

- **`burst_notice: true`** (still 201) — the trigger blew its [burst
  cap](/sessions/triggers/#burst-control), so `session` is the burst-notice session it spawned
  instead of the one you asked for.
- **429 Too Many Requests** (`error: "Burst suppressed"`) — the trigger is inside a burst it has
  already announced, so nothing at all was created.

A one-time reuse trigger whose target session is gone or is no longer reusable returns 422
(`error: "No session created"`), with `session` carrying that target when the row still exists and
`null` when it does not. An agent root that cannot be resolved returns 422
(`error: "Invalid agent_root"`).

The MCP equivalent is `action_trigger` with `action: "invoke"`.

`max_sessions_per_minute` (integer, nullable) sets the trigger's [burst
cap](/sessions/triggers/#burst-control); `null` — the default — means unbounded. The trigger payload
also reports `bursting`, true while the trigger is inside a burst and spawning nothing.

`scheduling_class` (`spot` / `priority` / `null`) sets the [spot or
priority](/sessions/spot-and-priority/) class of the sessions this trigger spawns; `null` — the
default — derives it from the trigger's condition type. The payload reports both `scheduling_class`
(what was chosen, usually `null`) and `effective_scheduling_class` (what its sessions actually get).
Changing it applies to sessions the trigger spawns from then on.

`status` is one of `enabled`, `disabled`, or `failed`, and all three work as `?status=` filters.
`failed` is Zimmer's to set: a one-shot fire raised and the trigger was
[parked rather than destroyed](/sessions/triggers/#when-a-one-time-fire-fails) — either a one-time
schedule or a [session-scoped `ao_event` wake](/sessions/triggers/#when-an-ao_event-fire-fails). The payload carries
`failed_at` and `last_error` alongside it, both `null` on a healthy trigger — any write that moves
the status off `failed`, including `POST /triggers/:id/toggle`, clears them.

## Notifications

`GET /notifications` (`status=read|unread`) · `GET /notifications/:id` ·
`GET /notifications/badge` → `{pending_count}` · `PATCH /notifications/:id/mark_read` ·
`PATCH /notifications/mark_all_read` · `DELETE /notifications/:id/dismiss` (422 if unread) ·
`DELETE /notifications/dismiss_all_read` · `POST /notifications/push` (`session_id` + `message`).

## Health

`GET /health` → `{health_report, timestamp, rails_env, ruby_version}` ·
`POST /health/cleanup_processes` · `POST /health/retry_sessions` ·
`POST /health/archive_old` (`days`, clamped 1–365, default 7).

`GET /health/queue_recovery_mode` · `POST /health/enter_queue_recovery_mode` (`reason`,
`ttl_minutes`, clamped 5–240, default 60) · `POST /health/exit_queue_recovery_mode` — the job-queue
escape hatch. Entering halts execution on `pollers`, `triggers` and `default` and leaves `agents`
running, so a session started to investigate the backlog still runs. `GET /health` carries the same
state under a top-level `queue_recovery_mode` key. These three are deliberately **not** behind the
cooldown described below: an overloaded instance is exactly when the cache is least trustworthy, and
the cooldown fails closed. Entering answers 503 `Queue recovery mode unavailable` when
`config.good_job.enable_pauses` is off, rather than reporting a halt GoodJob would ignore. See
[Queue recovery mode](/operate/background-jobs/#queue-recovery-mode).

Two health endpoints sit **outside** this API — no `/api/v1` prefix, no API key, because a load
balancer and a deploy gate have neither: `GET /up` (200 if the process booted) and `GET /up/deep`
(200 only if the database, the cache and Redis each answered a real round trip; `503` with a
`failed` list naming the one that did not). They report; they change nothing, and they are not rate
limited. See [Deploying](/operate/deploying/#up-is-a-liveness-ping-updeep-is-the-health-check).

:::caution[The only rate limit in the API lives here]
The three `POST`s share `HealthActionCooldown::COOLDOWN = 30.seconds` — and share it with the MCP
`action_health` tool and the `/health` web dashboard — keyed in `Rails.cache` as
`health_api_rate_limit:<action>:<digest>`, where `<digest>` is a SHA-256 of the presented
`X-API-Key`. The cooldown is therefore per action **and** per key — your cleanup does not throttle
anyone else's — and the raw key never appears in a cache key. Exceeded →
`429 {"error": "Rate limited", "retry_after": 30}`.

The limiter fails closed. If the cache cannot enforce the cooldown — a null store, or a Redis that is
down, which `:redis_cache_store`'s `error_handler` turns into silent nils rather than an exception —
the three `POST`s return `503 {"error": "Rate limiting unavailable"}` rather than running
unthrottled. `GET /health` is unaffected. See
[the limitation](/limitations/#the-only-rate-limit-is-on-the-health-endpoints-and-it-needs-a-real-cache).
:::

## Costs

`GET /api/v1/costs` → rollups over a window: `totals`, `cost_breakdown` (by kind of token),
`by_day`, `by_agent_root`, `by_model`, `by_thread_kind`, `by_adhoc_source`, `top_sessions`, and
`unpriced_models`. Window is `days` (default 7, clamped 1–365) or explicit `from`/`to`.

`GET /api/v1/costs/records` → the underlying rows, paginated. `kind` selects the table
(`session`, the default, or `adhoc`); filter with `session_id`, `agent_root`, `model`, `subagent`,
or `source`. This is the export path for cost-versus-performance analysis — the app deliberately
does not try to do that analysis itself.

`POST /api/v1/costs/backfill` → queue a sweep of every transcript on disk into the ledger. This is
an **ops action with an endpoint rather than a shell**: getting history into the ledger must not
require SSH onto the production box. Idempotent — it returns the run already in flight rather than
starting a second one, and ingestion upserts on `request_id`, so a re-read directory writes no
duplicate rows. The same sweep starts itself after a deploy; this is for a re-scan.

`GET /api/v1/costs` also carries `ledger_coverage`: whether the one-time historical sweep has
finished, how far it has got, and `covers_since` — the oldest call actually stored. A total whose
coverage is unknown is not interpretable, which is why it travels with the figures.

Both rollup and record responses carry a `pricing` object: the per-MTok rates and cache multipliers used to produce
every dollar figure in that response. Volumes are stored, prices are applied on read, so a figure
without its rate table is not reproducible — see [Token spend](/operate/costs/).

Dollar amounts are **list price, not a bill**. These accounts are subscription-billed; the figures
are a comparable unit across models. A model with no configured rate contributes zero and is named
in `unpriced_models` rather than being silently folded into the total.

## Elicitations

- `POST /elicitations` — **UNAUTHENTICATED**. Requires `_meta["com.pulsemcp/request-id"]` and
  `message`. → 201.
- `GET /elicitations/:request_id` — **UNAUTHENTICATED**. Auto-expires past `expires_at`.
- `PATCH /elicitations/:id/respond` — authenticated. `action_type` ∈ `accept | decline | cancel`,
  optional `content` (kept only for `accept`; `cancel` is the protocol's "dismissed without
  answering"). `:id` is either the `request_id` or the numeric primary key, so the identifier you
  already hold — from a poll response or from the web UI's own `/elicitations/:id/respond` route —
  works here too.

`show` stays `request_id`-only on purpose: it is unauthenticated for the poll protocol, and
accepting a primary key there would turn it into a sequential-id enumeration of every elicitation.

The first two skip auth because the MCP child process has no API key. See
[Elicitation](/sessions/elicitation/).

Note the parameter is `action_type`, not `action` — `action` is a Rails reserved param.

`respond` is the authenticated counterpart to a human clicking the button in the web UI: it lets a
script or agent resolve the request, which unblocks the owning session (`needs_input` → `running`).
It answers 200 with the poll response — `action`, `content`, and a `_meta` carrying
`com.pulsemcp/request-id` and `com.pulsemcp/responded-at` — or 404 when nothing matches the
identifier, 422 when the elicitation is already resolved or `action_type` is not one of the three.

## Categories

Organizational buckets for the dashboard. Full CRUD at `/categories[/:id]` plus
`POST /categories/reorder`.

A category is `{id, name, description, position, is_frozen, session_count, created_at, updated_at}`.
`name` is required, unique case-insensitively, ≤100 chars, and whitespace-stripped; `description` is
≤1000 chars and stored as null when blank. New categories append to the end of the stack. Deleting
one nullifies its sessions' `category_id` — the sessions themselves survive as Uncategorized.

A **frozen** category (`is_frozen: true`) is a parked bucket: its sessions are excluded from
refresh-all and from recovery.

`PATCH /categories/:id` is a genuine partial update — sending only `is_frozen` leaves `name` and
`description` alone.

`POST /categories/reorder` takes `ids`, an ordered array top to bottom; each listed category's
`position` becomes its index, and any category you leave out keeps the position it had. The string
sentinel `"uncategorized"` positions the Uncategorized section, which is stored on `AppSetting`
rather than as a row — so it is not in the category list the call returns.

```bash
curl -X POST "$BASE_URL/categories/reorder" \
  -H "X-API-Key: $API_KEY" -H "Content-Type: application/json" \
  -d '{"ids": [5, "uncategorized", 3, 8]}'
```

## The rest

| Resource | Endpoints |
| --- | --- |
| **Logs** | Full CRUD at `/sessions/:session_id/logs[/:id]`. `content` and `level` are required on create; `level` ∈ `info · error · debug · warning · verbose`, and doubles as the index filter |
| **Subagent transcripts** | Full CRUD at `/sessions/:session_id/subagent_transcripts[/:id]`. `agent_id` required on create; `PATCH` takes every field but `id` and `session_id`; index filters on `status` and `subagent_type`; `include_transcript=true` on show returns the full JSONL |
| **Enqueued messages** | CRUD + `PATCH :id/reorder` (`position` ≥ 1) + `POST :id/interrupt` (pauses a running session first). `content` ≤ 500,000 chars, optional `goal`; `status` ∈ `pending · processing · sent · undelivered`; the read payload also carries `origin` ∈ `caller · automated_pr_merged · automated_merge_conflict`, which records who wrote the row and is settable by no request. Archiving a session is **refused** (422) while any row is `pending`, since the archive would discard it; `force: true` on the archive overrides that and retires the rows to `undelivered` — see [lifecycle](/sessions/lifecycle/). Deleting one re-numbers the positions behind it |
| **CLIs** | `GET /clis/status` · `POST /clis/refresh` · `POST /clis/clear_cache` |
| **Transcript archive** | `GET /transcript_archive/download` (zip) · `/status` |
| **Config (read-only)** | `GET /configs` → `{mcp_servers, agent_roots, runtime_models, goals}`, where each root is the full `AgentRootsConfig::Root#to_h` (see [Agent roots](/air/agent-roots/)) and `runtime_models` is grouped by runtime with each model's `id`, `label`, `default`, and `requires_oauth` · `GET /mcp_servers` → `{name, title, description}` · `GET /skills` |

One endpoint lives outside `/api/v1`: `GET /api/secrets/keys` → `{secrets: [{name, description}]}`,
the secret-name autocomplete. It returns *names and descriptions*, never values, and it sits behind
the same `X-API-Key` gate as everything else.

### Transcript content is redacted

Every endpoint that returns or accepts transcript content serves the **redacted** copy —
`GET /sessions/:id?include_transcript=true`, `GET /sessions/:id/transcript`,
`POST /sessions/:id/refresh`, the subagent-transcript endpoints, and the transcript archive. Zimmer
redacts on write, as bytes come off disk, so a credential an agent printed reads back as
`[REDACTED:<LABEL>]` rather than the value. Content **posted** to
`/sessions/:session_id/subagent_transcripts` is redacted on the way in as well.

No request parameter, response field, or status code changes because of this — only the bytes inside
`transcript`. Two consequences worth planning around: a consumer diffing a transcript against the
file on disk will see the markers, and redaction is irreversible, so the plaintext is not recoverable
through the API. It is **defense in depth, not a guarantee** — see
[Transcripts](/sessions/transcripts/) for what it does and does not catch, and keep treating a
downloaded transcript as secret material.

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

There is no second copy of this reference and no generated OpenAPI spec. If you change a route,
change this page in the same PR — `app/controllers/api/AGENTS.md` says so, and this is the one page
to change.
