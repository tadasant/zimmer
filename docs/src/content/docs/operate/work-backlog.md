---
title: The work backlog
description: The ranked queue of gate-cleared issues the agent fleet works from, in Postgres instead of a JSON file — what an item is, how it is ranked, who may write it, and how it becomes a session.
---

The issue work gate clears far more issues per day than the fleet finishes. The **work backlog**
is where the cleared-but-unstarted ones wait: a ranked list, cheap to hold, that one job pulls
from a few times a day. A Zimmer session is not the queue — a parked session costs a clone, a
scheduler slot and a decision, and the list used to be 245 of them.

It replaces `WORK_BACKLOG.json`, a checked-in file in the deployment's private companion repo
that every append and every pull rewrote through its own auto-merged pull request. The
`work_backlog_items` table is the same queue with the same ranking rules, reachable by a gate or a
groomer in one call.

```
issue work gate ──append──►  work_backlog_items  ──pull a few/day──►  implementing sessions
   (priority)                  (this table)           (04:00 groomer)          (spot)
                                     │
                          human: "start now" ──────────────────────►  priority session
```

## What an item is

A pointer to a GitHub issue plus the gate's rating and its rank. **GitHub stays the source of
truth for the issue** — the verdict, the reasoning and the spec live on the thread; the row does
not mirror issue state, and a reader re-checks the issue before acting on it.

| Column | What it holds |
| --- | --- |
| `key` | `zimmer#498`, or `manual-<slug>` for an item with no issue |
| `issue_url`, `repo`, `surface`, `title`, `kind`, `scope_direction` | The issue and how the gate classified it |
| `estimated_cost` | `small` / `medium` / `large` — **the ranking input**, rated by the gate |
| `gate_verdict`, `decided_at`, `added_at`, `added_by`, `added_via` | The gate's decision and when and how the row arrived |
| `precedence`, `pinned` | Where it sits, and whether a human put it there |
| `status` | `queued` → `started` or `removed`. Nothing moves a row back; see below |
| `writing_session_id` | The session that appended it — stamped from the MCP connection, self-declared on REST |
| `started_session_id`, `started_by_session_id`, `started_at` | The session it became, the session that pulled it, and when |
| `removed_at`, `removed_by`, `removal_reason` | For a removed item, who and why |
| `liveness_state`, `liveness_checked_at` | What the liveness re-check last observed about a row that left the queue, and when |
| `payload` | `ratings`, `prompt`, `notes`, `gate_session`, and whatever the gate adds next |

**A row is never deleted.** The file dropped an item when it was pulled, so the history of what got
started lived only in the groomer's reports. Here the row stays with a status, so "what did the
backlog produce" is a query and the queue's size over time can be charted. "Removed" still means
gone from the queue.

**An issueless item may only come from a human or the one-time import.** The groomer spawns a
session straight from `prompt`, with no issue to re-check and no verdict behind it, so
`issue_url: null` is exactly the shape ungated work would take to reach the fleet. The model
enforces it, and the MCP append tool refuses `prompt` outright.

## Ranking

**Shortest work near the top.** That is the whole rule, and it is encoded once, in
`WorkBacklog::Ranking`, so the gate and the groomer no longer re-implement it.

`precedence` is an absolute scale — higher is pulled sooner, values are deliberately sparse, and an
ordinary append renumbers nothing. An unpinned item sits in a band chosen by its `estimated_cost`:

| `estimated_cost` | Band | Base |
| --- | --- | --- |
| `small` | 5000–6999 | 6000 |
| `medium` | 2000–3999 | 3000 |
| `large` | 500–1999 | 1000 |

An append lands 10 below the lowest unpinned peer of the same cost that sits inside the band
(first-in, first-out within a band). When the next slot would be at or below the floor, the band is
re-spaced first — its unpinned items spread evenly across `[floor, base]`, order preserved — and
the append goes below the re-spaced lowest. A band that a re-space cannot make room in raises,
before any row moves, rather than crossing into the band below, because crossing would silently
rank cheap work below expensive work. That gives a band roughly 495 items.

