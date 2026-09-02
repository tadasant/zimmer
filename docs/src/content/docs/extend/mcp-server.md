---
title: Zimmer's MCP server
description: The native MCP server Zimmer serves at POST /mcp — its 23 tools, the scoped variants, API-key auth, and how to point a client at it.
sidebar:
  order: 2
---

Zimmer speaks [MCP](https://modelcontextprotocol.io) itself. `POST /mcp` is a streamable-HTTP MCP
endpoint served by the Rails app, and it is how an agent session reaches back into the orchestrator
that spawned it: to archive itself, to schedule its own wake-up, to spawn a downstream session, to
tell you it is stuck.

There is no separate process. The tools call Zimmer's models and services in-process — the same ones
[the REST API](/extend/rest-api/) calls — so there is nothing to install, nothing to keep in version
lockstep, and no HTTP hop back into the app.

The protocol itself is the [official MCP Ruby SDK](https://github.com/modelcontextprotocol/ruby-sdk)
(the `mcp` gem): JSON-RPC framing, version negotiation, the streamable-HTTP transport, and argument
validation against each tool's schema. Zimmer supplies the two things the SDK cannot know — who may
call (the API key) and what this connection may see (the scoped tool list).

## Point a client at it

Any MCP client that speaks streamable HTTP works. The whole configuration is a URL and an API key:

```json
{
  "mcpServers": {
    "zimmer": {
      "type": "http",
      "url": "https://your-zimmer.example.com/mcp",
      "headers": { "X-API-Key": "one-of-your-API_KEYS" }
    }
  }
}
```

That is Claude Code's `.mcp.json`. Codex's `config.toml` wants the same two things under different
keys:

```toml
[mcp_servers.zimmer]
url = "https://your-zimmer.example.com/mcp"
http_headers = { "X-API-Key" = "one-of-your-API_KEYS" }
```

Or drive it by hand:

```bash
curl -s https://your-zimmer.example.com/mcp \
  -H "X-API-Key: $ZIMMER_API_KEY" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

## Auth is the API's auth

The `X-API-Key` header, compared against `ENV["API_KEYS"]` (comma-separated) with a constant-time
comparison — literally `Api::BaseController`, which `McpController` inherits. A key that works
against `/api/v1/sessions` works against `/mcp`.

MCP clients that only know how to send a bearer token can send the same key as
`Authorization: Bearer <key>` instead. There is one credential either way.

:::caution[Scoping is an affordance, not a trust boundary]
A key is an opaque string with no scope, no identity, and no audit trail — the same caveat as
[the REST API](/extend/rest-api/). The scoping below (`tool_groups`, `allowed_agent_roots`) lives in
the URL, so a caller that holds a key can always widen it by asking for a different URL — or skip MCP
and call `/api/v1` directly. It exists to give an agent the *right* surface, not to contain a
determined one. Anyone you hand a key to can do anything a key can do.
:::

## Scoped variants: `tool_groups`

The same endpoint serves several **scoped variants**, selected with a query parameter. This is how a
session gets exactly the surface it should have and no more.

| URL | Tools |
| --- | --- |
| `/mcp` | The full surface — all 23 tools |
| `/mcp?tool_groups=sessions` | Session orchestration: spawn, search, inspect, act on other sessions |
| `/mcp?tool_groups=self_session` | Self-management: the 7 tools a session needs to run itself |
| `/mcp?tool_groups=triggers_readonly,health_readonly` | Any combination; `_readonly` drops the write tools |
| `/mcp?tool_groups=self_session&session_id=42` | Names the calling session, so self-management tools can default to it |

The groups are `sessions`, `notifications`, `triggers`, `health` (each with a `_readonly` variant),
plus the composite `self_session`. Omitting `tool_groups` enables all four base groups. An unknown
group is dropped with a warning rather than failing the connection.

`self_session` is the important one. It is **auto-injected into every session** (see below) and
carries `get_session`, `get_session_provenance`, `get_configs`, `send_push_notification`,
`wake_me_up_later`, `wake_me_up_when_session_changes_state`, and a **restricted `action_session`** —
the same tool name, but its `action` enum is narrowed to `update_notes`, `update_title`, `set_heartbeat`,
`pause_into_spot_queue`, and `archive`.
A session can manage itself; it cannot restart, fork, or re-configure anything. In particular the
capability/config edits on the full surface — `change_mcp_servers`, `change_model`, `change_skills`,
`change_hooks`, `change_plugins`, `change_goal`, `change_auto_compact_window`, `change_category`,
`toggle_push_notifications` — are deliberately absent here: a session must not rewrite
its own capabilities, goal, or organizational placement through the server injected into it. (The
*action* is narrowed, not the *target*: every tool takes a `session_id`, and a session is trusted to
pass its own. See the caution above.)

The injected entry's URL also carries `session_id=<id>` — the session the config was written for.
Nothing in an MCP request body identifies its caller (the API key is shared by the whole fleet and
the transport is stateless), so this is the only place that knowledge exists. The wake-up tools use
it to default their `session_id` argument, which is the difference between a session's first wake
call working and it failing on an argument the agent cannot see the value of. It is a **default and
not a scope**: `tool_groups` and `allowed_agent_roots` still decide everything the connection may
reach, and an explicit `session_id` always wins. `RuntimeConfigPostProcessor` stamps it onto every
Zimmer entry in a session's config, including catalog-provided ones, and leaves alone any entry that
already names a session.

## Restricting what a connection may spawn: `allowed_agent_roots`

```
/mcp?tool_groups=sessions&allowed_agent_roots=zimmer,docs
```

With `allowed_agent_roots` set, the connection is locked to those [agent roots](/air/agent-roots/):

- `start_session` requires an `agent_root`, it must be in the list, and its `mcp_servers` must
  **exactly** match that root's `default_mcp_servers` — no additions, no removals. That includes
  `[]`: on an unrestricted connection an explicit empty array is a valid request for no servers
  ([omitted vs `[]`](/air/agent-roots/#a-list-you-pass-replaces-the-roots-defaults)),
  but here it is a removal and is rejected unless the root has no defaults to begin with.
- `action_trigger` may only create, update, delete, toggle, or invoke triggers on an allowed root,
  and `search_triggers` only shows those.
- `action_session`'s `change_mcp_servers` — and `change_plugins`, since plugins can bundle MCP
  servers — are refused outright.
- `wake_me_up_when_session_changes_state` refuses to watch a session outside the allowed roots. (A
  session waking *itself* is never restricted.)
- `get_configs` hides the roots you may not use, so the model never sees them.

  It hides unusable MCP servers the same way, on every connection: a server whose `${VAR}` does not
  resolve or whose OAuth credential is missing or dead is left out of the server list and named in a
  trailing **Unavailable** roster instead — enough for an agent to tell a broken server from an
  absent one without offering it as a choice. → [Availability, and what an agent is
  offered](/air/mcp-servers/#availability-and-what-an-agent-is-offered)

## What Zimmer injects into every session

`SelfSessionInjector` + the runtime config post-processors write these entries into a session's
`.mcp.json` / `config.toml` at prepare time. They are not catalog entries — Zimmer synthesizes them,
pointed at the instance that is running the session:

| Entry | When | URL |
| --- | --- | --- |
| `zimmer-self-session` | Every session, unless something already covers the surface | `<instance>/mcp?tool_groups=self_session` |
| `zimmer` | Roots that declare `default_subagent_roots` | `<instance>/mcp?allowed_agent_roots=<those roots>` |

The `zimmer` entry is full-surface, which is why it *does* cover the self-session surface — a parent
root gets one server, not two. A catalog entry you select yourself (`zimmer`, `zimmer-sessions`,
`zimmer-self-session` in `mcp.json`) that is full-surface suppresses the injection the same way.

Both injections are defensive about a name collision. If the catalog already supplies a `zimmer`
entry, the subagent injection leaves it alone rather than overwriting it — the two are the same URL
differentiated only by query param, so writing the root-restricted `allowed_agent_roots` over a
catalog-provided full-surface entry would silently narrow what the session may spawn. The
catalog's entry (retargeted) wins, and `start_session` keeps its full root surface.

Outside production, every `zimmer*` entry is **retargeted** at the instance preparing the session:
the origin is rewritten and the API key replaced, while the query string (the scoping) is preserved.
A staging session orchestrates staging, not production — even though the catalog's URLs say
production.

## The tool surface

23 tools, four domains.

| Group | Tools |
| --- | --- |
| `sessions` | `quick_search_sessions`, `get_session`, `get_session_provenance`, `get_configs`, `get_transcript_archive`, `start_session`, `action_session`, `manage_enqueued_messages`, `manage_categories`, `respond_to_elicitation`, `save_outcome_analysis` |
| `notifications` | `get_notifications`, `send_push_notification`, `action_notification` |
| `triggers` | `search_triggers`, `action_trigger`, `wake_me_up_later`, `wake_me_up_when_session_changes_state` |
| `health` | `get_system_health`, `action_health`, `get_spot_policy`, `action_spot_policy`, `get_costs` |

`quick_search_sessions` matches session titles plus the `metadata` and `custom_metadata` JSON by
default, and `search_contents: true` widens it to the **transcript** — this is the MCP route to
finding a session by something said mid-conversation, and it exists so nobody has to `curl` the REST
API for it. That scan is bounded rather than best-effort (the `transcript` column has no index a
substring match can use), so it walks candidates newest-first, stops at `per_page` matches or a
wall-clock budget, orders results newest-first regardless of `order`, and reports **no total count**.
When it stops early it says so and returns a `scan_cursor`; pass that back with the same query and
filters to continue from exactly where it stopped. An empty result that says "scan incomplete" means
"not found yet", not "not there". `get_transcript_archive` is a bulk export, not the search — it is
hundreds of megabytes and up to ten minutes stale.

Two defaults matter when the question is "does this work already have a session?". `show_archived`
defaults to `false`, and a session that finished a piece of work has archived itself — so a
duplicate check has to pass `show_archived: true` or name `archived` in `status`, or it misses
exactly the sessions it is looking for. And each result's prompt line is a preview, the first
100 characters, so an issue URL named later in a prompt is not visible in the listing; `query` does
not read the prompt column, so search for the identifier a router put in `custom_metadata` instead.

`get_session` always includes a `### Session Hierarchy` section (the spawn tree this session belongs
to — an edge means "spawned", not "most recently talked to") and a `### Human Messages` section (the
messages Zimmer knows a named human authored anywhere in that tree, with author, channel, timestamp,
content and the session each was said in). Neither is behind an `include_` flag, because the most
important reading of the message record is the empty one: a caller asking "did a human authorize
this?" must be able to tell "no human turns" from "I forgot the flag." Entries are marked `here` (a
human spoke to this session) or `elsewhere` (a human spoke to another session in the hierarchy). See
[Hierarchy and human messages](/sessions/hierarchy-and-human-messages/).

