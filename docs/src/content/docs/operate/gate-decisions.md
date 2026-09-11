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

It is enforced twice. The model's callbacks refuse every path through a `GateDecision` instance,
with an error a caller can read. The `gate_decisions_append_only` Postgres trigger refuses the paths
that never reach a callback — `update_all`, `delete_all`, `update_column`, raw SQL. The trigger is in
`db/schema.rb`, so CI and test have it too (see
[Testing](/operate/testing/#functions-and-triggers-are-dumped-other-ddl-is-refused)).

Two gaps, both deliberate. The trigger lets one `UPDATE` through: the foreign key clearing
`writing_session_id` after that session is deleted, which would otherwise make the session
undeletable. And `TRUNCATE` fires no row trigger. A plain `TRUNCATE gate_decisions` is refused
anyway, because `gate_decision_feedbacks` references the table, but `TRUNCATE … CASCADE` is not.
`gate_decision_feedbacks` itself is append-only on the model only.

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

`surface` is a **free string**, not an enum or an allowlist — normalized on the way in
(`GateDecision.normalize_surface` lowercases and turns hyphens and whitespace into underscores) so
that "Strad-Production" and `strad_production` land in the same bucket rather than founding two. A
gate rating a repo Zimmer has never seen before can record the decision immediately; nothing here
has to be deployed first. The cost of that is spelling: use whatever the ledger already writes for
that surface, because a typo founds a bucket rather than being rejected.

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
[#220](https://github.com/tadasant/zimmer/issues/220)). CSRF enforcement is still on, so the form
post is not free — an agent would have to fetch a token from a Zimmer page first — but a speed bump
is not a boundary. Until the primitive exists, `web_ui` means "came in through the browser surface",
which is weaker than "a human typed it", and the ledger should be read that way.

Rows backfilled from the old JSON files carry the `imported` channel rather than `web_ui`, and their
`author` is null when the source did not record one. A plausible-looking author invented by an
importer is exactly the forgery the table exists to prevent.

## Reading it

Three MCP tools, in an **opt-in tool group of their own** (`gate_decisions`), served at `POST /mcp`:

| Tool | What it is for |
| --- | --- |
| `search_gate_decisions` | The calibration read. Filter by gate, surface, decision, artifact URL (exact, or `artifact_query` for a substring of it), date window, or full text over the whole entry |
| `get_gate_decision_feedback` | Every note a human left, and nothing else — roughly eight across ~1,500 decisions |
| `record_gate_decision` | Write one rating. The only write tool in the group |

The group matters as much as the tools, and so does its being **opt-in**. Folded into `sessions`,
every session carrying `zimmer-sessions` would be handed the ability to write gate ratings; left in
the base set, so would every session holding the unscoped `zimmer` server, since omitting
`tool_groups` means "every base group". A ledger every session has a pen for is not evidence of
anything. So `gate_decisions` sits outside the base set: it is valid and addressable, but a
connection has to name it. `gate_decisions_readonly` — generated automatically, like every domain
group's readonly variant — carries the two reads and not the write. The one catalog entry that
scopes to the full group is `zimmer-gate-decisions`, and it is meant for the two gate roots, which
live in a deployment's own catalog rather than in Zimmer's — so attaching it there is what puts the
write tool back within reach of the gates, and of nothing else.

Be precise about what that buys, though: **tool groups are a scoping boundary, not an authorization
one.** The API key is shared by the whole fleet and is written into every session's own MCP config,
so a determined agent could compose its own `?tool_groups=` URL. What the group decides is what a
session is *offered*, which is what keeps recording a rating from being something any session does
in passing. The guarantee that does not depend on a caller staying inside its tools is the feedback
boundary above: no API key reaches `POST /gate_decisions/:id/feedbacks` at all.

The same filters are on `GET /api/v1/gate_decisions`; see [the REST API](/extend/rest-api/).

## Browsing it

`/gate_decisions` is the Gate Decisions tab in the web UI, and it is the surface a person reads the
ledger through rather than a gate. The list filters on gate, surface, decision, a `decided_at`
window, a substring search over the artifact URL, full text over the whole entry, and "has a human
note" — through **the same `GateDecisions::Filters` object** the REST index and
`search_gate_decisions` use, so a question asked on the page and the same question asked by a gate
cannot come back with different answers. A filter the ledger cannot honour — an unknown gate, an
unparseable date, which takes a hand-edited URL to produce — says so on the page and shows the ledger
unfiltered, because "no precedent" is the wrong thing for anyone to conclude from a typo.

Two of those filters are sequential scans and will stay that way: a leading-wildcard `ILIKE` cannot
use the btree index on `artifact_url`, and the full-text filter is `payload::text ILIKE`, which the
GIN index on `payload` cannot serve either. At ~1,500 rows and ~13 MB Postgres does both in tens of
milliseconds, which is the same trade `GateDecision.matching_text` documents — substring matching is
what a reader searching for `air_prepare_service.rb` or `#722` actually means, and a word-stemmed
index would be faster at answering a different question.

**The detail page renders the entry generically, and that is the design.** There is no list of field
names anywhere in the view. `GateDecisions::PayloadView` classifies each value by its **shape** —
boolean, number, short string, URL, paragraph, list of scalars, list of objects, nested object — and
the shape decides how it is drawn; anything nested past the depth cap degrades to pretty-printed JSON
rather than to a blank. That matters because the gates' schemas move: across 318 PR-gate zimmer
entries there are 34 distinct keys, four of which arrived in the last few weeks. A view built from a
field list would go wrong by **omission**, silently, the first time a gate added a key — the page
would still look complete and nobody auditing a hold would know a section was missing.

The same classification decides the layout. Fields that render short — the verdict, the ratings, the
axes, the flags — are lifted into an at-a-glance aside that stays put while the long-form prose
scrolls in the main column. `ratings` and `justifications` are the worked example: same keys, same
nesting, but one holds four words and the other four paragraphs, so one skims and the other does not,
and no rule naming either of them was needed to get that right. The aside may pick; the entry view
below it never omits — every key the gate wrote.

The order those keys appear in is Postgres's rather than the gate's: `payload` is `jsonb`, which
normalizes an object on the way in, so keys come back shortest-first then bytewise no matter how the
gate wrote them. Authoring order was never stored and cannot be recovered. The order is stable — the
same entry always renders the same way — which is what a reader comparing two ratings needs.

Because rows are append-only, a re-rate is a *new* row and the earlier reading is still live in the
table. The detail page says so: every other rating of the same artifact is linked from the top, so
someone reading a hold finds out that a later row un-held it.

The feedback form lives here too, posting to `POST /gate_decisions/:id/feedbacks` — the browser-only
write path above, with the honest limits of that boundary stated in the form's own copy rather than
implied away. Nothing on the page claims a note is verified-human, because Zimmer's browser surface
authenticates nobody.

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

### The appends the first import missed

`ImportGateDecisionLedgers` read the archive once, between 15:02 and 15:26 UTC on 2026-09-02. The
gates kept appending to the JSON files for eight more hours, until the cutover to
`record_gate_decision`, and for about an hour after it as a fallback while that tool was
unreachable. None of those 52 entries, across 13 files, was imported
([tadasant/tadasant-internal#2432](https://github.com/tadasant/tadasant-internal/issues/2432)).
50 of them were in no row at all.

`ImportGateDecisionsAppendedAfterTheLedgerImport` imports 50 of them. It is not a re-run of the
importer, because the other two were recorded live as well. Those two are tadasant-internal#2399's
rating and its re-rate, and the re-rate was recorded as decided a day later and under a different
verdict (`correction`). Their live rows carry no source key, so a re-run would have inserted both a
second time, into a table that cannot delete a row. So the task pins the 50 it imports: each one by
the key the importer would give it and the verdict it carries, all checked against the table
before the task was written. Its keys are the importer's own, so a whole-file import over the
archive would find all 50 already present. Two things guard the insert:

- **A pinned entry that has since been recorded live is skipped.** That means a row a gate wrote over
  MCP or the API for the same gate and artifact, decided within a day of the entry. Surface is not
  matched, because live rows have been recorded under the wrong one. Skipping errs toward a missed
  insert, which another task can add. A wrong insert cannot be removed.
- **A pinned entry it cannot find fails the run.** If the entry is absent from the archive, carries
  a different verdict, or is refused by the model, nothing is written for it. Every other file
  still finishes first, and then the run parks `failed` on /health, naming the unresolved entries.
  The files holding them go back off the cursor, so a retry, or a re-arm after the cause is fixed,
  re-reads only those files.

Its `stats` give the outcome of each of the 50 under `entries`, keyed by source key, with totals
beside them. The backfill is complete when `unresolved` is 0 and `imported`, `already_present` and
`recorded_live` sum to 50. A clean first run reads `imported: 50`.
