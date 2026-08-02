---
title: Hierarchy and human messages
description: The spawn tree a session belongs to, and the record of what Zimmer knows a named human said in it — and why absence from that record is the point.
sidebar:
  order: 7
---

Two related things, kept deliberately apart.

**Session hierarchy** is the lineage graph: the origin session at the root, every descendant below
it, and any session that queued or interrupted one of them. **Human messages** are the messages
Zimmer *knows* were authored by a named human, each attached to the session where they were actually
said, and gathered across that whole graph.

Together they let an agent answer "did a human actually ask for this?" as a **lookup** instead of a
judgement it makes by reading the prose of a `user` turn.

## Session hierarchy

There are two kinds of edge, and they mean different things.

A **spawn** edge means "A spawned B". It does *not* mean "most recently talked to" — a session is
routinely followed up by a router other than the one that spawned it, and reading a spawn edge that
way would be wrong. Each session is spawned exactly once, so the spawn edges alone form a tree.

An **uncle** edge means "A inspected B and decided to queue or interrupt it". The premise is that a
session which read another's state and chose to redirect it holds information that session does not
— so it is senior: an additional parent, sibling to the spawn parent, hence "uncle". A session can
collect several over its life, and an uncle can sit in a hierarchy the junior was never spawned into,
so the combined graph is a **DAG**, not a tree.

The graph is traversable in both directions: a session's seniors up to its roots, and every
descendant below. That matters because a human's instruction often lands on a *sibling* — the router
spawns two workers and clarifies intent to one of them — or on a session that only later reached in
to interrupt this one.

### Where each edge lives

The spawn edge is the first-class `parent_session_id` column. Both `POST /api/v1/sessions` and the
`start_session` MCP tool accept it, so a router can record the edge as it spawns.

Sessions spawned before that was wired recorded the same fact in `custom_metadata` as
`router_session_id`. The tree is **derived** from both — the column first, that key as a fallback
(`Session#lineage_parent_id`). Deriving rather than migrating is deliberate: it needs no backfill, it
is reversible, and it never rewrites what a session recorded about itself. An expression index on
`custom_metadata->>'router_session_id'` keeps the downward walk from becoming a sequential scan.

Uncle edges live in their own table, `session_uncle_links` (`session_id` → `uncle_session_id`, plus
the `source` entry point that recorded it). A separate table rather than a second column because a
session can have several uncles and there is no principled way to pick one to keep. Both foreign keys
are `ON DELETE CASCADE`, which is where they differ from `parent_session_id`'s `SET NULL`: nulling a
parent pointer leaves a meaningful row (a session with no recorded parent), while nulling either end
of an edge leaves a row that asserts nothing.

### Who writes an uncle edge — and why the caller must declare itself

`Sessions::RecordUncleEdge` is the only writer, called from the session-initiated queue/interrupt
paths: `action_session` `follow_up` and `manage_enqueued_messages` `create` / `send_now` / `interrupt`
over MCP, and `POST /api/v1/sessions/:id/follow_up` plus the enqueued-message `create` / `interrupt`
over REST.

**The acting session is self-declared**, via an `acting_session_id` parameter. That is not laziness;
it is the only thing available. Nothing about the request identifies the caller: one API key is shared
by the whole fleet, so it establishes a caller but not a session, and the MCP endpoint's scoping
(`tool_groups`, `allowed_agent_roots`) is per-connection — the self-session server injected into every
session is byte-identical across all of them. Omitting `acting_session_id` records nothing, which is
the right answer for a human with a curl command or an MCP client.

Read an uncle edge as **a claim of seniority, not proof of one**. See
[Limitations](/limitations/) for what that means for provenance.

**A human is never an uncle.** A person clicking "Send Now" or interrupting from the browser has no
session on the other end. The web UI controllers have no `acting_session_id` at all — the guarantee is
structural, not a flag those paths are trusted to set correctly.

### The rules, including inversion

When session A queues or interrupts session B:

| Case | What happens |
| --- | --- |
| A is B | Nothing. A session messaging itself says nothing about lineage. |
| A can already reach B going down (spawn ancestor, or an existing A → B uncle edge) | Nothing. The graph already asserts what the edge would. |
| An uncle edge **B → A** exists — A was the junior | **Inverted.** B → A is deleted and A → B is written. An uncle edge is a claim about who holds the better information *now*, and the newer act of inspection supersedes the older one. Replacement, not addition: keeping both would assert a two-cycle, in which each session is senior to the other. |
| B is A's **spawn** ancestor — a child calling back into its parent | Nothing, and `parent_session_id` is never touched. B *did* spawn A; that is history, and a graph that rewrites it lies about something that happened. Nothing is lost by declining — A and B already share one hierarchy, so both consumers of the graph already show everything the inverted edge could add. |
| B is senior to A two or more hops away | Refused. Only the *direct* uncle edge inverts; unwinding a longer chain would mean deleting an edge neither session is party to. |
| Otherwise | A → B is written. |