`get_session_provenance` returns those same two sections on their own, for one `session_id`. Zimmer
injects neither into a session's turns, so this is the tool a session calls to read its own
provenance — and its description, not a block in the prompt, is where the caveats that record has to
be read with are stated. Like `get_session` it is in `self_session` as well as `sessions`, because
the auto-injected self-session server is the only surface every session carries.

Note the corollary for
anything calling `action_session` with `follow_up`: a follow-up issued over this API is
machine-authored and records nothing, which is deliberate — pass `parent_session_id` to
`start_session` so the session you spawn can see the human context you were given.

For a session that already exists, `acting_session_id` is the equivalent. Set it on `follow_up`, or
on `manage_enqueued_messages` `create` / `send_now` / `interrupt`, to your own session id: Zimmer
records an "uncle" lineage edge marking you as a senior of the target, and that widens the target's
hierarchy to include yours, so your hierarchy's human messages reach it as `elsewhere` context. Like
`parent_session_id` it is self-declared and unverified — the API key identifies a caller, not a
session — so omitting it records nothing, and a recorded edge is a claim of seniority rather than
proof of one. The rules, including what happens when a junior calls back into its senior, are in
[Hierarchy and human
messages](/sessions/hierarchy-and-human-messages/#the-rules-including-inversion).

`archive` takes the same argument for a different purpose: **provenance, and no edge**. It records
you as the actor on the archived session's own timeline, so a human reading that session later can
tell an agent archiving it from a human clicking Trash. Set it whenever an agent drives an archive,
including archiving itself; an archive that declares nothing is logged as one. See
[the archive line](/sessions/lifecycle/#the-archive-line-names-who-did-it).

`action_health`'s three destructive actions (`cleanup_processes`, `retry_sessions`, `archive_old`)
share a 30-second cooldown with `Api::V1::HealthController` and the `/health` web dashboard — the
same `HealthActionCooldown` object, bucketed by a digest of the connection's API key. Switching
surfaces does not buy a second run, and one client's cleanup does not throttle anyone else's. If the
cache cannot enforce the cooldown (a null store, or a Redis that is down), the tool refuses with
`Rate limiting unavailable` rather than running unthrottled; `cli_refresh` and `cli_clear_cache`
only enqueue a job and are never throttled. See
[the limitation](/limitations/#the-only-rate-limit-is-on-the-health-endpoints-and-it-needs-a-real-cache).

`action_health` also carries the job-queue escape hatch: `enter_queue_recovery_mode` (`reason`,
`ttl_minutes`) halts execution on `pollers`, `triggers`, `inference`, `maintenance` and `default` while leaving `agents`
running, and `exit_queue_recovery_mode` resumes it. Both are outside that cooldown — the way out of
a halt has to work on the first try. `get_system_health` states the mode up front when it is on,
because a pending-job count means something completely different when the queues are deliberately
frozen. An agent session only gets these if its connection was given the `health` tool group; the
curated `self_session` set does not include it. See
[Queue recovery mode](/operate/background-jobs/#queue-recovery-mode).

`get_system_health` also names the backlogged queues and job classes whenever ready work is waiting,
plus each queue's own head-of-line age and the single longest-waiting job's lane and class, carrying
the same split as the `Queue backlog critical` Slack page. This is the parity that matters for
triage: the GoodJob dashboard at `/jobs` needs a browser session on the production host, which an
agent session does not have. The ages are what let an agent triaging `Zimmer GoodJob queue is not
draining` tell one starved lane from a wedged worker — `oldest_ready_age_seconds` in the JSON body is
a maximum across every queue at once, and a two-thread lane in front of minute-long jobs reads
exactly like a wedge through it. It is silent when nothing is waiting, and says so explicitly when
the read itself fails rather than dropping the whole health report. See
[The page says which queue, of what, and how old there](/operate/background-jobs/#the-page-says-which-queue-of-what-and-how-old-there).

`action_health` also carries `backfill_token_usage`: queue a sweep of every transcript on disk into
the token-spend ledger, so `get_costs` covers all of history rather than only spend since ingestion
was deployed. It is the MCP half of an ops action that deliberately has no shell equivalent, it is
not throttled, and it is idempotent — asking twice joins the run already in flight. See
[Token spend](/operate/costs/).

The action tools are verb-multiplexers: `action_session` takes an `action` enum (`follow_up`,
`pause`, `restart`, `archive`, `unarchive`, `fork`, `change_model`, …), `action_trigger` takes
`create` / `update` / `delete` / `toggle` / `invoke`, and so on. `tools/list` carries the full schema for each —
ask the server rather than trusting this table.

`action_trigger` reaches parity with the conditions the triggers form and the REST API can express.
A Trigger ORs its conditions, and a single `trigger_type` + `configuration` pair can only describe
one of them — so a trigger that must fire on more than one thing (a Slack passive listener carrying
both `passive_listen_thread` and `passive_listen_channel`, say) also accepts a `conditions` array of
`{trigger_type, configuration}` objects. The flat pair still works unchanged for the
single-condition case; sending both is rejected rather than guessed at.

On `update`, `conditions` **upserts**: an element with an `id` edits that condition, one without
appends, and an existing condition the array does not mention is left alone. Deleting one is
explicit (`{"id": 123, "remove": true}`). That asymmetry is deliberate — a Slack condition's
`configuration` holds the poller's only copy of its cursors
(`TriggerCondition::SLACK_POLL_STATE_KEYS`), which `preserve_slack_poll_state` keeps by merging back
the keys an incoming configuration omits. Replace semantics would destroy the row and its cursors
with it, silently re-baselining a live trigger. Fetching a trigger by id through `search_triggers`
prints each condition's id, which is what the array addresses.

`action_trigger`'s `invoke` fires a trigger now, without waiting for a condition to match — the MCP
half of `POST /api/v1/triggers/:id/invoke`, and the same fire the **Run Now** button on the trigger
page performs. Pass `variables` to fill in the template's placeholders. The session is linked to the
trigger and counts toward its fire counter, a `disabled` trigger can still be invoked (and is not
re-armed by it), and the trigger's [burst cap](/sessions/triggers/#burst-control) still applies — over
it the tool returns the burst-notice session, or reports that nothing was created. See [firing a
trigger by hand](/sessions/triggers/#firing-a-trigger-by-hand).

`action_session`'s `pause_into_spot_queue` is the MCP half of **Pause Until → Spot Queue** in the web
UI, and the counterpart of `wake_me_up_later` for a session with no time worth naming: it sleeps the
session with no trigger at all and leaves it for the spot scheduler, which resumes it when a Claude
Code account is under both quota targets and a slot is free. It is on the `self_session` surface too,
because a session waiting on quota rather than on an event is exactly the caller for it. See
[Spot and priority](/sessions/spot-and-priority/#joining-the-queue-on-purpose).

One thing differs between the two halves, on purpose. On a *running* session the web UI stops the
turn; the tool lets it finish, because its commonest caller is a session parking itself and a
session that halted itself would kill the process waiting for the reply. Pass `"halt": true` to get
the UI's behaviour when you are driving somebody else's running session. The `self_session` variant
does not expose the option, and strips it from the arguments if it is passed anyway.

`start_session` and `action_session` also take the web UI's *symbolic* queue placement, not just the
integer behind it: `place: "top_of_spot"` is the same server-side resolution the Ranked view's
**Demote to spot** button and the Quick Router's **Run as spot** checkbox perform, mutually exclusive
with `precedence`. It narrows the placement to one request rather than locking the queue. See [Placing something at the head of the
queue](/sessions/spot-and-priority/#placing-something-at-the-head-of-the-queue).

`action_session` reaches full parity with the fields the web UI's session-detail editors expose. Its
config-editing actions — `change_mcp_servers`, `change_model`, `change_skills`, `change_hooks`,
`change_plugins`, `change_goal`, `change_auto_compact_window`, `change_category`,
`toggle_push_notifications` — mirror the inline editors on the session page. List-valued fields
(`mcp_servers`, `skills`, `hooks`, `plugins`) use **replace, not merge** semantics, and every id is
validated against its catalog, so an unknown skill/hook/plugin id is rejected with the valid options
listed rather than persisted (a bad value would otherwise fail AIR prepare on the next unarchive).
Like `change_mcp_servers`, these persist to the session and take effect the next time its runtime
config is prepared — they do not hot-reconfigure a running process. An empty array is a value, not
an absence, on both sides of a session's life: `change_mcp_servers` with `[]` clears the list, and
`start_session` with `[]` launches with none — the same request means the same thing at launch time
and at change time. `start_session` names the same four lists (`mcp_servers`, `skills`, `plugins`,
`hooks`), so a hook that is noise for the task is dropped at launch rather than corrected by a
follow-up `change_hooks` — which, for a clone-only session, would race the job start.

### `start_session` is only safe to retry if you name the attempt

`start_session` takes an optional `idempotency_key`. Generate a fresh UUID and pass it, and the create
becomes safe to repeat: a second call with the same key returns the session the first one made — the
result says so in its heading, *Existing Session Returned (idempotency_key matched)* — and queues no
second agent job. The replayed result also reports whether an agent job is queued on that session, so
a session that was created but never started (a worker killed between the commit and the enqueue) is
visible rather than handed back as though it were running.

Without one, a failed `start_session` is genuinely ambiguous. The 504 a caller sees on a slow create
comes from the reverse proxy, not from Zimmer, so it is an HTML page rather than a JSON-RPC error
envelope, it carries no session id, and it arrives *after* the row has committed. Every observed
occurrence had in fact created a healthy session that went on to run to completion. Retrying that —
the obvious reading of an error — spawns a second clone, a second agent holding a Claude quota slot,
and two agents opening two PRs for one task.

So: **with** a key, retry on any error including a timeout. **Without** one, do not retry — call
`quick_search_sessions` with the title you passed and check whether the session is already there.

Two ways to get the key wrong, both of which end with a session that silently never exists. Do not
derive it from the task, an issue number, or a date: keys share one global namespace, so two routers
that independently build `issue-577-fix` collide. And it is not a fingerprint of the arguments —
reusing a key returns the session it created the first time whatever you pass with the repeat. A
fresh UUID per unit of work avoids both. See [Creating a
session](/extend/rest-api/#idempotency_key--making-the-create-safe-to-retry) for the REST equivalent
and the concurrency guarantee behind both.

Two tools deliver a message to a session that already exists, and both let you choose whether to
interrupt. `action_session` `follow_up` queues the prompt when the session is `running` and sends it
straight through when the session is `waiting` or `needs_input`. `force_immediate: true` interrupts
instead. A `failed` or `archived` session is rejected either way. `manage_enqueued_messages` makes
the same choice by action name: `create` queues, `send_now` stages and interrupts in one step,
`interrupt` promotes a message already in the queue. `action_session` `follow_up` takes an optional
`goal` alongside the prompt, and it means the same thing on all three of its delivery paths: a
non-blank goal becomes the session's new definition of done, a blank or omitted one leaves the
existing goal untouched (use `change_goal` to clear one). `manage_enqueued_messages` takes a `goal`
too, but it is the *message's* goal — `update` with a blank one clears it on the row, and neither it
nor `create`/`send_now` length-check it before the insert. All three interrupt paths run through
`Sessions::InterruptService`, the same backend the web UI's "Send Now" button uses, so they inherit
its per-session advisory lock and exactly-once delivery. An interrupt jumps its own message to the
front of the queue; the messages still pending keep their order behind it.

A queued message is not read until the current turn ends, so a message that would have redirected the
agent arrives after the wasted work is done. What an interrupt costs is one turn: the in-flight
process is terminated, an uncommitted tool call is lost, files already written stay written, and the
next turn resumes the same conversation with the new message appended. Termination is not always
instantaneous — a web process cannot signal a worker-spawned agent across container boundaries, so it
records `interrupt_terminate_pid` and the worker's monitoring loop ends that turn on its next pass.
Queue the additive messages. Interrupt the ones that change the plan.

The two wake-up tools are the ones worth knowing by name. `wake_me_up_later` sleeps the calling
session and creates a one-time trigger that resumes it at a wall-clock time; `wake_me_up_when_session_changes_state`
resumes it when *another* session reaches `needs_input`, `failed`, or `archived`. Together they are how
a session waits on CI, on a deploy, or on a session it spawned, without burning a process on `sleep`.

Two things about them are worth stating because they shape how much a wait costs:

- **`session_id` is optional on both.** The injected entry names the session it was written for, so
  a session waking *itself* — the overwhelmingly common case — just omits it. Pass it only to
  schedule a wake for a different session, where it still wins over the connection's own.
- **`event_names` takes the whole set at once.** One call with
  `["session_archived", "session_needs_input", "session_failed"]` creates **one** trigger with one
  condition per event, so a complete wait is two rows — that watcher plus a `wake_me_up_later`
  deadline backstop — rather than four. The singular `event_name` still works.

And `session_needs_input` no longer fires on a turn boundary the watched session leaves again at
once. Zimmer settles it first, so a wake that reaches you is a session that actually came to rest →
[a turn boundary is not a rest](/sessions/lifecycle/#a-turn-boundary-is-not-a-rest).

### `get_costs`

Reads Zimmer's token-spend ledger: what inference cost, by agent root, model, session, and kind of
token. Fleet-wide by default; pass `agent_root` or `session_id` to scope it, `days` to set the
window.

It lives in `health` rather than `sessions` for the same reason `get_spot_policy` does — this is the
deployment's posture, not one session's business — and it is therefore **not** in the `self_session`
set injected into every session. A session has no reason to read the whole fleet's bill.

Every fleet report states how complete the ledger is: a `Partial history` warning with the sweep's
progress while the one-time historical backfill is still running, and the covered window once it has
finished. An agent comparing this month against last needs to know which of the two it is looking at.

The usual caution applies to anything it returns: the dollar figures are list price on
subscription-billed accounts, so they are a comparable unit across models rather than money owed,
and a model with no configured rate contributes zero and is named explicitly rather than being
folded silently into a total. See [Token spend](/operate/costs/).

## Protocol

The SDK's `StreamableHTTPTransport`, run **stateless** with JSON responses: every POST carries one
complete JSON-RPC message and gets one complete JSON response, so no `Mcp-Session-Id` is issued and
any Puma worker can serve any request. Building the server per request is also what lets one endpoint
serve every scoped variant. `GET /mcp` (server-initiated SSE) and `DELETE /mcp` (session termination)
are 405 — there is no stream and no session to terminate. Batched bodies are rejected, as the spec
requires since 2025-11-25.

The SDK owns version negotiation, the JSON-RPC error codes, and **argument validation**: a
`tools/call` whose arguments don't match the tool's `input_schema` comes back as an error result the
model can correct, before any Zimmer code runs.

`McpController` disables the SDK's DNS-rebinding (`Host`/`Origin`) check. That check defends a
*locally bound* server against a browser; Zimmer is a deployed Rails app whose `config.hosts` already
validates `Host`, and whose credential is an explicit header rather than an ambient cookie.

```mermaid
sequenceDiagram
    participant C as MCP client (Claude Code / Codex)
    participant R as McpController (POST /mcp)
    participant S as MCP::Server (Ruby SDK)
    participant T as Mcp::Tools::*
    participant M as Models / services

    C->>R: initialize (X-API-Key)
    R->>R: Api::BaseController#authenticate_api_key
    R->>S: Mcp::Context(tool_groups, allowed_agent_roots)
    S-->>C: protocolVersion, serverInfo, capabilities.tools
    C->>R: tools/list
    S-->>C: only the tools in the enabled groups
    C->>R: tools/call {name, arguments}
    S->>T: Tool#call(args)
    T->>M: Session / Trigger / Notification / HealthMonitorService …
    M-->>T: records
    T-->>S: markdown text
    S-->>C: content[{type:"text"}], isError
```

A tool that raises `Mcp::ToolError` (bad arguments, missing record, forbidden by scoping) comes back
as a **tool result** with `isError: true` and the message as text — the model reads it and can
recover. A protocol-level problem (unknown method, a tool the connection never advertised) comes back
as a JSON-RPC error, which the model never sees.

## Adding a tool

1. Write `app/services/mcp/tools/<name>.rb`, subclass `Mcp::Tool` (which is an `MCP::Tool` from the
   SDK, plus Zimmer's calling convention), declare `tool_name`, `description`, `input_schema`, and
   implement `#call(args)` (string keys). Return a String (sent as text) or a Hash/Array (sent as
   pretty JSON). Raise `Mcp::ToolError` for anything the model should see and act on. The schema is
   enforced for you — arguments are validated against it before `#call` runs.
2. Call the models and services directly. If the logic already exists behind a service object, call
   it — the MCP layer validates arguments, calls, and formats; it does not own business logic.
3. Register it in `Mcp::Registry::ALL_TOOLS` with its domain group and whether it is a write
   operation. Add `composite_groups: %w[self_session]` if a session should be able to use it on
   itself, and a `composite_overrides` entry if it needs a narrower variant in that group (see
   `action_session`).
4. Test it under `test/services/mcp/tools/`, and let `test/controllers/mcp_controller_test.rb` cover
   the wire shape.
