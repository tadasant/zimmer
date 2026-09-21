---
title: Zimmer plugins
description: An app outside Zimmer whose key can invoke a few chosen triggers, with template variables, and nothing else — enforced on the server. The MCP and REST contract, and how to register one.
sidebar:
  order: 7
---

A Zimmer plugin is an app outside Zimmer that is allowed to start work in it, narrowly. You
register the app, tick the triggers it may invoke, and mint it a key. With that key the app can list
those triggers and invoke one with [template variables](/sessions/triggers/#prompt-template-variables).
It cannot do anything else.

The first one is a housing-search MCP app. Its listings have a **Kick off vetting** button, and
pressing it invokes the vetting trigger with the listing in `{{text}}`. The trigger spawns a Zimmer
session that researches that listing. Selecting several listings fires one invoke each.

Not to be confused with a [catalog plugin](/air/artifacts/#plugins), which bundles skills, MCP servers and
hooks into a session. In the code a Zimmer plugin is an **external app** (`ExternalApp`,
`external_apps`), so the two cannot be mixed up there.

## Why it is a separate credential

An ordinary API key has a name but no scope. The [MCP server's](/extend/mcp-server/) `tool_groups`
and `allowed_agent_roots` live in the URL, so anyone holding a key can widen them, or skip MCP and
call `/api/v1` directly. Inside the deployment's circle of trust that is fine. A plugin's key is
outside it: it sits in a third-party gateway or an app's config. If it leaks, it must not be able to
start arbitrary sessions, read transcripts or touch other triggers.

So a plugin's limits are enforced on the server, not suggested by a URL:

- **A plugin key is an `ApiKey` with the `external_app` grant.** `ApiKey.authenticate` matches a
  grant exactly, and every REST controller and `POST /mcp` ask for `api`. A plugin key therefore
  gets `401` from every other route, whatever URL or `tool_groups` it tries. The test suite walks the
  route table and checks every `/api` and `/mcp` route against a plugin key, so a route added later
  is covered too.
- **Two surfaces take that grant, and only that grant:** `POST /mcp/external_app` and
  `/api/v1/external_app/...`. A full-API key gets `401` there.
- **They reach only the plugin's allowlist, and only while the plugin is enabled.** A trigger that is
  not on the list gets exactly the answer a trigger that does not exist gets, so a key cannot be used
  to find out what else the deployment has. A disabled plugin gets `403` on every request, without
  its keys being revoked.
- A plugin key always belongs to exactly one plugin, and only a plugin key belongs to one. The model
  enforces that, and so does a database check constraint.

## Register a plugin

**Web UI:** **Settings → Zimmer plugins** (`/settings/plugins`).

1. **Register** it with a name and, optionally, what it is. The name is stamped on every session it
   starts.
2. On its page, tick **Triggers it may invoke** and **Save**. Each row shows the template variables
   the trigger uses and its per-minute cap. Workflow triggers take no variables and are not offered.
3. **Create key**. Copy it straight away. Zimmer keeps only a digest, so it is shown once.

To rotate a key, create a new one, move the app onto it, then revoke the old one. Untick
**Enabled** to switch the plugin off without touching its keys. **Delete plugin** removes it, its
allowlist and its keys. Sessions it started are kept.

**MCP:** the opt-in `external_apps` tool group, `POST /mcp?tool_groups=external_apps` (catalog
entry `zimmer-external-apps`), with a full-API key:

- `search_external_apps` — every plugin with its allowlist and keys (never a secret). Takes `id` or
  `query`.
- `action_external_app` — `create` (`name`, optional `description`, `enabled`, `trigger_ids`),
  `update` (`id` plus any of those; `trigger_ids` **replaces** the allowlist), `delete` (`id`),
  `mint_key` (`id`; returns `key.secret`, shown once) and `revoke_key` (`id`, `key_id`).

```json
{ "action": "create", "name": "Housing search", "description": "Vets listings", "trigger_ids": [42] }
{ "action": "mint_key", "id": 1 }
```

The group is opt-in because `action_external_app` hands out credentials. Minting over MCP is still
allowed, unlike [API keys](/auth/overview/#managing-keys). A plugin key reaches a subset of what the
caller's own key already reaches (invoking triggers), so minting one widens nothing. The secret does
land in the calling session's context. `TranscriptRedactor` masks the `zmr_` shape in the stored
transcript, but treat the session as having seen it.

Every change leaves a WARN `[external_app]` audit line, from either surface.

## The plugin's contract

This is what an app or gateway holding a plugin key builds against.

### Auth

The key goes in `X-API-Key: <key>` or `Authorization: Bearer <key>`. Keys look like `zmr_` followed
by 64 hex characters.

| Response | Meaning |
| --- | --- |
| `401` | No key, an unknown or revoked key, a deleted plugin's key, or a key that is not a plugin key |
| `403` | The plugin is disabled |

### MCP: `POST /mcp/external_app`

Streamable HTTP, stateless, plain JSON responses, the same transport as [`/mcp`](/extend/mcp-server/#protocol).
Query parameters are ignored: `?tool_groups=` changes nothing here. `tools/list` returns exactly two
tools.

**`list_triggers`** — no arguments. Returns (as JSON text content):

```json
{
  "external_app": { "id": 1, "name": "Housing search", "description": "Vets listings" },
  "triggers": [
    { "id": 42, "name": "Vet a listing", "variables": ["text"], "max_sessions_per_minute": 40 }
  ]
}
```

`variables` are the placeholders the trigger's template uses. The template itself is never
returned, and neither are the agent root and equipment. `max_sessions_per_minute` is `null` when the
trigger has no cap.

**`invoke_trigger`** — `trigger_id` (integer, required) and `variables` (object, optional). The
known variable names are `link`, `text`, `author`, `channel`, `event`, `repo`, `number`, `title`,
`labels` (a string or an array), `channel_id`, `message_ts`, `thread_ts` and `author_id`. A placeholder
the template uses but you omit renders empty. An unknown name, or a value over 10,000 characters,
is refused. Returns:

```json
{
  "outcome": "fired",
  "fired": true,
  "message": "Trigger \"Vet a listing\" fired manually. Session created.",
  "trigger": { "id": 42, "name": "Vet a listing" },
  "session": { "id": 5150, "status": "waiting", "url": "https://zimmer.example.com/sessions/5150" }
}
```

Any outcome other than `fired` comes back as a tool error (`isError: true`) with the same JSON.

### REST: `/api/v1/external_app`

The same two operations with the same bodies:

```bash
curl https://zimmer.example.com/api/v1/external_app/triggers -H "X-API-Key: zmr_…"

curl -X POST https://zimmer.example.com/api/v1/external_app/triggers/42/invoke \
  -H "X-API-Key: zmr_…" -H "Content-Type: application/json" \
  -d '{"variables": {"text": "listing-8812"}}'
```

A refusal also carries the API's usual `error` / `message` / `messages` keys.

### Outcomes

| `outcome` | REST | What happened |
| --- | --- | --- |
| `fired` | `201` | The session was created, or a reuse trigger's session followed up. `session` is it |
| `burst_notice` | `429` | The trigger went over its per-minute cap. `session` is the one burst-notice session it spawned instead; the session you asked for was **not** created |
| `burst_suppressed` | `429` | The trigger is inside a burst. Nothing was created |
| `pending_session` | `409` | The trigger has `skip_if_pending_session` on and a session it spawned is still pending. `session` is that one |
| `not_reusable` | `422` | A one-time reuse trigger whose target session is gone. Nothing fired |
| `not_found` | `404` | No trigger with that id is on this plugin's allowlist |
| `invalid_variables` | `422` | An unknown variable name, or a value that is too long |
| `not_invokable` | `422` | The trigger now runs a workflow, so it takes no variables |

## Batches and the burst cap

Invoking works like the trigger's Invoke button ([Firing a trigger by hand](/sessions/triggers/#firing-a-trigger-by-hand)):
the same `Triggers::ManualFire`, the same burst cap, the same reuse behaviour. A **disabled**
trigger can still be invoked, because `status` governs its own conditions, not callers.

A multi-select sends one invoke per item. Two trigger settings decide how that goes:

- **`max_sessions_per_minute`.** The cap counts fires in a one-minute window, whoever fires them.
  Past it, the first extra fire spawns a single burst-notice session and every later one is
  suppressed until five minutes after the trigger last went over. A 30-listing batch against a
  trigger capped at 10 creates 10 sessions and one notice, and the other 19 come back
  `burst_suppressed`. For a trigger a plugin batches into, set the cap a little above the largest
  batch you expect (say 40), or leave it empty. An empty cap also means a leaked key has no rate
  limit other than the allowlist.
- **`skip_if_pending_session`** must be **off**. With it on, the second invoke in a batch comes back
  `pending_session` while the first session is still running.

A reuse trigger routes every invoke into the same session, as follow-ups. For per-item work, use a
trigger that spawns a new session each time.

## Where a session came from

A session a plugin creates has genesis `api` and carries the plugin in its metadata:

```json
{ "trigger_id": 42, "trigger_name": "Vet a listing", "external_app_id": 1, "external_app_name": "Housing search" }
```

A session started by the Invoke button has genesis `web_ui` and no `external_app_*` keys, so the two
can be told apart. `quick_search_sessions` matches metadata, so searching the plugin's name finds its
sessions. The plugin's settings page lists the most recent ones, and `last_invoked_at` says when it
last invoked anything. Invokes are logged as `[external_app] "Housing search" (external_app_id=1)
invoked trigger 42 …`. A refusal is logged at WARN, so it ships to obs.

Two kinds of session carry no plugin stamp: the burst-notice session, which is not the work that was
asked for, and a reuse trigger's follow-up, which lands in a session that already existed. See
[the limitation](/limitations/#a-zimmer-plugins-follow-up-into-a-reused-session-is-not-stamped).