Those rules are the acyclicity invariant: an edge A → B is written only when B cannot already reach
A, so **no sequence of calls can construct a cycle**. Two details make that hold rather than merely
sound true. Inversion re-checks reachability *after* removing the direct edge and rolls the whole
thing back if the target is still senior by a longer path — otherwise A → B → X → A would be
constructible from four individually-legal calls. And the reachability search is bounded by a node
budget (5,000 sessions visited), not by `MAX_DEPTH`: a depth-bounded check would answer "no cycle"
for any path longer than eight hops and let one through, and uncle edges accumulate across unrelated
hierarchies, so long paths are ordinary. Past that node budget the guarantee lapses to the
traversal's own `seen` guards, which stop a cycle from hanging a render but do not prevent one.

An edge is a record *about* a delivery, never a precondition of it. If recording fails, the follow-up
still lands and the failure is logged.

### Origin, and roots

`origin` is the root of the **spawn** chain, and stays single-valued. It is deliberately blind to
uncle edges: spawning happened once and cannot change, whereas an origin computed over uncle edges
would move every time some other session interrupted this one, and "where did this session come from"
would stop having a stable answer.

`roots` is plural — every root reached by walking up *both* edge kinds. That is what pulls an uncle's
whole hierarchy into view, which is the entire point: the senior that interrupted you usually holds
the human context you need. The spawn origin always leads the list, so an ordinary single-parent
hierarchy renders exactly as it did before uncle edges existed.

Because a session can now be reached by more than one path, the downward walk is breadth-first and
each session is rendered **once, at its shallowest depth**.

### Depth and cycles

The walk is bounded twice: `MAX_DEPTH` of 8 levels and `MAX_NODES` of 150 sessions. Deep enough for
the shapes that actually occur (router → worker → helper, plus a gate session spawned off a worker),
shallow enough that a cycle or a router that has spawned hundreds of sessions cannot turn a detail
page into a fleet-wide render. Both bounds apply to the **upward** walk too, because uncle edges mean
"up" fans out rather than forming a chain. The walk tracks visited ids, so a cycle terminates rather
than looping — a backstop, since `RecordUncleEdge` refuses to create one, but a bound that assumes
every writer was correct is not a bound.

When either bound is hit, the reader is told: the UI shows an amber "Showing at most 150 sessions, 8
levels from the highest ancestor reached. This tree is larger." and the MCP and REST responses carry
the same note (`truncated: true` in JSON). The session you asked about is always included, even if the ceiling cut the branch it
lives on — a page that omits the session you are looking at is worse than one that admits it is
truncated.

## Human messages

The defining property is **provenance, not content**. A record exists only when Zimmer can establish
the authenticated actor at the input boundary. Everything else records nothing at all.

### Why absence is the whole feature

Almost everything that reaches an agent arrives as a `user`-role turn: a follow-up another agent
session issued over the MCP API, a router-composed spawn prompt, a scheduled wake-up (including one
the session scheduled for itself), a heartbeat nudge, a post-interruption resumption, a subagent
message, a polled GitHub comment. None of those are a human speaking, and most of them travel the
*same delivery path* as a message Tadas types into the browser.

So the rule is stated once, at the boundary, and nowhere else:

> Capture keys off the **authenticated actor at the input boundary**, never off the text of the
> message.

A wrongly-attributed record launders automation into authorization, which is worse than having no
record at all. So when the actor cannot be established, Zimmer records **nothing**.

### Who counts as a human

The `users` table lists them — a hand-seeded roster, not authentication. Zimmer has no signup and no
login; rows exist so that when Zimmer establishes *who* spoke at an input boundary, it has something
durable to attribute the words to. Two rows ship, inserted by the migration that creates the table:

| `key` | `display_name` | `email` | `slack_user_ids` | `notes` |
| --- | --- | --- | --- | --- |
| `tadasant` | Tadas | `tadas@tadasant.com` | set per deployment | who he is, injected into every prompt |
| `juliehazz` | Julie | `julie@tadasant.com` | set per deployment | same |

