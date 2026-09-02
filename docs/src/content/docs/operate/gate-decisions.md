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
REST API, not through MCP, not in the model. A correction is a *new* row on the same artifact citing
the earlier one, so both readings stay visible and the record cannot be edited into agreement with
itself.

Only a handful of fields are columns:

| Column | What it holds |
| --- | --- |
| `gate` | `pr_merge` or `issue_work` |
| `surface` | The agent root / repo rated on — `zimmer`, `strad_production`, `artifacts`, … |
| `artifact_url` | The PR or issue that was rated |
| `decided_at` | The date the gate wrote in the entry |
| `decision` | The verdict — `auto-merge`, `hold`, `auto-proceed`, … |
| `producing_session_url` | The session whose work was rated, pulled out of the prose it is usually embedded in |
| `writing_session_id` | The session that wrote the row, stamped server-side |
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

- **No MCP tool writes it, on any group.** `record_gate_decision` silently drops the key if you send
  it, and says so in its receipt.
- **The REST API has no feedback action at all.** `Api::BaseController` authenticates an API key the
  whole agent fleet shares — that establishes a caller, not a person.
- **The write path is the browser**, `POST /gate_decisions/:id/feedbacks`, served by an
  `ApplicationController` descendant. The author is resolved there from `User.admin`, never read
  from the request body — the same rule, at the same boundary, that
  [human messages](/sessions/hierarchy-and-human-messages/) follow.
- **Notes are append-only too**, so one cannot be edited into saying something else or deleted to
  make a gate look better than it was.

Rows backfilled from the old JSON files carry the `imported` channel rather than `web_ui`, and their
`author` is null when the source did not record one. A plausible-looking author invented by an
importer is exactly the forgery the table exists to prevent.

## Reading it

Three MCP tools, in a **tool group of their own** (`gate_decisions`), served at `POST /mcp`:

| Tool | What it is for |
| --- | --- |
| `search_gate_decisions` | The calibration read. Filter by gate, surface, decision, artifact URL, date window, or full text over the whole entry |
| `get_gate_decision_feedback` | Every note a human left, and nothing else — roughly eight across ~1,500 decisions |
| `record_gate_decision` | Write one rating. The only write tool in the group |

The group matters as much as the tools. Folded into `sessions`, every session carrying
`zimmer-sessions` could write gate ratings, and a ledger anything can write is not evidence of
anything. `gate_decisions_readonly` — generated automatically, like every base group's readonly
variant — carries the two reads and not the write. The catalog server that scopes to it is
`zimmer-gate-decisions`.

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

The source is resolved in order: an explicit directory, then `GATE_DECISION_LEDGER_DIR`, then
GitHub via the `gh` credential every Zimmer container already carries. Outside production, a source
it cannot reach is recorded on the task's ledger row and the task completes; in production it fails
loudly rather than claiming to have imported a history it never read.
