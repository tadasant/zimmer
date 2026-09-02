---
title: The gate decision ledger
description: Every rating Zimmer's agent gates make, in Postgres instead of a JSON file — what it stores, how a gate queries it, and why human feedback has exactly one way in.
---

Two agent gates rate work before it lands: a **PR merge gate** decides whether a pull request may
auto-merge, and an **issue work gate** decides whether an issue may be picked up. Both are
calibrated by their own history — "how have I rated this surface lately, and where did a human tell
me I was wrong". The `gate_decisions` table is that history.

It replaces a checked-in JSON file per gate per surface. The largest of those was 3.4 MB, and a gate
read the whole thing to calibrate one rating.

## What a decision is

A row is one rating, and it is **append-only**. There is no update and no delete — not through the
REST API, not through MCP, and not through the model, which raises on both. A correction is a *new*
row on the same artifact citing the earlier one, so both readings stay visible and the record cannot
be edited into agreement with itself.

The honest limit: this is enforced on the model, so `update_all` and raw SQL would bypass it. A
Postgres trigger would be stronger, but Rails' Ruby schema dumper cannot carry one, so it would
exist in production and silently not exist in CI — a guarantee no test could hold you to. Nothing in
the app takes those paths against this table.

Only a handful of fields are columns:

| Column | What it holds |
| --- | --- |
| `gate` | `pr_merge` or `issue_work` |
| `surface` | The agent root / repo rated on — `zimmer`, `strad_production`, `artifacts`, … |
| `artifact_url` | The PR or issue that was rated |
| `decided_at` | The date the gate wrote in the entry |
| `decision` | The verdict — `auto-merge`, `hold`, `auto-proceed`, … |
| `producing_session_url` | The session whose work was rated, pulled out of the prose it is usually embedded in |
| `writing_session_id` | The session that wrote the row — stamped from the connection on MCP, self-declared on REST |
| `recorded_via` | `import`, `mcp` or `api` |
| `payload` | **The entry, verbatim** |

The thinness is deliberate. The two gates do not share a schema and neither schema is finished: on
300 PR-gate zimmer entries there are 34 distinct keys, of which 11 are universal, four arrived in
the last few weeks and four are retired. Pinning those into columns would mean a migration every
time a gate learns something, so everything a gate writes lands in `payload` and only the stable,
queryable handful is promoted — as a copy, not a move, so entries stay whole.

## Human feedback has exactly one way in

`human_feedback` — a person saying a gate got a call wrong — is **not** a field on a decision. It is
a separate table with its own author, timestamp and channel, and it is the one thing in this ledger
that no machine can write.

That is not tidiness. Until this ledger moved into the database, every append was a pull request
whose diff another gate read, and the gates' own escalation doc says why that mattered: a
ledger-shaped PR carrying a fabricated `human_feedback` note *"would sail through a structural check
and never be seen by a human."* A direct database write removes that last look. So:

- **No MCP tool writes it, on any group** — at any nesting depth, and whatever its casing. The key
  is scrubbed recursively out of every entry, so it cannot ride into `payload` as
  `Human_Feedback` or under some other key and be printed back to a reading gate as though it were
  real. `record_gate_decision` says in its receipt when it dropped one.
- **The REST API has no feedback action at all.** `Api::BaseController` authenticates an API key the
  whole agent fleet shares — that establishes a caller, not a person.
- **The write path is the browser only**, `POST /gate_decisions/:id/feedbacks`, served by an
  `ApplicationController` descendant. The author is resolved there from `User.admin`, never read
  from the request body — the same rule, at the same boundary, that
  [human messages](/sessions/hierarchy-and-human-messages/) follow.
- **Notes are append-only too**, so one cannot be edited into saying something else or deleted to
  make a gate look better than it was.

