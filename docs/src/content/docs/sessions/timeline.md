---
title: The Human Timeline
description: An append-only record of what Zimmer knows a named human said to a session — and why absence from it is the point.
sidebar:
  order: 7
---

Every session carries a **Human Timeline**: an ordered, append-only record of the messages
Zimmer *knows* were authored by a named human being.

It exists so an agent can answer "did a human actually ask for this?" as a **lookup** instead
of a judgement. That question comes up constantly — a merge gate deciding whether an
instruction to skip a hold is real, a session recovering the original intent of work that has
been running for days — and until now the only way to answer it was to read the prose of a
`user` turn and guess.

The defining property is **provenance, not content**. A timeline event is recorded only when
Zimmer can establish the authenticated actor at the input boundary. Everything else records
nothing at all.

## Why absence is the whole feature

Almost everything that reaches an agent arrives as a `user`-role turn: a follow-up another
agent session issued over the MCP API, a router-composed downstream prompt, a scheduled
wake-up (including one the session scheduled for itself), a heartbeat nudge, a
post-interruption resumption, a subagent message, a polled GitHub comment. None of those are a
human speaking, and most of them travel the *same delivery path* as a message Tadas types into
the browser.

So the rule is stated once, at the boundary, and nowhere else:

> Capture keys off the **authenticated actor at the input boundary**, never off the text of the
> message.

An event that is wrongly attributed launders automation into authorization, which is worse
than no timeline at all. A missing event is a correct, safe outcome — so when the actor cannot
be established, Zimmer records **nothing**.

## Who counts as a human

`config/human_identities.yml` lists them. Two exist:

| Name | Display | Web UI | Slack |
| --- | --- | --- | --- |
| `tadasant` | Tadas | yes — the only human with browser access | via the Slack ID map |
| `juliehazz` | Julie | no | via the Slack ID map |

Slack user IDs are **deployment configuration, never application source** — the same class of
config as a Slack trigger's `allowed_user_ids`. The file ships with none. A deployment
populates them through the `ZIMMER_HUMAN_SLACK_USER_IDS` secret or env var, resolved through
`SecretsLoader` first and process `ENV` second:

```
ZIMMER_HUMAN_SLACK_USER_IDS="U01ABCDEF:tadasant,U07GHIJKL:juliehazz"
```

Until that is set, no Slack message is attributed to anybody. A pair naming an identity that
isn't in the YAML is dropped rather than inventing an author.

Note that a Slack trigger's `allowed_user_ids` answers a *different* question. "May fire this
trigger" is not "is Tadas or Julie", so the timeline resolves the author independently.

## What is captured, and what is not

| Input | Recorded? | Why |
| --- | --- | --- |
| A new session Tadas creates in the web UI | ✅ `web_ui.new_session` | Zimmer has no login and one human reaches the UI |
| A quick router session he starts himself | ✅ `web_ui.quick_prompt` | same |
| A chat-bubble prompt | ✅ `web_ui.chat_bubble` | his words only — the page-context wrapper is machine-written |
| A follow-up typed in the browser | ✅ `web_ui.follow_up` | same |
| A message enqueued in the browser | ✅ `web_ui.enqueued_message` | recorded when typed, not when delivered |
| A Slack message from a mapped human | ✅ `slack.channel_message` / `slack.dm` | resolved from the Slack user ID |
| `follow_up` / `send_now` / enqueue issued by **another agent** over MCP or REST | ❌ | the API key is shared by the whole fleet — it establishes a caller, not a person |
| A router-written downstream session prompt | ❌ | a router holding a human's words is still a machine when it composes the prompt |
| A scheduled or **self-scheduled** wake-up | ❌ | machine-authored by construction |
| A heartbeat nudge, an `[AUTOMATED SYSTEM MESSAGE - NOT USER INPUT]` resumption | ❌ | same |
| A subagent message | ❌ | intra-session machinery |
| A polled GitHub PR/issue comment | ❌ | see below |

### The GitHub attribution trap

Zimmer records an `attribution` field on polled GitHub comments
(`custom_metadata.github_comments`), and it frequently reads `tadasant`. It is **not** evidence
of a human author: every agent in the fleet pushes through that one shared GitHub account. One
open session alone carries 66 comments attributed to `tadasant`, all of them agent-written.
GitHub comments are artifact text, and they stay out of the timeline.

## Live vs inherited

A session's timeline has two tiers, and the difference matters:

- **`live`** — a human spoke to *this* session. This is what answers "did a human ask for this,
  here?"
- **`inherited`** — a human spoke to an **ancestor** session, and this session was spawned from
  it. Real context about original intent, but **not** an instruction to this session.

Inheritance walks `Session#parent_session` up to five levels at read time rather than copying
rows at spawn. Copying would make the table lie about where an event happened and would freeze
the ancestor's timeline at the moment of the spawn — a human who clarifies intent to a router
five minutes later would never reach the session doing the work.

This distinction is load-bearing. In practice, a router session holds the human's words and the
session doing the work does not, so a strictly per-session timeline would read empty exactly
where the question is being asked. But an inherited event must never be presentable as a live
turn: every rendering — the injected block, the detail screen, the MCP output — marks the tier
explicitly.

To create the spawn edge, pass `parent_session_id` when starting a downstream session. The
`start_session` MCP tool accepts it, as does `POST /api/v1/sessions`.

## Where it shows up

**In the agent's context, every turn.** `AgentSessionJob#build_prompt_with_goal` — the one
prompt builder for both the initial spawn and every follow-up — appends a `<session-timeline>`
block next to `<session-notes>`. Each event renders with its author, provenance, timestamp and
content, and the block states in plain terms that an unlisted user turn was machine-authored.
The newest 25 entries are shown; older ones are counted, not dropped silently. A human's own
words are neutralized against closing the block early.

**On the session detail screen.** A "Human Timeline" panel sits above the transcript, open by
default, with `live` and `inherited` badges, a link to the source session for inherited
entries, and a Slack permalink where there is one. An empty timeline renders an explicit empty
state that explains what absence means, rather than showing nothing.

**Over MCP.** The `get_session` tool includes a `### Human Timeline` section — always, not
behind an `include_` flag. Two reasons: it is small and bounded, and its most important reading
is the empty one. A caller must be able to tell "no human turns" from "I forgot to pass the
flag". `get_session` is in both the `sessions` and `self_session` tool groups, so a session can
ask this about itself with the tools it already has.

## Backfill

There is none. Sessions that existed before this shipped show an empty timeline, which reads
as "no human message was recorded here" — technically true and, for the gating use case, the
safe answer. It does mean a pre-existing session cannot prove a human authorized something;
that authorization has to be re-established live.