**A pinned item is never touched by an agent.** `pinned: true` is how a human hand-moves an item
and has it stay moved: it can sit anywhere on the scale, including below a floor, and it is
excluded from every peer set so one hand-placement cannot drag future appends down with it.
Every writer re-ranks the queue after it writes, moving any unpinned item that has drifted out of
its band back to 10 below its band's lowest peer, oldest first.

Every mutation runs under a transaction-scoped Postgres advisory lock, so two gates appending at
once serialise instead of both computing "10 below the lowest peer" from the same snapshot.

## Who may do what

| Operation | Who | Surface |
| --- | --- | --- |
| Read the queue | anyone with the group | `get_work_backlog`, `GET /api/v1/work_backlog_items` |
| Append a cleared issue | the issue work gate | `append_work_backlog_item`, `POST /api/v1/work_backlog_items` |
| Pull the top N into spot sessions, removing dead ones for a mechanical reason | the groomer | `pull_work_backlog_items`, `POST /api/v1/work_backlog_items/pull` |
| Pin or hand-place an item | a human | `PATCH …/:id/pin`, `PATCH …/:id/unpin`, or the row's Pin / Unpin controls on [`/issues`](/operate/issues-view/#the-four-human-only-operations) — **no MCP tool** |
| Remove an item by judgement | a human | `POST …/:id/remove`, or the row's Remove control on `/issues` — **no MCP tool** |
| Start an item now, as a `priority` session | a human | `POST …/:id/start_now`, or the row's Promote control on `/issues` — **no MCP tool** |

The mechanical operations are agent-callable and the discretionary ones are not, and that split is
enforced by absence: there is no MCP tool that pins, places, removes by free-text reason, or
promotes to priority, and a test asserts none appears. The browser half of each discretionary
operation is a controller of its own — `WorkBacklogPromotionsController`, `WorkBacklogPinsController`,
`WorkBacklogRemovalsController` — descending from `ApplicationController` rather than
`Api::BaseController`, so a form on `/issues` reaches them and the fleet's shared API key does not.
The one removal an agent may make is on a pull, with a reason drawn from a fixed vocabulary of
observed facts — `issue_closed`, `issue_has_open_pr`, `session_already_working`, `trust_failed` —
not typed.

The `work_backlog` MCP tool group is **opt-in**, like `gate_decisions`: a connection has to name
it, so neither `zimmer-sessions` nor the unscoped `zimmer` server carries the writes. The queue is
read by a job that spawns sessions with no human in the loop, which makes an entry on it an
unattended implementing session; a queue every session has a pen for is not one. Like every tool
group this is a *scoping* boundary — what a session is offered — not an authorization one, since
the API key is shared by the fleet. On REST the same caveat applies to `acting_session_id`: it is
provenance, never authorization.

## How an item becomes a session

