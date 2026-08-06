---
title: The Status summary
description: The two-or-three sentence "where things stand" blurb at the top of a session page — written by forking the session, cached until the session moves, and regenerated on exactly one automatic trigger.
sidebar:
  order: 8
---

A long session is expensive to re-enter. You open it, and the answer to "does this need me?" is
somewhere in four hundred transcript rows. The **Status** panel is the answer stated once, at the
top, in two or three sentences — and then linked out from there.

## The panel group

The session detail screen opens with one card holding four sections:

| Section | State | What it answers |
| --- | --- | --- |
| **Status** | always expanded | Where does this stand, and does it want me right now? |
| **Session hierarchy** | collapsible | Who spawned this, and what else is in the tree? |
| **Human messages** | collapsible | Did a human actually ask for this? |
| **Transcript** | collapsed by default | What actually happened, in full? |

Status is the only one that is never a disclosure. The other three are plain `<details>` elements —
no JS to load, and nothing for the transcript's infinite-scroll and auto-scroll controllers to fight
with.

The transcript being collapsed is the point of the arrangement: on a session with thousands of rows,
the three panels above it are what a returning reader wants first, and the transcript is what they
open once they know which part they need.

## Link, don't explain

The summary is deliberately short and deliberately link-heavy. The rule the generating agent is given
is: **if a detail is worth more than a clause, link to it rather than spending a sentence on it.**

Three kinds of link do most of the work:

- **A specific transcript message.** Every top-level transcript row carries a stable `id` of
  `message-<transcript_index>` — the same index the fork-from-here affordance uses, so the two agree
  by construction. A link to `#message-214` opens the collapsed Transcript panel, scrolls that row
  into view, and rings it briefly.
- **A pull request, issue, or CI run** that came up in the conversation.
- **Another Zimmer session**, by its `/sessions/:id` URL.

## Generation runs on a fork

The blurb is written by an agent, and the agent is a **fork of the session itself**.

`SessionStatusSummaryGenerator` forks the session at its last transcript message, strips the fork's
inherited goal, title and heartbeat, and sends it one follow-up prompt asking for the summary. The
fork runs a single turn and pauses. `SessionStatusSummaryHarvestJob` lifts the assistant text the
fork wrote *after* the fork point onto the source session's `SessionStatusSummary` record, then
archives the fork so its copied clone is reclaimed on the normal trash path.

For runtimes with a deterministic resume transcript file, such as Claude Code, the fork resumes from
the copied transcript file. Codex does not have that shape: its rollouts live in a date-partitioned
tree with runtime-generated UUID filenames, so Zimmer cannot recreate a resumable rollout for a
fresh fork. A Codex summary fork therefore starts as a fresh one-shot turn and receives the copied
conversation inline in the summary prompt.

Forking rather than a one-shot completion is a deliberate trade. The specifics that justify a link —
"CI is red on the migration test, see message 214" — live in the session's own conversation. A
headless inference call (the substrate `SessionTitleJob` uses for titles and categories) only ever
sees a truncated, flattened rendering of the transcript, which is exactly where those specifics get
lost. The fork gets the real conversation at the real point it stopped.

**The inherited goal is stripped, and that is not optional.** A fork inherits the source's goal, and
a goal is an instruction to act — a summarizer still carrying "open a PR and label it ready to merge"
would go and do that.

### Copying a clone that is still being written to

The fork copies the source session's clone directory, and that clone is a **live working tree**. The
session's own agent, its jobs (`BundleInstallJob` rewrites `vendor/bundle` wholesale) and the archive
pipeline all keep writing to it while the copy walks it. A recursive copy enumerates a directory
before it stats the entries it found, so a file that disappears in that window aborts the copy with
`ENOENT`.

Three things keep that from failing a fork:

- **The copy is retried.** `ForkSessionService::COPY_RETRY_DELAYS` gives it three attempts with
  backoff, clearing the half-written destination between them. Intermediate attempts log at `info`;
  only an exhausted budget logs `error` — which is what alerts. A copy that fails for a reason that
  will not fix itself (`EACCES`, `ENOSPC`, or an `ENOENT` because the *source* clone is gone) fails on
  the first hit instead of spending the budget.