`key` is the stable identity string. `HumanMessage#author` stores it verbatim — not a foreign key —
because those records are immutable evidence and must not depend on the roster staying exactly as it
is. A key that no longer resolves still renders what the human said and who they were; it simply
stops naming a person. The practical consequence: **renaming a key orphans every message that human
already authored.**

Slack user IDs are **deployment configuration, never application source** — the same class of config
as a Slack trigger's `allowed_user_ids`. This repository is public, so the seeded rows ship with an
empty list and a deployment fills them in at `/supervisor/users`. Until then, no Slack message is
attributed to anybody. An ID that belongs to no row resolves to nobody rather than inventing an
author, and one ID cannot belong to two humans (the model rejects the collision, which would
otherwise make an author depend on row order).

A Slack trigger's `allowed_user_ids` answers a *different* question. "May fire this trigger" is not
"is Tadas or Julie", so the author resolves independently.

The roster is editable **only** from the Supervisor panel, which sits behind the HTTP Basic realm. No
MCP tool reads or writes it, and that asymmetry is deliberate rather than an oversight: `users` is the
authority on who counts as a human, so an agent that could add a Slack ID or rename a key could
manufacture the human authorship the record exists to make unforgeable. Agents get the roster's
context — display names and `notes` — delivered to them in the block below, and no way to change it.

`email` is a linkage, not yet a capture path. Nothing attributes a message from it. A session's
`auth_identity_email` in metadata often reads `tadas@tadasant.com`, but that names the pooled Claude
login the *agent process* was spawned with — a machine's credentials, not the person who typed — so
attributing from it would claim a human asked for something every time an agent ran. If Zimmer ever
grows real per-human login, the request's authenticated email is what would resolve through
`User.for_email`, at the boundary, from the actor.

### Who is the admin

Exactly one human is responsible for anything typed into the Zimmer web UI. `ZIMMER_ADMIN_USER`
names them by `key`, resolved through `SecretsLoader` first and process `ENV` second; unset, it
falls back to the hardcoded `tadasant`, which is what a single circle of trust actually looks like.

The value is a key that must resolve to a real row. A `ZIMMER_ADMIN_USER` naming nobody — a typo, a
deleted row — makes `User.admin` return `nil`, and web-UI capture then records **nothing** rather
than guessing. That is the safe direction, and it is the same assertion the old `web_ui: true` flag
made: not a permission check, a statement about who can reach the browser.

### What the roster knows about a human

`notes` is free-form context an operator writes at `/supervisor/users` — who this person is, whose
word is final. It is not decoration: every human-messages block Zimmer builds for an agent turn
carries a `<people>` section describing the humans who actually speak in it, so a session weighing
"may I do this?" can see who is asking and not only what was asked.

The section describes each human once, only when a note exists, and only for humans present in the
messages shown. Notes are sanitized exactly like message content and session titles — a roster edit
must not be able to close the block and forge a `here` message.

### What is captured, and what is not

| Input | Recorded? | Why |
| --- | --- | --- |
| A new session Tadas creates in the web UI | ✅ `web_ui.new_session` | Zimmer has no login and one human reaches the UI |
| A quick router session he starts himself | ✅ `web_ui.quick_prompt` | same |
| A chat-bubble prompt | ✅ `web_ui.chat_bubble` | his words only — the page-context wrapper is machine-written |
| A follow-up typed in the browser | ✅ `web_ui.follow_up` | same |
| A message enqueued in the browser | ✅ `web_ui.enqueued_message` | recorded when typed, not when delivered |
| A Slack message from a mapped human | ✅ `slack.channel_message` / `slack.dm` | resolved from the Slack user ID |
| `follow_up` / `send_now` / enqueue issued by **another agent** over MCP or REST | ❌ | the API key is shared by the whole fleet — it establishes a caller, not a person |
| A router-written spawn prompt | ❌ | a router holding a human's words is still a machine when it composes the prompt |
| A scheduled or **self-scheduled** wake-up | ❌ | machine-authored by construction |
| A heartbeat nudge, an `[AUTOMATED SYSTEM MESSAGE - NOT USER INPUT]` resumption | ❌ | same |
| A subagent message | ❌ | intra-session machinery |
| A polled GitHub PR/issue comment | ❌ | see below |

