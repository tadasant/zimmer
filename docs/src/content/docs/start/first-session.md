---
title: Your first session
description: Create a session, watch it run, follow up, and understand what the UI is telling you.
sidebar:
  order: 2
---

## Create it

From the UI, or:

```bash
curl -X POST http://localhost:3000/api/v1/sessions \
  -H "X-API-Key: $YOUR_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "agent_root": "general-agent",
    "prompt": "Add a health check endpoint at /healthz that returns 200 OK.",
    "goal": "open-reviewed-green-pr"
  }'
```

What you get back is a session in `waiting`, with an `AgentSessionJob` enqueued.

:::note[A session without a prompt is created but not enqueued]
`POST /api/v1/sessions` only enqueues the job if `prompt` is present. A prompt-less session is a
"clone-only" session — it exists, it can be given a prompt later via `follow_up`, and *that* is what
starts it (`resume` transitions from `waiting`).
:::

## What happens next

Within a minute or so it should flip to `running`. If it doesn't, treat that as a symptom and
see [Expected timings](#expected-timings) below.

While it runs you'll see the timeline stream in over Turbo: user messages, assistant messages,
thinking blocks, tool calls, tool results, subagent accordions. That's the
[transcript pipeline](/sessions/transcripts/) doing its job.

## Follow up

The session pauses to `needs_input` when the agent's turn ends. Send a follow-up:

```bash
curl -X POST http://localhost:3000/api/v1/sessions/$ID/follow_up \
  -H "X-API-Key: $YOUR_KEY" \
  -d '{"prompt": "Also add a test for it."}'
```

Three things can happen, and the status code tells you which:

| Session state | Result | Status |
| --- | --- | --- |
| `needs_input` or `waiting` | delivered immediately, session resumes | `200` |
| `running` | queued as an `EnqueuedMessage`, delivered when the turn ends | `202` |
| `running` + `force_immediate: true` | the process is interrupted and the message delivered now | `200` |

The `202` case is the one that surprises people. A follow-up to a *running* session lines up behind
the current turn instead of interrupting it. Pass `force_immediate` if you mean "stop what
you're doing."

## Reading the UI

The `needs_input` list is your to-do list. That's the design intent — sessions sitting there are
waiting on you, and agents are instructed not to archive themselves out of it while you still need
to read something.

A session showing "blocked on elicitation" is different: the agent process is still alive, and an
MCP server is waiting for you to answer a question. See [Elicitation](/sessions/elicitation/).

## Expected timings

If something takes materially longer than this, the problem is probably the system:

| Operation | Expected |
| --- | --- |
| Session `waiting → running` | ~1 minute |
| GitHub Actions CI (for the agent's PR) | 5–10 minutes |
| Stuck-session auto-recovery | ~15 minutes |
| Catalog refresh (worker) | every 15 minutes |
| Catalog refresh (web) | every 5 minutes |

:::note[If a session sits in `waiting` forever, check that a worker is running]
In production and staging, `execution_mode = :external` means GoodJob needs a separate
`bundle exec good_job start` process. The Kamal deploy runs one as a dedicated `worker` role;
locally, GoodJob runs in-process with Puma, so `bin/dev` is enough.
:::

## If it fails with `oauth_required`

The session went to `failed` because one of its MCP servers needs OAuth and has no valid credential.
The UI will show Authorize buttons. Click through the flow and the session resumes automatically,
replaying the original prompt. See [MCP server OAuth](/auth/mcp-oauth/).

## Useful session controls

| Action | What it does |
| --- | --- |
| **Pause** | `running → needs_input` |
| **Sleep** | Go dormant; a one-time trigger will wake you |
| **Restart** | Re-run from the start; falls back to restart-from-scratch if there's no clone |
| **Fork** | Branch a new session from a specific message index |
| **Refresh** | Re-read the transcript from disk (never shortens the stored one) |
| **Heartbeat** | Auto-nudge this session every N seconds while it's in `needs_input` |
| **Archive** | Move to trash; the clone is reaped after an undo window |

:::caution[The Undo toast doesn't render]
[Issue #12](https://github.com/tadasant/zimmer/issues/12). The archive response never renders the
flash, so there's no Undo button — even though the endpoint works. The undo window is unusable from
the UI.
:::