- **A summary fork does not copy installed dependencies.** The summarizer reads the conversation and
  is told not to run tools; it never builds or boots anything. `ForkSessionService::DEPENDENCY_DIRECTORIES`
  (`vendor/bundle`, `**/node_modules`) is excluded from its copy, which is most of the bytes and most
  of the seconds — and every second the copy is not running is a second the source tree cannot change
  underneath it. A **user-initiated** fork excludes nothing; it is a working session and wants the
  tree it forked.
- **A failed fork cleans up after itself.** The partial destination is removed rather than left for
  `OrphanCloneFilesystemCleanupJob`, whose scheduled sweep ignores anything younger than 48 hours
  (2 hours on [the disk-pressure path](/operate/background-jobs/#clone-pruning-has-a-second-urgent-gear)). A retry only
  proceeds once the destination is confirmed gone — `rm_rf` reports nothing when it removes part of a
  tree, and a copy into a destination that still exists nests or merges rather than failing. The same
  holds for a fork that fails *after* the copy succeeded: if the session record does not save, or the
  transcript cannot be written, the copied clone is discarded on the way out rather than stranded.

A summary fork's clone is therefore **not a runnable checkout** — `.bundle/config` still points at the
`vendor/bundle` that is no longer there. See [Limitations](/limitations/#a-status-summary-forks-clone-is-missing-its-installed-dependencies-and-does-not-know-it).

The generator also re-checks that the session is still out of the trash **after** the copy, not just
before it. The copy takes real time, and a session that archived during it would otherwise get a fork
of a clone `DeferredCloneCleanupJob` is about to delete. Such a fork is archived immediately, the
claim below is released so the record does not sit in `pending` behind a fork that will never answer,
and nothing is recorded against the summary.

### The fork's title has to fit the cap the source title already fills

A fork is titled `Fork of <source title>`, and `Session` caps a title at 100 characters. A source
title over 92 characters therefore composes a title the model rejects, and the fork fails on
`Session.create!` — deterministically, since no retry can produce a shorter title. Titles that long
are legal and routine: a router sets them through `start_session`, where "under 70 characters" is
guidance and not enforcement, and `SessionTitleJob` cuts its own generated titles at the full 100.

`ForkSessionService#generate_forked_title` truncates the base title, with an ellipsis, to whatever
the prefix leaves. The budget is read off `Session`'s own length validator
(`ForkSessionService.title_length_limit`) rather than restated, so changing the model's cap cannot
leave the service composing titles the model then refuses. A fork of a fork spends the prefix twice
against the same cap, so a long title erodes by 8 characters and an ellipsis each time it is forked.

### One generation at a time

Five call sites can ask for a summary — the `pause` and `fail` transitions, plus Regenerate on each of
the UI, REST and MCP surfaces — and nothing serializes them. Two landing together on one session used
to mean two full clone copies and a duplicate-key insert, because the record was read-or-built up
front and written only *after* the copy finished: for the several seconds the copy took, there was no
row for the in-flight guard to see.

The record is therefore created **before** the fork, and claimed **before** the fork:

1. The `SessionStatusSummary` row is created if the session has none, atomically — two runners
   inserting at once end up with one row rather than one row and a `PG::UniqueViolation`.
2. The generation is claimed under a row lock. Exactly one runner moves the record into `pending`;
   the losers return "a summary is already being generated" having forked nothing.
3. `requested_at` doubles as the claim token. Every later write is conditional on the row still
   carrying the timestamp this runner wrote, so a copy that outlived `PENDING_TIMEOUT` and had its
   record taken over by a newer generation ends with the older runner archiving its own fork and
   leaving the newer claim alone — rather than pointing the record at a fork whose answer is already
   stale.

Harvesting enforces the same rule from the other end: an answer is only lifted onto the record if the
record still **names that fork**, including when it names no fork at all because a newer claim is
still copying. Every fork that can reach the harvest job was written onto the record before it was
dispatched, so a record that does not name it has moved on. Adopting such an answer would store a
stale blurb against the newer generation's line count — which is to say, render it as up to date. The
fork is archived either way.

`SessionStatusSummaryJob` is deliberately **not** deduped at the queue level. A GoodJob concurrency
key on the session id would collapse an operator's forced Regenerate into an unforced automatic
refresh that happened to be queued for the same session — the operator presses the only control in the
panel and nothing happens. The exclusion belongs where the expensive work is.

Summary forks are Zimmer's own bookkeeping, not the operator's work, so they stay out of every list
an operator reads: the dashboard (both the server-rendered grid *and* the Turbo Stream that pushes
new cards into it — the marker is stamped at create time, before that broadcast fires),
`GET /api/v1/sessions`, `GET /api/v1/sessions/search`, and `quick_search_sessions`. They are also
excluded from every bulk refresh (`refresh_all` in the UI, REST, and MCP), which would otherwise
resume a fork sitting between its pause and its harvest and spend a second agent turn on it.

A fork reaching `needs_input` is routed into harvesting instead of into the action queue: no push
notification, no `session_needs_input` trigger fire, no title inference.

## Caching: staleness is counted in messages, not minutes

A summary does not expire because time passed. It expires because the session **said something new**.

`SessionStatusSummary` records the session's transcript line count at the moment the displayed
summary was produced. "Messages since summary generated" is that number subtracted from the live
count, and a summary whose count matches is never regenerated — no matter how many times the page is
viewed.

That count only advances on a *successful* generation. A generation that was merely requested, or one
that failed, leaves it alone, so a failed attempt cannot make a stale summary look current.

## The one automatic trigger

Zimmer generates a summary automatically when a session **comes to rest**: the `pause` transition into
`needs_input`, and the `fail` transition into `failed`. That is the whole list.

Nothing else generates:

- Viewing the session page does not. A stale summary renders as the cached text plus the
  messages-since count, and waits.
- Reading the session over MCP or REST does not.
- Nothing polls, and no per-message hook exists.

Resuming into `running` deliberately does not trigger either. "Where things stand" is a question
about a session that has stopped, and summarizing at the start of a turn spends a fork on an answer
the same turn invalidates.

On top of that the generator refuses outright when the session has not moved since the last summary,
when a generation is already in flight, when the session is in the trash, when it has no transcript,
and when it is itself a summary fork.

## Regenerating on demand

The **Regenerate** button in the panel is the one write path, and it is *forced* — it regenerates even
when Zimmer considers the cached blurb current. The staleness check exists to stop automatic
regeneration, not to argue with the person looking at the page.

The panel updates itself when the answer lands: `SessionStatusSummary` broadcasts a replacement of
`session_<id>_status_panel` over the `session_<id>_status` stream the detail screen already
subscribes to. Generation takes a whole agent turn on a fork, so the page that asked for it is long
since rendered by then — without the broadcast the panel would sit on "Generating…" until someone
reloaded, which for the only control in the panel reads as broken.

The same capability is on the other two surfaces:

- **MCP** — `action_session` with `"action": "regenerate_status_summary"`. Enqueued, not run inline:
  generation waits on a whole agent turn.
- **REST** — `POST /api/v1/sessions/:id/regenerate_status_summary`, which returns `202 Accepted`.

And the summary is readable from both without generating anything: `get_session` renders a
`### Status Summary` section with a freshness marker, and `GET /api/v1/sessions/:id` returns
`status_summary` as a sibling of `session`.

## Failure and abandonment

A fork that fails, or comes back with nothing usable, records the reason on the summary record and
leaves the previous blurb in place — a stale-but-real summary beats an empty panel. The fork is
archived either way; a fork left behind holds a full copy of a repository.

The recorded reason folds together the fork's `failure_reason`, `exit_status`, and
`exception_message`, capped at `SessionStatusSummary::MAX_ERROR_CHARS`. All three are included
because the failure paths write different subsets — a process death records a reason and an exit
status, an exception death records a reason and an exception message and no exit status. The fork is
hidden, so anything left only in its metadata is invisible to the person reading the panel: before
this, a Codex fork killed by `Resume failed and no prompt available for fresh start recovery`
surfaced as the bare, unactionable `The summary fork failed.`

The reason is written onto the row **as it exists in the database**, and only when the failing run
still holds the claim. A handler whose only job is to record a failure must not be able to fail the
way the thing it is recording failed — when it did, the failure went unrecorded, the record stayed
`pending`, and the panel spun on "Generating…" for the full fifteen minutes.

An in-flight generation that never comes back stops counting as pending after 15 minutes
(`PENDING_TIMEOUT`) so the panel says so and the Regenerate button starts working again, rather than
spinning forever.

Fleet-wide, the rows are browsable in the Supervisor dashboard (`/supervisor/session_status_summaries`),
which answers two questions a per-session panel cannot: which generations are wedged in `pending`, and
which sessions keep failing for the same reason. Only `state` is editable there — the text is
agent-written and the two line counts *are* the staleness arithmetic, so hand-editing either would
make the panel lie about how current it is.