`WorkBacklog::Start` is the one place the queue becomes work. It spawns a `zimmer-orchestrator` session
with goal `open-reviewed-green-pr`, prompted with the issue URL plus "Please implement this" (an
issueless item's verbatim `prompt`), titled `Implement zimmer#498 (…)`, and tagged
`custom_metadata.spawned_by = "work-backlog"` with the item's id and key. The item is marked
`started` with that session in the same transaction, so a failed spawn leaves it queued.

A **pull** starts each item at `spot` class, as a child of the pulling session, with the rank
carried forward: the n-th item pulled gets the puller's precedence plus `(count − n + 1)`, so the
top item runs first and the tree stays contiguous. The server bounds a pull at 10 items; how many
to pull on a given night — three, against a WIP ceiling of ten — is the groomer's policy, not the
server's. A pull by `keys` is safe to retry after an error; a pull by `count` is not, and the tool
says so. A **start now** starts one item at `priority`
class — the human's lever over the spot queue, which is why it has no MCP path.

## What `in_flight` counts

`in_flight` is not only a number on a page. The groomer's pull is
`max(0, min(PER_RUN_CAP, WIP_CEILING − in_flight))`, so anything counted as in flight that is not
actually being worked ratchets the ceiling down — and because the count only ever goes up while the
queue stops draining, it fails silently, with no error anywhere.

So the line is drawn at **will this move without a person**:

| Session status | In flight? | Why |
| --- | --- | --- |
| `running` | yes | a turn is on a worker |
| `waiting` | yes | queued for a worker, asleep on a wake it armed for itself, or held at the spot gate — it resumes on its own |
| `needs_input` | **no** | it has stopped and handed the work to a human |
| `archived`, `failed` | no | the session has ended |

**A session parked holding an open PR is not in flight.** It is spending no compute, no agent is
advancing it, and it can sit in `needs_input` for days — so counting it lets a handful of finished
items hold the whole WIP ceiling shut. That cut lands exactly on the fleet's own protocol rather
than beside it: a session whose PR is merely waiting for the merge gate to rate it *sleeps* on a
bounded self-wake, which is a `waiting` session and stays in flight; it comes to rest in
`needs_input` only once a human is what the PR is waiting on.

Those parked items are not hidden. `counts.parked` is reported beside `counts.in_flight` on every
read surface — the REST index, `get_work_backlog`, `pull_work_backlog_items` — and
[the Issues view](/operate/issues-view/) renders them as their own section, because "these are
waiting on you" is usually the answer to "why is the queue not draining".

They are also **listable**, not only countable: `status` accepts `in_flight`, `spot_held`, `parked`
and `claimed` alongside `queued` / `started` / `removed` / `all`, on the REST index and on
`get_work_backlog`. A count says how many; a caller told "parked is not part of your WIP
arithmetic" needs to be able to go and look at which.

These counts are of sessions **this backlog produced**, not of the whole spot population.

### `spot_held`: why a pull of zero is not always healthy

A pull of zero is a documented healthy outcome — it means the fleet already has as much in flight
as it can finish. That sentence is true when the ceiling is full of work being *done*. It is false,
and was reported as true for two days in September 2026, when the ceiling is full of work the
**spot gate has never started** ([#1103](https://github.com/tadasant/zimmer/issues/1103)).

A session the gate holds before its first turn is `waiting`, so it is in flight by the table above.
Nothing is advancing it and it burns no compute — it is dormant at the door. With enough of them,
`in_flight` sits at the ceiling, the pull evaluates to zero every night, and the report says healthy
while the fleet is idle.

`counts.spot_held` is the number that tells the two apart. It is a **subset of `in_flight`**, not a
fourth slice beside it, and held items deliberately **keep** their WIP slot:

- A **parked** item waits on a *person*. Nothing the fleet does brings it back, so counting it lets
  finished work hold the ceiling shut. It is excluded.
- A **spot-held** item waits on *quota*. It is assigned work that will run: `SpotSessionHold`
  re-checks it on its own backoff ladder (clamped to an hour) and starts it with no pull involved.

That difference is why a sustained hold is a **wait, not a deadlock**. When the gate opens the held
sessions start themselves, run, finish, and release the ceiling — the backlog resumes draining
without anybody touching it. Excluding them from `in_flight` would make things worse, not better:
the groomer would pull fresh items into a fleet that cannot start them, growing the held pile so
that all of it resumes at once against a freshly refilled budget and blows the same pacing curve
the hold exists to enforce.

So the fix is to the **reporting**, not to the arithmetic. A pull of zero is still correct under a
hold; what changed is that the run can now say which zero it is.

**`spot_held` names a population, not a cause, and the cause inverts the reading.** The gate refuses
for two opposite reasons and this count cannot tell them apart — it is the same "held before a turn"
figure [`get_spot_policy`](/sessions/spot-and-priority/) reports:

| Ceiling holding the gate | What a large `spot_held` means | Is a pull of zero healthy? |
| --- | --- | --- |
| `fleet_cap` | every session slot is taken — the fleet is **busy** | **yes** |
| `spot_budget`, `pacing_curve` | a quota window is spent or ahead of its curve — the fleet is **idle** with capacity to spare | no, though zero is still the right pull |

So anything drawing a conclusion from the number asks `get_spot_policy` which ceiling is holding,
and reports both:

> pulled 0 — 20 in flight against a ceiling of 20, but 14 of those are held at the spot gate on
> `pacing_curve`, so the fleet is idle behind quota rather than busy

The Issues view splits the same way, and names the population rather than a cause: its "In flight"
header reads *"6 an agent is still advancing, 14 held at the spot gate before a turn"* whenever any
are held.

**This narrows what `in_flight` overstates; it does not close it.** A session the ceiling paused
mid-run, or one parked on an auth outage, is also `waiting` and also being advanced by nobody, and
neither is split out here — they belong to their own populations with their own resume owners. See
[Limitations](/limitations/).

**Nothing bounds the parked pile, and that is a deliberate open edge.** Narrowing `in_flight` also
removes the only thing that indirectly limited how many finished-but-unmerged sessions the backlog
could accumulate: parked sessions are outside `SpotGateService`'s fleet cap too, and `needs_input`
is a non-reapable status, so each one holds its clone. If merging stops for a fortnight the pull
keeps pulling while `parked` climbs. The rule for a groomer is therefore a second condition rather
than a second number: when `parked` keeps growing, the useful action is to get those PRs merged,
not to pull more. See [Limitations](/limitations/).

## When a row leaves the queue and goes nowhere

A row leaves `queued` by two routes. A pull marks it `started` and spawns a session; a pull's
mechanical removal marks it `removed` with the fact it observed. **Neither route has a way back**,
and nothing reads the row again — `WorkBacklog::Ranking` and the pull both look only at `queued`
rows. So when the premise expires, the item is neither queued nor being worked, and nothing says
so. On 2026-09-11, 41 of 159 open convergent issues across the gated repos were `started`, and 13
had been for four days or more.

`WorkBacklogLivenessSweepJob` (hourly, `WorkBacklog::LivenessSweep`) re-checks those rows and
records what GitHub currently says in `liveness_state`. It takes every row whose verdict can still
change before any row that is settled (`issue_closed` or `superseded`), and within each group the
least-recently-checked first:

| Found | `liveness_state` | Stranded? |
| --- | --- | --- |
| The issue is closed | `issue_closed` | No — resolved |
| An open PR referencing it moved within `STALE_PR_AFTER` (14 days) | `pr_open` | No — someone is on it |
| The only open PRs referencing it have gone quiet | `pr_stalled` | Yes |
| A merged PR references it, but the issue is still open | `pr_merged_issue_open` | Yes — **ambiguous**, see below |
| No PR has ever referenced it | `no_pr` | Yes |
| GitHub could not be read | `unknown` | Yes — re-checked next pass |
| A newer row carries the same key | `superseded` | No — someone already re-queued it |

### It puts nothing back, and that is the design

The obvious fix — re-queue a `started` row whose session ended with the issue still open — is
wrong. On 2026-09-11 a session examined 12 such rows by hand and found: **6 deliberate partial
completions**, where the PR fixed part of the issue and said so ("Addresses #419 … auto-closing on
merge would drop a known, still-live production gap") and a real remainder is outstanding; **4
fully done**, where the work merged and the PR simply carried no closing keyword; **2 with an open
PR**; and **1 pulled a month after its fix had already merged**.

**The first two groups are indistinguishable by any mechanical signal.** Both are "issue open, a
merged PR references it, no closing keyword". Separating them took reading each PR's scope section
and checking whether the defect still existed in `main` — a judgement per issue. A sweep keyed on
"session archived and issue still open" re-queues the finished four; one keyed on "a merged PR
references the issue" closes the six with a remainder. Both destroy something, so the sweep makes
the only call a cron job is entitled to make: it classifies, and a human or an agent decides.

Putting an item back is then an ordinary `append_work_backlog_item`. Appending on a key whose only
row is `started` creates a fresh `queued` row and leaves the old one as history — confirmed 6 of 6
on 2026-09-11.

### The three ways a row strands, and the one this misses

1. **`started` rows whose session ended** — covered.
2. **`removed` rows whose removal was provisional** — covered. A pull may remove an item because
   the issue has an open PR, or because a session is already working it. Both are facts with a
   shelf life: `zimmer#522` was removed as `issue_has_open_pr` and that PR has not been touched
   since 2026-08-21. `trust_failed` is deliberately excluded — a judgement about the thread has no
   expiry to re-check — and so is `issue_closed`, which is terminal.
3. **Issues with no backlog row at all** — **not covered, and cannot be from here.** Before
   2026-08-29 the gate started sessions itself, and the migration into this table imported only
   `queued` items, so that work left no row. `zimmer#368` sat 37 days that way. Those issues appear
   on the Issues view under "In GitHub, not on the queue"; reaching them would take a sweep over
   GitHub rather than over this table.

### Where the count shows up

The rows the re-check has not resolved are the `stranded` population: a **Stranded** section and
count on [the Issues view](/operate/issues-view/), `status: "stranded"` in `get_work_backlog` and
the REST index, and `counts.stranded`. Because nothing clears it automatically, it is a triage
queue rather than a fault counter.

**The Issues view checks the stored verdict against its live GitHub read.** A row whose issue the
page's snapshot shows closed is left out of the section and the count, whatever `liveness_state`
says. `tadasant/zimmer#173` is why: it closed at 21:57 on 2026-09-12 and was still listed as
stranded, as `pr_merged_issue_open`, over an hour later. The page writes nothing back. An issue the
snapshot does not hold, and an issue that is still open, keep their stored verdict, because only the
sweep reads the pull requests that decide whether an open issue is stranded.

`get_work_backlog`, the REST index and the alert read the stored verdict alone. The alert is
computed straight after a pass, and settled rows go last, so every stranded row has just been
re-checked when the alert is computed, as long as there are fewer than `MAX_EXAMINED_PER_SWEEP`
(200) of them. The other two can be up to one pass behind the page. See
[Limitations](/limitations/#stranded-reads-outside-the-issues-view-lag-by-up-to-a-sweep-pass).

Settled rows go last because the candidate population only grows: a row whose issue closed stays
a candidate for good. In a plain least-recently-checked round-robin, most of each pass's 200 would
go to re-confirming closed issues, and a stranded row would wait several passes for its turn, with
no upper bound on the lag.

Every pass logs what it examined and the age of the oldest stranded row — at WARN when a repo could
not be read, INFO otherwise, since production exports WARN and above
([#584](https://github.com/tadasant/zimmer/issues/584)). The backstop is an alert: when the oldest
unresolved row passes `ALERT_AFTER` (7 days), the sweep pages `#alerts` — because a population
nothing drains needs an upper bound that is not a person remembering to look.

### The alert has to reach a human more than once

The first version of that alert could page **exactly once in its life**, and did
([#1175](https://github.com/tadasant/zimmer/issues/1175)). It reported one constant fingerprint
through `ErrorReporter` and did nothing else, and GlitchTip's *new issue → Slack* alert notifies an
issue at most once, ever — the property that keeps a crash loop from flooding `#alerts`. So the
first hour paged and every hour after it was silent, while the population it exists to bound grew
unwatched. That is the same invisible growth the sweep was written to end, so it must not be how the
detector itself fails.

Two surfaces now, each doing a different half.

**The page is an ERROR log record.** A non-staging Zimmer ERROR trips the
`zimmer_backend_log_errors` Grafana rule, and that rule [fires again every time it goes from normal
to alerting](/operate/observability/#an-error-record-is-the-alert-that-can-fire-twice), where a
GlitchTip issue notifies once and is then spent for good. It is a *notification*, not a standing
alert: one record per page means the rule resolves by itself minutes later, and the standing count
stays where it already lives — the Stranded section of the Issues view, and `get_work_backlog`.

**The GlitchTip event's fingerprint carries a severity band**, so a *worse* population is a
genuinely new issue with its own one-time notification, and a steady one keeps the issue it already
has. The band is two coarse numbers:

| Dimension | Moves when |
| --- | --- |
| `weeks` | the oldest row's age passes another multiple of `ALERT_AFTER` (7 days) |
| `rows` | the count climbs through the next step of `ALERT_ROW_BANDS` — 1, 10, 25, 50, 100, 250, 500, 1000 |

A page costs a real step change in one of those, and the band it was sent for is then remembered for
`ALERT_BAND_TTL` (also 7 days). So a population of 21 rows whose oldest has sat 9 days pages on the
hour it is first seen, says nothing for the next five days, and pages again when that row reaches 14
days — thereafter about one page a week, never an hourly flood, and never the permanent silence this
replaced. A count climbing 21 → 60 pages on the pass that crosses 50, without waiting for the week.

**The remembered band is a high-water mark that expires**, and both halves of that are load-bearing.
A band that followed the population *down* would page on every upward re-crossing of a boundary, so
a count flickering 49 ↔ 50 would page hourly. A high-water mark that never expired would instead go
quiet for weeks after triage took the oldest rows off, because the remainder cannot beat a mark it
has already dropped below. Expiring the mark after a week gives the second without the first.

Two more rules. A pass that **could not read a repo** says nothing at all: every row it could not
probe is recorded `unknown`, which counts as stranded, so rows long since closed re-enter the
population at their original age and both halves of the band jump — a false page, and a poisoned
mark if it were remembered. And a population that **clears** forgets its band altogether, on the
empty pass, which is why `alert_if_overdue` runs even when there was nothing to examine — so the next
population starts from its first week rather than being measured against one that is gone.

The band lives in `Rails.cache` — Redis everywhere but `test`, which runs a `:null_store`. Before it
pages, the sweep writes a throwaway token to a probe key and reads it back; a store that cannot
remember fails that check, and the sweep then stays **silent** on purpose. An hourly page nothing can
throttle would flood the channel every real page on this deployment travels, and a cache that has
stopped answering is alerted on loudly in its own right. The probe is a separate key from the band
precisely so that failing it can never leave a band written that no page went out for.

## The import

The existing file is imported by a [one-time post-deploy
task](/operate/deploying/#one-time-post-deploy-tasks), `ImportWorkBacklog`, so no shell on the
production box is involved. It only inserts, keyed on each item's `id` in any status, so a second
pass writes nothing; it never edits or deletes a row, and never touches the source file. The
file's precedences arrive verbatim and no re-rank runs, so the queue comes out in the order the
file was stored in.

The source is resolved in order: an explicit path, then `WORK_BACKLOG_SOURCE_PATH`, then GitHub
via the `gh` credential every Zimmer container already carries. Outside production a source it
cannot reach is recorded on the task's ledger row and the task completes; in production it fails
loudly rather than claiming to have imported a queue it never read.

## Reading the queue as a human

[The Issues view](/operate/issues-view/) is the page in front of this table: the queue in rank
order joined to live GitHub issue state, a **Promote** button on every queued row, and a trend
chart of open-issue counts over time. Promote does not post to `start_now`: it goes to a separate
browser-only controller that calls the same `WorkBacklog::Start`, deliberately away from the
API-key surface every agent session holds.

## The frozen file

The gate and groomer skills in the companion repo were cut over to these tools on 2026-09-03.
`WORK_BACKLOG.json` is kept there as the snapshot this table was seeded from, and is written only by
the gate's fallback when `append_work_backlog_item` errors.
