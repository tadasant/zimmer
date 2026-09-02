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
issue work gate ──append──►  work_backlog_items  ──pull 0–3/day──►  implementing sessions
   (priority)                  (this table)           (04:00 groomer)        (spot)
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
| `status` | `queued` → `started` or `removed` |
| `writing_session_id` | The session that appended it — stamped from the MCP connection, self-declared on REST |
| `started_session_id`, `started_by_session_id`, `started_at` | The session it became, the session that pulled it, and when |
| `removed_at`, `removed_by`, `removal_reason` | For a removed item, who and why |
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

An append lands 10 below the lowest unpinned peer of the same cost (first-in, first-out within a
band), clamped at the floor. A band that reaches its floor is re-spaced — its unpinned items
spread evenly across `[floor, base]`, order preserved — and the append retried. A band that
cannot be re-spaced past its floor raises rather than crossing into the band below, because
crossing would silently rank cheap work below expensive work.

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
| Pin or hand-place an item | a human | `PATCH …/:id/pin`, `PATCH …/:id/unpin` — **REST only** |
| Remove an item by judgement | a human | `POST …/:id/remove` — **REST only** |
| Start an item now, as a `priority` session | a human | `POST …/:id/start_now` — **REST only** |

The mechanical operations are agent-callable and the discretionary ones are not, and that split is
enforced by absence: there is no MCP tool that pins, places, removes by free-text reason, or
promotes to priority, and a test asserts none appears. The one removal an agent may make is on a
pull, with a reason drawn from a fixed vocabulary of observed facts — `issue_closed`,
`issue_has_open_pr`, `session_already_working`, `trust_failed` — not typed.

The `work_backlog` MCP tool group is **opt-in**, like `gate_decisions`: a connection has to name
it, so neither `zimmer-sessions` nor the unscoped `zimmer` server carries the writes. The queue is
read by a job that spawns sessions with no human in the loop, which makes an entry on it an
unattended implementing session; a queue every session has a pen for is not one. Like every tool
group this is a *scoping* boundary — what a session is offered — not an authorization one, since
the API key is shared by the fleet. On REST the same caveat applies to `acting_session_id`: it is
provenance, never authorization.

## How an item becomes a session

`WorkBacklog::Start` is the one place the queue becomes work. It spawns a `zimmer-router` session
with goal `open-reviewed-green-pr`, prompted with the issue URL plus "Please implement this" (an
issueless item's verbatim `prompt`), titled `Implement zimmer#498 (…)`, and tagged
`custom_metadata.spawned_by = "work-backlog"` with the item's id and key. The item is marked
`started` with that session in the same transaction, so a failed spawn leaves it queued.

A **pull** starts each item at `spot` class, as a child of the pulling session, with the rank
carried forward: the n-th item pulled gets the puller's precedence plus `(count − n + 1)`, so the
top item runs first and the tree stays contiguous. A **start now** starts one item at `priority`
class — the human's lever over the spot queue, which is why it has no MCP path.
`counts.in_flight` on the read surfaces is the number of started items whose session is still
alive: the number the groomer's WIP ceiling counts, which is sessions this backlog produced and
not the whole spot population.

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

## What is not here yet

There is no Issues view. The REST actions the view will drive — including `start_now`, the
"promote" button's server half — are built and tested; the page is the next phase. The gate and
groomer skills in the companion repo still write the JSON file until they are cut over to these
tools, and nothing here requires them to change: the table and the file coexist, and the table
was seeded from the file.
