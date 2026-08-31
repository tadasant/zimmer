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

A source session with **no conversation** to copy takes that same fresh-turn path whatever its
runtime. A session that died in its opening seconds has a transcript holding only the runtime's own
bookkeeping, and copying that to the fork's resume path would hand the fork an id the runtime
refuses both ways — see [A transcript with no conversation in
it](/sessions/spawning/#a-transcript-with-no-conversation-in-it-wedges-a-session-id). So
`ForkSessionService` writes nothing and leaves `runtime_started` off, and the fork answers from the
prompt alone. Before that, the summary fork of a session wedged this way was wedged in turn, which
is how a dead session also lost the summary that would have made it visible.

Forking rather than a one-shot completion is a deliberate trade. The specifics that justify a link —
"CI is red on the migration test, see message 214" — live in the session's own conversation. A
headless inference call (the substrate `SessionTitleJob` uses for titles and categories) only ever
sees a truncated, flattened rendering of the transcript, which is exactly where those specifics get
lost. The fork gets the real conversation at the real point it stopped.

That trade only holds while a fork can actually run. When it cannot, the one-shot completion is not a
worse summary than the fork's — it is a summary against no summary at all, which is why it exists as
[the pool-independent path](#the-pool-independent-path) below.

**The inherited goal is stripped, and that is not optional.** A fork inherits the source's goal, and
a goal is an instruction to act — a summarizer still carrying "open a PR and label it ready to merge"
would go and do that.

**The fork is never credited with the source's pull requests.** `GithubPrUrlHook` decides which PRs a
session opened by reading its transcript, and a summary fork's transcript is a copy of the source's —
so the source's own `gh pr create` output sits in it as the strongest evidence the hook recognises.
Crediting the fork would enrol it in the three GitHub pollers, whose scope is that list for any
session not archived or failed, and the
PR poller answers a merge by queueing "your PR merged, you may archive" onto a session nobody reads
and the harvest job archives moments later. The hook therefore records nothing at all for a summary
fork — see [Transcript hooks](/extend/transcript-hooks/#githubprurlhook).

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
  the first hit instead of spending the budget. Retrying is for a tree being written to; it can do
  nothing for a tree being deleted, because the file never comes back.
- **A summary fork does not copy installed dependencies.** The summarizer reads the conversation and
  is told not to run tools; it never builds or boots anything. `ForkSessionService::DEPENDENCY_DIRECTORIES`
  (`vendor/bundle`, `**/node_modules`) is excluded from its copy, which is most of the bytes and most
  of the seconds — and every second the copy is not running is a second the source tree cannot change
  underneath it. A **user-initiated** fork excludes nothing; it is a working session and wants the
  tree it forked.
- **A failed fork cleans up after itself.** The partial destination is removed rather than left for
  `OrphanCloneFilesystemCleanupJob`, whose scheduled sweep ignores anything younger than 48 hours
  (2 hours on [the disk-pressure path](/operate/background-jobs/#clone-pruning-has-a-second-urgent-gear)). A retry only
  proceeds once the destination is confirmed gone — a cleanup reports nothing when it fails to clear
  the path, and a copy into a destination that still exists nests or merges rather than failing. The same
  holds for a fork that fails *after* the copy succeeded: if the session record does not save, or the
  transcript cannot be written, the copied clone is discarded on the way out rather than stranded.

A summary fork's clone is therefore **not a runnable checkout** — `.bundle/config` still points at the
`vendor/bundle` that is no longer there. See [Limitations](/limitations/#a-status-summary-forks-clone-is-missing-its-installed-dependencies-and-does-not-know-it).
And when there is no source clone left to copy at all, a forced generation gives the fork an empty
directory rather than failing — see
[The trash is not a refusal for a forced generation](#the-trash-is-not-a-refusal-for-a-forced-generation).

For an **automatic** generation, the generator also re-checks that the session is still out of the
trash **after** the copy, not just before it. The copy takes real time, and a session that archived
during it would otherwise get a fork of a clone `DeferredCloneCleanupJob` is about to delete, about a
session nobody asked about. Such a fork is archived immediately, the claim below is released so the
record does not sit in `pending` behind a fork that will never answer, and nothing is recorded against
the summary.

A **forced** generation does not take that exit — see
[The trash is not a refusal for a forced generation](#the-trash-is-not-a-refusal-for-a-forced-generation).
Somebody pressed the button, so this is not a session nobody is looking at, and by this point the fork
owns its own copy of the clone anyway.

### The trash can win that race, and that is not an error

The re-check above only runs on a copy that *finished*. When the cleanup reaches the tree first, the
copy dies partway through on a path that was there when the directory was enumerated and gone when it
was stat'd — the same benign condition, arriving as an `ENOENT` instead of as an archived session.
That used to page: `ForkSessionService` logged `error`, the generator recorded a failure, and a human
was woken about a summary nobody was going to read.

`ForkSessionService` classifies it instead. An `ENOENT` naming a path **inside the source clone**,
raised while forking a session that — re-read from the database, because the archive lands during the
copy — is **archived**, is reported as `Result#source_clone_discarded`: logged at `info`, not `error`.
For an automatic generation the generator reads that flag, releases its claim, and returns `skipped` —
the same outcome the post-copy re-check produces, with no failure recorded against the panel.

For a **forced** one the same condition is not a loss at all: an operator is watching a panel that
says "Generating", and the fork did not need the tree. The copy that died is discarded, an empty
working directory is scaffolded in its place, and the generation carries on — see
[The trash is not a refusal for a forced generation](#the-trash-is-not-a-refusal-for-a-forced-generation).
That closes the narrow race the pre-flight check cannot: the clone was there when the button was
pressed and gone by the time the job ran.

The question it asks is about the **session**, not about the clone, and that is deliberate. A clone
being deleted is renamed aside before its bytes go
([`AtomicCloneRemoval`](/operate/background-jobs/#both-clone-sweeps-reap-deletion-tombstones)), and
the copy walking that tree keeps resolving the paths it already opened — so "is the clone root gone"
is a question whose answer flips mid-copy for reasons that have nothing to do with whether this fork
is in trouble. The session's status does not. A copy in that window still looks retryable and still
spends its retry budget before failing; it costs a background job ~2.5 seconds, and it wakes no one.

The distinction is the point, and it is deliberately narrow. A clone that is missing while its
session is **live** is a genuine fault — a stray delete, a volume gone, a cleanup that ran against
the wrong path — and it still logs `error` and still pages.

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
an operator reads: the dashboard (the server-rendered grid, the Turbo Stream that pushes new cards
into it — the marker is stamped at create time, before that broadcast fires — and the
[Ranked view](/sessions/spot-and-priority/#the-queue-stays-live) and its `sessions_ranked` stream),
`GET /api/v1/sessions`, `GET /api/v1/sessions/search`, and `quick_search_sessions`. They are also
excluded from every bulk refresh (`refresh_all` in the UI, REST, and MCP), which would otherwise
resume a fork sitting between its pause and its harvest and spend a second agent turn on it.

A fork reaching `needs_input` is routed into harvesting instead of into the action queue: no push
notification, no `session_needs_input` trigger fire, no title inference.

## The pool-independent path

Everything above needs a login-pool account, a copy of the session's clone, and an agent turn. Under
sustained quota pressure a fork is **parked before it answers**, and the whole apparatus produces
nothing but a parked session holding a repository copy.

That is not a rare edge. It is the busiest hour of the day — and the busiest hour is exactly when a
human opens the action queue and wants to know where things stand. The first version of the repair
sweep answered it by standing down during an outage, which gated the retry on the very resource whose
absence caused the failure being retried. The result was a panel that read *"the summary fork was
parked before it could answer (quota_exhausted). It will be retried."* for hours, while the retry that
would have fixed it was the thing standing down.

So `SessionStatusSummaryGenerator` has a second mode. Passed `headless: true`, it takes the same
claim on the same record, then — instead of forking — renders the session's conversation to text and
asks for the blurb in **one `claude -p` completion** on a small model (Haiku, the substrate
`SessionTitleJob` has always used). It writes the answer onto the record exactly as the harvest does.

What that mode does not need is the point of it:

| | Fork | One-shot |
| --- | --- | --- |
| Login-pool account | yes — parks when the pool is empty | no; runs against the ambient credentials |
| Clone copy | yes, a full repository | none |
| MCP servers | booted | none |
| Cost | an agent turn | one small-model completion |
| Reach | the real conversation, its tools, its clone | the rendered transcript tail only |

It is reached from the three places a fork is known not to be able to deliver:

- **The repair sweep during an auth outage.** A runtime with no available account switches to this
  path rather than standing down, under its own higher cap (`MAX_HEADLESS_PER_SWEEP`).
- **The harvest of a fork that could not have delivered.** A fork that was *parked*, or that died
  while the pool was empty, enqueues a headless retry for its source session immediately rather than
  leaving it to a sweep that would re-fork into the same empty pool. A fork that died of something
  else while the pool was healthy is deliberately *not* downgraded — re-forking is the right repair
  there, and stamping a terser blurb as current would stop the sweep ever trying again.
- **A forced Regenerate while the pool is empty.** The three surfaces that offer it are all forced
  and none of them consults the pool, so the generator re-checks it rather than trusting the caller.
  It fails *open*: a pool it cannot read is not evidence of an outage.

- **Any generation at all, forced included, when the pool has nothing to fork on.** The generator
  re-checks the pool itself rather than trusting the caller, because the three forced surfaces — the
  panel's **Regenerate** button, `POST /api/v1/sessions/:id/regenerate_status_summary`, and the MCP
  `action_session` regenerate action — do not consult it. Without that check, pressing Regenerate
  during an outage paid for a clone copy, watched the fork park, and reported a failure.

Concurrency is bounded at `BlockingInferenceBounded::PERFORM_LIMIT`, a ceiling this job shares with
`SessionTitleJob` — see [Bounding blocking inference](/operate/background-jobs/#bounding-blocking-inference).
A headless run blocks a worker thread on a subprocess for up to `HEADLESS_TIMEOUT` and `default` has
four threads, so without a fleet-wide ceiling an outage could put summary inference on most of the
shared queue at once.

The ceiling deliberately does **not** key off the `headless:` argument. The caller does not decide
whether a generation blocks — the generator does, on `headless || pool_exhausted?` — so a generation
enqueued as a fork by a `pause` transition becomes a blocking subprocess the moment the pool runs
dry. A bound that read the argument would describe the caller's intent rather than the work, and
would stop binding during exactly the outage it exists for.
Two properties keep it honest:

- **A refusal never becomes a blurb**, and the guard has two halves because the wording half is not
  enough on its own. `claude -p` prints its own errors to stdout — a usage limit, a credit balance, an
  API error blob — so the primary test is the **exit status**, which `ClaudePrintRunner::Result` now
  carries: a backend that reported a failing code did not answer, whatever it left on stdout, and
  `HeadlessInferenceService` discards it. On top of that both paths run their text through
  `StatusSummaryAnswer` — one definition of "is this an answer or a refusal", rather than one per
  caller — which is what covers a backend that cannot report a code at all. A rejected answer records
  a failure and leaves the session stale, i.e. still a candidate.
- **It cannot stomp a fork.** Both modes take the same claim and every write is conditional on still
  holding it, so a one-shot whose record was taken over by a newer generation returns `pending` and
  writes nothing.

A headless generation notes itself on the session's own timeline ("Wrote the status summary with a
one-shot inference call (no fork)"), so a reader who finds a blurb terser than usual can see why.

The clone refusal does not apply here. An automatic *fork* declines a session whose clone has been
reclaimed, because a fork needs a tree to copy; a one-shot does not, and a session whose clone is gone
is exactly the kind someone opens later to ask what happened.

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
`needs_input`, and the `fail` transition into `failed`. That is the whole list for a session whose
summary is fine.

Nothing else generates:

- Viewing the session page does not. A stale summary renders as the cached text plus the
  messages-since count, and waits.
- Reading the session over MCP or REST does not.
- Nothing polls, and no per-message hook exists.

Resuming into `running` deliberately does not trigger either. "Where things stand" is a question
about a session that has stopped, and summarizing at the start of a turn spends a fork on an answer
the same turn invalidates.

On top of that the generator refuses outright when the session has not moved since the last summary,
when a generation is already in flight, when it has no transcript, and when it is itself a summary
fork. An **automatic** generation additionally refuses a session in the trash and one whose clone has
already been reclaimed: nothing enqueues one for an archived session on purpose, and standing a fork
up for a session heading for deletion is waste. A **forced** generation refuses neither — see
[The trash is not a refusal for a forced generation](#the-trash-is-not-a-refusal-for-a-forced-generation).

## The repair sweep behind it

A transition is the right trigger and a poor guarantee. A session sitting in `needs_input` has **no
further transition**, so a generation that never landed leaves the panel describing an earlier point
in the session for as long as the session sits in the user's action queue — which is exactly where an
accurate "where things stand" matters most. Four things produce that:

- the enqueued job discarded during a deploy, or lost while the queues were in recovery mode;
- the fork **parked** out of quota before it ran its turn (see below);
- the claim abandoned past `PENDING_TIMEOUT` because the fork died;
- the fork's answer landing already behind the conversation, because the source moved while the fork
  was copying and running.

`StatusSummaryBackstopJob` is the repair path. Every five minutes it walks the sessions **at rest**
(`needs_input` and `failed`, most recently active first), and re-enqueues a generation for the ones
whose summary is no longer current — no record, no summary text, or a summary the transcript has
moved past. Staleness is the whole test, and a `failed` state is deliberately not a second one: a
failure that matters leaves the summary stale anyway, while a `failed` record whose summary *is*
current is exactly the case that must not be retried, since the generator would answer an unforced
retry with "Summary is current" and the session would be re-enqueued forever. A session with no
transcript is skipped, for the same reason the transition hook skips it.

It is a repair sweep, not polling, and the difference is enforced rather than asserted:

- **It never forces.** A summary the generator considers current still costs nothing — the sweep
  enqueues, and the generator returns "current" without forking.
- **It stamps every session it examines** (`session_status_summaries.backstop_attempted_at`), so a
  session is looked at once per `RETRY_INTERVAL` (30 minutes) rather than once per sweep. That is also
  what stops a session that can never be summarized — one whose clone has been reclaimed — from
  eating the sweep's budget ahead of one that could be repaired. The stamp is a `WHERE`, not a filter
  in Ruby, so the steady state — every session at rest already stamped — returns no rows at all
  rather than the whole action queue. A `SCAN_LIMIT` of 200 bounds the pathological case, and a sweep
  that reaches it logs that it did.
- **It is capped at `MAX_PER_SWEEP` (5) repairs.** Each repair costs a fork of a repository and an
  agent turn, so a fleet-wide outage that failed every generation at once cannot become a fleet-wide
  re-fork.
- **An auth outage changes how it repairs, not whether it does.** A runtime with no available account
  is repaired on the [pool-independent path](#the-pool-independent-path) instead — no fork, no clone
  copy, no account slot. That path is capped separately at `MAX_HEADLESS_PER_SWEEP` (10), higher than
  the fork cap because the costs are not comparable.
- **A session mid-turn is not swept.** A `blocked_on_elicitation` session is `needs_input` with a live
  process waiting on an approval; it is not at rest, and there is nothing final to say about it yet.
  Neither are summary forks, which would fork the fork.

Rendering the panel still generates nothing. The sweep is the only thing that starts a generation
without either a transition or a person.

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
- **REST** — `POST /api/v1/sessions/:id/regenerate_status_summary`, which returns `202 Accepted` (or `422` with a reason — see below).

And the summary is readable from both without generating anything: `get_session` renders a
`### Status Summary` section with a freshness marker, and `GET /api/v1/sessions/:id` returns
`status_summary` as a sibling of `session`.

### The trash is not a refusal for a forced generation

**An archived session regenerates like any other.** Archive is how a Zimmer session *finishes*, its
transcript stays readable, and a finished session is exactly the one somebody opens later to ask what
happened — which is the question the panel answers. Refusing on `archived?` made the one control in
that panel dead, silently: the button was enabled, the panel flipped to "Generating", the job declined
because the session was in the trash, and no new summary ever arrived.

**A reclaimed clone is not a refusal either.** `DeferredCloneCleanupJob` deletes an archived session's
clone once the ten-second undo window closes — on the clean branch *and* on the branch that preserves
unpushed artifacts first; only a session whose artifacts Zimmer failed to preserve keeps its clone for
the trash-retention window. So every archived session an operator actually opens later has no working
tree at all, and a check for one would refuse exactly the sessions the panel exists to serve.

What generation actually needs is the **conversation**, and that is in the database. The summarizer is
told not to run tools and answers from the transcript it was forked with; what it needs from the
filesystem is a directory to be spawned in and the resume transcript `ForkSessionService` writes under
`~/.claude/projects`. So when the source clone is gone, the fork is given an **empty working
directory** instead of a copy — `ForkSessionService`'s `scaffold_missing_clone`, which
`SessionStatusSummaryGenerator` passes only on a forced run. The fork's clone is stamped
`clone_scaffolded` in its metadata, so an empty tree reads as deliberate rather than as a copy that
died halfway.

The scaffold is `git init`ed rather than left as a bare directory, because "a directory to be spawned
in" is not quite the whole requirement: `codex exec` refuses to start outside a git repository unless
it is passed `--skip-git-repo-check`, which Zimmer does not pass and should not have to — every clone
it has ever spawned into has been a real repository. An empty repository keeps that true for the cost
of one subprocess. It is best-effort: a `git init` that fails is logged and the fork carries on, since
a Claude Code summary fork does not care either way.

Scaffolding is not only for the trash, either. `StaleCloneCleanupJob` reclaims a **failed** session's
clone after 24 hours, and a day-old failed session is exactly the kind someone opens to ask what
happened. That case scaffolds too, logged at `warn` rather than `info` — the archived case is
expected, and this one is worth noticing.

Scaffolding also closes the race the pre-flight cannot: a clone that was there when the button was
pressed and unlinked while the copy walked it. The copy fails with `ENOENT` inside the source tree,
and a forced fork scaffolds rather than giving up — it did not need the tree in the first place.

Nothing is resuscitated on the **automatic** path. `unavailable_reason` still stats the clone for a
non-forced run, and an automatic generation for a session whose clone is gone is refused. Paying to
stand a fork up for a session nobody is looking at is the waste the automatic refusals exist to
prevent.

Two refusals remain, and they are the ones no amount of scaffolding can fix: a session that is itself
a summary fork (it has nothing to say), and one with no transcript (nothing to say it about).
`SessionStatusSummaryGenerator.unavailable_reason` answers with those.

**All three surfaces ask it before they enqueue** — as the *forced* run they perform, so they get the
answer for the click rather than for the automatic path. A request that cannot produce a summary is
answered with the reason instead of a job that declines where nobody can see it:

| Surface | Something to summarize | Nothing to summarize |
| --- | --- | --- |
| Status panel | button live, panel flips to "Generating" | button disabled, panel says why |
| `action_session` | `## Status Summary Regenerating` | tool error carrying the reason |
| `POST /api/v1/sessions/:id/regenerate_status_summary` | `202 Accepted` | `422 Unprocessable Entity` with the reason |

The pre-flight reads the session. It writes nothing and enqueues nothing, so the rule that **rendering
the panel never generates** still holds — the panel calls it on every page view.

### What a scaffolded fork leaves behind

Nothing that outlives it, and nothing new. The scaffolded directory *is* the fork's own clone — Zimmer
does not restore the source session's clone, does not touch the source session's status, and does not
write to the source session's metadata. So there is no half-restored state to unwind on the way out,
on either the success or the failure path:

- **Success** — `SessionStatusSummaryHarvestJob` lifts the blurb onto the source session and archives
  the fork. `DeferredCloneCleanupJob` reclaims the scaffolded directory on the normal trash path, the
  same as any other fork's clone.
- **Failure before dispatch** — the generator archives the fork it made rather than leaving it on the
  floor (`#abandon_fork`), which reclaims the directory the same way.
- **The process dies in between** — the fork is a `needs_input` session with a directory holding an
  empty `.git`, an `.mcp.json` and whatever `air prepare` injected alongside it, and nothing of the
  repository. It is invisible to operator lists, and its summary record ages out at
  `PENDING_TIMEOUT` into the "started but never came back" state the panel already renders. Nothing
  about the source session is different from before the click.

## Failure and abandonment

A fork that fails, or comes back with nothing usable, records the reason on the summary record and
leaves the previous blurb in place — a stale-but-real summary beats an empty panel. The fork is
archived either way; a fork left behind holds a full copy of a repository.

### A pause is not proof that the fork answered

`AuthOutageParkService` parks a session that has run out of login pool by scheduling a wake and
letting it reach `pause!` — **the same transition a finished turn reaches**. A parked summary fork
never ran its turn, so the last assistant text in its transcript is the runtime's own refusal:
`You've hit your session limit · resets 10pm (UTC)`, `Not logged in · Please run /login`.

Harvesting treated that as the answer. It was stored as the session's Status blurb, stamped `ready`
at the requested line count — which is to say **marked current**, so `stale?` was false and no later
generation, automatic or forced, would replace it. On this deployment 73 sessions ended up displaying
a quota refusal as their status, two of them sitting in the user's action queue; in one id window, 91
of the 92 summary forks carried the park marker.

`SessionStatusSummaryHarvestJob` now refuses those two ways over:

- **The park marker.** A fork carrying `auth_outage_reason` is treated exactly like a failed one — the
  reason is recorded, nothing is stamped, and the displayed summary stays stale and therefore eligible
  to be written over.
- **The text.** A runtime can also print its limit line and exit cleanly, before rotation has anything
  left to rotate into and so before anything parks it. An answer that is a single line under 200
  characters matching `ApiErrorRetryService::ACCOUNT_QUOTA_LIMIT_PATTERN` or
  `AuthRecoveryService::AUTH_RECOVERABLE_ERROR_PATTERN` is rejected. Requiring one short line is what
  keeps the patterns off a genuine blurb that happens to be *about* a session which hit a limit;
  getting that judgement wrong costs a regeneration, never a wrong blurb.

**Refusing an answer is not the same as delivering one**, and for a while that was the whole of the
remaining bug. Rejecting the refusal made the panel honest — it said the generation had failed
instead of displaying a quota refusal as though it were a summary — but it was still empty, which
from the reader's side is the same defect. So a fork that comes back with nothing now hands its
source session straight to [the pool-independent path](#the-pool-independent-path) rather than
waiting for a sweep to re-fork into the pool that just parked it.

The fork is archived either way, so the copied clone is still reclaimed. The park's own wake trigger
goes with it — one parked fork waiting hours for quota holds a full repository copy, and starting a
fresh generation later is cheaper than keeping it. In the incident above the same source sessions
were re-forked up to five times each, so the re-fork was happening regardless.

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