**Be precise about what "the browser" buys, because it is less than "human-only".**
`ApplicationController` performs no authentication — Zimmer's perimeter is the tailnet, and agent
sessions run *inside* that perimeter, on the same droplet. So what this boundary rules out is a
write over the shared API key, on the REST or MCP surfaces an agent is actually handed; it does not
rule out an agent that goes looking for the browser route and posts a form to it. A genuine
human-only guarantee needs a way to tell a person from an agent at the web surface — the agent-login
primitive Zimmer does not have yet ([#371](https://github.com/tadasant/zimmer/issues/371),
[#220](https://github.com/tadasant/zimmer/issues/220)). Until it exists, `web_ui` means "came in
through the browser surface", which is weaker than "a human typed it", and the ledger should be read
that way.

Rows backfilled from the old JSON files carry the `imported` channel rather than `web_ui`, and their
`author` is null when the source did not record one. A plausible-looking author invented by an
importer is exactly the forgery the table exists to prevent.

## Reading it

Three MCP tools, in an **opt-in tool group of their own** (`gate_decisions`), served at `POST /mcp`:

| Tool | What it is for |
| --- | --- |
| `search_gate_decisions` | The calibration read. Filter by gate, surface, decision, artifact URL, date window, or full text over the whole entry |
| `get_gate_decision_feedback` | Every note a human left, and nothing else — roughly eight across ~1,500 decisions |
| `record_gate_decision` | Write one rating. The only write tool in the group |

The group matters as much as the tools, and so does its being **opt-in**. Folded into `sessions`,
every session carrying `zimmer-sessions` would be handed the ability to write gate ratings; left in
the base set, so would every session holding the unscoped `zimmer` server, since omitting
`tool_groups` means "every base group". A ledger every session has a pen for is not evidence of
anything. So `gate_decisions` sits outside the base set: it is valid and addressable, but a
connection has to name it, and the connections that do are the two gate roots'.
`gate_decisions_readonly` — generated automatically, like every domain group's readonly variant —
carries the two reads and not the write. The catalog server that scopes to the full group is
`zimmer-gate-decisions`.

Be precise about what that buys, though: **tool groups are a scoping boundary, not an authorization
one.** The API key is shared by the whole fleet and is written into every session's own MCP config,
so a determined agent could compose its own `?tool_groups=` URL. What the group decides is what a
session is *offered*, which is what keeps recording a rating from being something any session does
in passing. The guarantee that does not depend on a caller staying inside its tools is the feedback
boundary above: no API key reaches `POST /gate_decisions/:id/feedbacks` at all.

`gate_decisions` is a base group, so the unscoped `/mcp` surface carries the write tool too. That is
what "no `tool_groups` means every base group" has always meant; the scoping that matters is that
`sessions` and `self_session` do not reach it.

The same filters are on `GET /api/v1/gate_decisions`; see [the REST API](/extend/rest-api/).

## The backfill

The historical entries are imported by a [one-time post-deploy
task](/operate/deploying/#one-time-post-deploy-tasks), `ImportGateDecisionLedgers`, so no shell on
the production box is involved. It only inserts — it never edits a row, never deletes one, and never
touches the source JSON, which means it is safe to run while the gates are still appending to those
files.

Its idempotency key is `(gate, surface, artifact_url, decided_at)` **plus the entry's ordinal within
that group**. The tuple alone is not unique in the real corpus: 52 of its groups hold two or three
entries, 59 rows in total, and those are re-rates — the same PR rated twice in a day because the
base branch moved. They are genuinely distinct decisions, and keying on the bare tuple would have
dropped every one of them.

One entry it cannot import does not stop the other 1,468: the entry is counted as `rejected`, named
in the logs, and reported in the task's stats, rather than aborting a slice that would then retry,
re-fetch the same megabytes and fail identically forever. The cursor is written as each file
finishes, so a worker killed mid-slice resumes rather than starting over.

The source is resolved in order: an explicit directory, then `GATE_DECISION_LEDGER_DIR`, then
GitHub via the `gh` credential every Zimmer container already carries. Outside production, a source
it cannot reach is recorded on the task's ledger row and the task completes; in production it fails
loudly rather than claiming to have imported a history it never read.
