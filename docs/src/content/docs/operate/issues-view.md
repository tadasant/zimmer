---
title: The Issues view
description: The fleet's work backlog joined to live GitHub issue state across six repos — the queue in rank order, the four human-only queue operations, and a trend chart reconstructed without a snapshot table.
---

The [work backlog](/operate/work-backlog/) is what the fleet works from. GitHub is where the work
actually lives. **Issues** (`/issues`, between Inference and Settings) is the one page that shows both,
joined on the issue URL: what is queued and in what order, what is running right now, what is open
on GitHub that the queue has never seen, and whether the whole pile is getting smaller.

It is a *view*. It stores nothing. Every number on it comes from `work_backlog_items`,
`gate_decisions`, or a live read of GitHub — there is no Issues table, no sync job, and nothing to
reconcile.

## The three lists

**The spot queue** is every `queued` backlog item in rank order — precedence descending, oldest
first within a tie, which is the order [`WorkBacklog::Ranking`](/operate/work-backlog/#ranking)
defines and the groomer's pull follows. Position 1 is what gets pulled next. Each row links to its
GitHub issue, carries its direction, kind, cost and precedence, says when the gate cleared it, and
links to the gate session that did if the gate recorded one.

**In flight** is every `started` item whose session has not archived or failed, with a link to that
session. It is deliberately *not* narrowed by the filter bar: "what is the fleet working on" is a
fixed question, and a repo filter that emptied the list would read as "nothing is running".

**In GitHub, not on the queue** is every open issue across the six repos with no live backlog row —
held by the gate, unrated, or simply not picked up yet. This is the half that makes the page "what
is going on in GitHub" rather than only "what is queued", and it is where the honest number lives:
at the time of writing the queue holds ~140 items against ~490 open issues.

The filter bar is [`WorkBacklog::Filters`](/operate/work-backlog/#how-an-item-becomes-a-session) — the same
object the REST index and the `get_work_backlog` MCP tool use, so a question asked on this page and
the same question asked by the groomer cannot come back with different answers. Repo and direction
narrow both halves of the page; the queue-only filters (kind, cost, hand-placed) narrow the queue
and leave the GitHub list alone rather than silently emptying it.

## Which repos

`Issues::GithubSnapshot::REPOS` is the list, and it is deliberately a constant rather than a
setting: the page is a view of one specific fleet's work, and a repo list in the database would be
a setting nobody sets.

| Repo | What it is |
| --- | --- |
| `tadasant/zimmer` | Zimmer itself — this app |
| `tadasant/strad` | The MCP gateway every Zimmer connector is served through |
| `tadasant/tadasant-internal` | The AIR catalog, the gate postures, the fleet's own prose |
| `tadasant/pi-extensions` | The Raspberry Pi extension set baked into the base image |
| `tadasant/motet` | Motet |
| `pulsemcp/air` | The AIR framework the whole agent-harness layer resolves its catalog through |

The owner is **not** uniform — `pulsemcp/air` is the odd one out — so nothing downstream may assume
it. The page still prints the short name (`air`, not `pulsemcp/air`) because repo names are unique
across the list; the per-repo cards link to the full `github.com/<owner>/<repo>/issues` path and the
repo filter carries the full name as each option's title.

Adding a seventh repo is one line in that constant. Everything that counts repos reads
`REPOS.length`, `FETCH_TIMEOUT` bounds the whole concurrent load rather than any one repo, and the
trend chart's palette has one slot per repo up to `Issues::Trend::MAX_SERIES` — which is 6, so a
seventh repo would fold the smallest series into the grey `other` bucket unless the palette grows
with it. A test pins that coupling rather than leaving it to be discovered on the page.

## The four human-only operations

The [work backlog](/operate/work-backlog/#who-may-do-what) has four operations no agent may take —
**promote**, **pin**, **unpin** and **remove** — and every queued row on this page carries all four.
This is the form they are the form for: without it the only way to pull three of those levers is a
`curl` against the REST API with the key the whole agent fleet shares, which puts them back on the
surface they were deliberately kept off.

**Promote** starts one queued item as a `priority` session immediately: the same
`WorkBacklog::Start` the groomer's pull calls, at `priority` instead of `spot`, spawning a
`zimmer-orchestrator` session with the `open-reviewed-green-pr` goal, prompted with the issue URL. The
session is created and the item marked `started` in one transaction under the ranking lock, so a
click that races a pull cannot start the same item twice — the second one is told the item is no
longer queued and nothing is spawned.

**Pin** hand-places the item at a precedence you type, and **Unpin** releases it. A pinned item is
never re-banded, renumbered or un-pinned by an agent, and it is excluded from every peer set, so one
hand-placement cannot drag future appends down with it — it may sit anywhere, including outside the
band its cost implies. The field is seeded with the row's current precedence, and its tooltip carries
the [band boundaries](/operate/work-backlog/#ranking). Unpinning re-ranks the item back inside its
band. A pinned row shows **Unpin** and no precedence field; move a pinned item by unpinning it and
pinning it again.

**Remove** takes the item off the queue with a free-text reason. This is the *discretionary* removal —
`WorkBacklog::Pull` already removes items an agent can observe are dead, with a reason drawn from a
fixed vocabulary, but only when the groomer reaches them, so an item near the bottom of the queue
whose issue closed months ago can sit there indefinitely. The row is not deleted: it stays as
history with the reason and who. Because it is the one control with no visible undo, the
confirmation names the key it is about to remove and the flash names the key it removed — and when
GitHub says the issue is closed, the reason field arrives pre-filled with `issue_closed`, the same
word the pull would eventually have used.

All three writes go through `WorkBacklog::Ranking`'s advisory lock and re-rank, exactly as the REST
actions do; nothing here reimplements the ranking.

The controls post to `WorkBacklogPromotionsController`, `WorkBacklogPinsController` and
`WorkBacklogRemovalsController`, all `ApplicationController` descendants. That is the point:
`Api::V1::WorkBacklogItemsController` does the same four things, but `Api::BaseController`
authenticates an API key the whole agent fleet shares, so a form posting there would put the human's
levers back within reach of the thing they are being kept from. None of the four has an MCP tool, for
the same reason, and `mcp_controller_test` asserts that no tool on any connection appears.

:::caution[This is not an authenticated human]
Zimmer's browser surface authenticates nobody — the perimeter is the tailnet, and agent sessions run
inside it ([#371](https://github.com/tadasant/zimmer/issues/371),
[#220](https://github.com/tadasant/zimmer/issues/220)). This boundary rules out a promote, pin, unpin
or remove over the shared API key, on the REST and MCP surfaces a session is actually offered. It
does not rule out an agent that goes looking for the route; CSRF means it would have to fetch a token
off a Zimmer page first, which is a speed bump, not a boundary. The page says so where the controls
are.
:::

## Where "convergent" and "divergent" come from

An issue's **direction** — does it close a gap the fleet already knows about, or open new surface
area — has three possible sources, none of them complete on its own, and a fourth answer for when
none of them has one. `Issues::Direction` tries them in order and the pill's tooltip says which one
answered:

1. **The GitHub label**, `convergent` or `divergent`. GitHub is the source of truth, and this is
   where the answer is moving to: the issue gate is being changed to apply the label on every
   rating, and the back-fill across the six repos is in flight. It is not yet where the answer
   lives for most issues — while this page was being built, `tadasant/zimmer` carried the labels on
   none of its 208 open issues and `tadasant/strad` carried them on 53 of 55.
2. **The backlog row's `scope_direction`**, for an issue the gate queued.
3. **The most recent `issue_work` gate decision** for that issue URL — the ledger covers everything
   the gate ever rated, including issues that never reached the queue.

Failing all three, the issue reads **unrated**, said out loud rather than guessed. That count is the
pile the gate has not reached, and it is one of the more useful numbers on the page.

Label absence is normal and always will be: the labels are applied going forward, and an issue that
predates the gate has no rating anywhere.

## The trend chart

Open-issue count per day over 30, 90 or 180 days, segmented by direction, by repo, or by the issues'
most widely-shared labels. Drag or arrow-key across it to read any day; click a series in the strip
below to hide it.

The history is **reconstructed, not sampled**. An issue was open at the end of day D exactly when it
was created on or before D and closed after D, so a set of issues carrying `created_at` and
`closed_at` *is* the history and the series is a fold over it. That is why the GitHub read fetches
closed issues within the window as well as open ones — without them the line would only ever rise.
There is no snapshot table, so there is no gap in the chart for the days before the feature shipped.

One limitation, stated on the page as well as here: the segment an issue belongs to is its
classification **today**, applied to its whole history. An issue relabelled last week reads as its
current direction for the entire window. Segment membership is a property of the issue, not an event
log of its labels, and doing better would mean a timeline request per issue.

## How GitHub is read

`Issues::GithubSnapshot` shells out to the `gh` CLI through `GithubSearchService` — the same client
and the same host credential the [PR poller and comment poller](/operate/background-jobs/) use, so
there is no second token to rotate. Two searches per repo — twelve in all — with the six repos read
concurrently and each repo's pair run in sequence on its own thread:

```
repo:<repo> is:issue is:open
repo:<repo> is:issue is:closed closed:>=<180 days ago>
```

The widest window is always the one fetched, so the 30- and 90-day views are slices of the same read
rather than three loads of GitHub.

A read in which *every* repo failed is not cached — that is a picture of GitHub being unreachable,
and holding it for the full TTL would keep the page degraded after the outage cleared. The
transformed result otherwise goes in `Rails.cache` for **five minutes**, and the page states how old the
read is with a **Refresh** button beside it. The cache is a request-coalescer, not a mirror: a cold
load is a few seconds, a cached one is well under a second, and clicking between windows, segments,
filters and pages costs one GitHub read rather than a dozen. There is deliberately **no mirror table
of issue state** — a poller writing issue rows into Postgres buys a fast page at the cost of a
second, always-slightly-wrong copy, and a page showing "open" for an issue closed ten minutes ago is
worse than a page that takes a second to load.

The two searches fail independently. "Closed in the last 180 days" is the half that grows without
bound on a fleet's own repo, so it is the one that reaches `GithubSearchService`'s 1000-result
ceiling first — and losing it must not blank a repo whose open issues were read successfully a
moment earlier. Whichever half answered is kept, and the error names which half was lost.

A repo whose search fails is **named on the page with the reason**, and the others still render.
A repo silently showing zero open issues reads as good news, which is the one thing a failure must
never look like.

## What has no MCP counterpart, and why

`get_work_backlog` already answers the queue half of this page, and the four human-only operations
(`start_now`/promote, `pin`, `unpin`, `remove`) are REST-and-browser only
[on purpose](/operate/work-backlog/#who-may-do-what). The GitHub-joined view — the trend series, the
direction chain, the loose-issue list — has **no MCP tool and is not getting one**: an agent that
wants GitHub issue state has `gh` and the GitHub MCP servers already, and a Zimmer tool that
re-serves a cached five-minute-old copy of it would be a worse answer with an extra hop.