Records are **read-only** on every surface: `HumanMessage` raises `ActiveRecord::ReadOnlyRecord` on
update and on a direct destroy, and there is no create/edit path in the UI, the API, MCP, or the
Supervisor dashboard. That is what makes them admissible as authorization evidence — a record you can
edit afterwards to say a human asked for something is worth nothing.

### The GitHub attribution trap

Zimmer records an `attribution` field on polled GitHub comments (`custom_metadata.github_comments`),
and it frequently reads `tadasant`. It is **not** evidence of a human author: every agent in the fleet
pushes through that one shared GitHub account. One open session alone carries 66 comments attributed
to `tadasant`, all of them agent-written. GitHub comments are artifact text, and they stay out.

### Here vs elsewhere

Every rendering marks which of two a record is:

- **`here`** — a human spoke to *this* session. This is what answers "did a human ask for this,
  here?"
- **`elsewhere`** — a human spoke to another session in the same hierarchy. Real context about
  original intent, but **not** an instruction to this session.

This distinction is load-bearing. In practice a router session holds the human's words and the
session doing the work does not, so gathering only this session's records would read empty exactly
where the question is being asked. But an `elsewhere` record must never be presentable as a turn in
this session: `SessionHumanMessages#human_message_here?` answers that question directly and returns
`false` when only `elsewhere` records exist.

## Where they show up

**In the agent's context, every turn.** `AgentSessionJob#build_prompt_with_goal` — the one prompt
builder for both the initial spawn and every follow-up — appends a `<session-hierarchy>` block and a
`<human-messages>` block next to `<session-notes>`. Each message renders with its author, provenance,
timestamp, content and the session it was authored in, and the block states in plain terms that an
unlisted user turn was machine-authored. The newest 25 are shown; older ones are counted, not dropped
silently. A human's own words are neutralized against closing the block early.

**On the session detail screen.** Two of the four sections in the page's panel group — below
[Status](/sessions/status-summary/) and above the collapsed Transcript. The hierarchy renders the tree as
indented nodes, each showing the session's agent root and title, each a link through to that
session's detail page, with the current session marked and not linked to itself. Below it, the human
messages, badged `this session` or `elsewhere`, with a link to the authoring session and a Slack
permalink where there is one. An empty record renders an explicit empty state explaining what absence
means, rather than showing nothing.

The panel header states **both** counts, always — `3 messages in this session · 0 elsewhere in the hierarchy`.
A header that named only the first would describe a narrower search than the one that ran, and a
reader would have no way to tell "nothing was said elsewhere" from "elsewhere was never looked at".
The prompt block and `get_session` state the same pair whenever there is anything to state, so all
three agree. (REST is deliberately different: `human_messages` is a bare array carrying each entry's
`origin`, and a client derives the counts it wants.)

The counts name the hierarchy, so when the walk was cut by `MAX_DEPTH` or `MAX_NODES` all three say
so — the panel appends *(truncated tree — not every session was searched)*, and the prompt block and
`get_session` call the elsewhere count a floor rather than a total. A count that names the whole tree
while the query searched part of it is the same over-claim in the other direction.

**Over MCP.** `get_session` includes a `### Session Hierarchy` section and a `### Human Messages`
section — always, not behind an `include_` flag. Two reasons: they are small and bounded, and the
most important reading of the message record is the empty one. A caller must be able to tell "no
human turns" from "I forgot to pass the flag". `get_session` is in both the `sessions` and
`self_session` tool groups, so a session can ask this about itself with the tools it already has.

**Over REST.** `GET /api/v1/sessions/:id` returns `session_hierarchy` and `human_messages` as
top-level keys beside `session`, never inside it — `session` means one shape on every response that
carries it, and these cost queries the index would otherwise pay once per card.

## Backfill

There is none for human messages. `human_messages` starts empty, so every session that existed before
this shipped shows no human messages, which reads as "Zimmer has no record here" — technically true
and, for the gating use case, the safe answer. It does mean a pre-existing session cannot prove a
human authorized something; that authorization has to be re-established live.

The spawn hierarchy is different, and deliberately so: it is **derived** rather than backfilled, so
pre-existing sessions show their real trees immediately, reconstructed from the
`custom_metadata.router_session_id` they already recorded. No migration rewrites any row.

Uncle edges have nothing to derive and nothing to backfill: they are recorded as queue/interrupt
calls happen, so `session_uncle_links` starts empty and every hierarchy renders exactly as it did
before until a session declares itself on a follow-up. The derivation of the spawn edge is untouched
by this — the new table sits alongside it rather than replacing it.
