---
title: The Issues view
description: The fleet's work backlog joined to live GitHub issue state across five repos — the queue in rank order, a promote button, and a trend chart reconstructed without a snapshot table.
---

The [work backlog](/operate/work-backlog/) is what the fleet works from. GitHub is where the work
actually lives. **Issues** (`/issues`, between Quotas and Settings) is the one page that shows both,
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

**In GitHub, not on the queue** is every open issue across the five repos with no live backlog row —
held by the gate, unrated, or simply not picked up yet. This is the half that makes the page "what
is going on in GitHub" rather than only "what is queued", and it is where the honest number lives:
at the time of writing the queue holds ~140 items against ~500 open issues.

The filter bar is [`WorkBacklog::Filters`](/operate/work-backlog/#how-an-item-becomes-a-session) — the same
object the REST index and the `get_work_backlog` MCP tool use, so a question asked on this page and
the same question asked by the groomer cannot come back with different answers. Repo and direction
narrow both halves of the page; the queue-only filters (kind, cost, hand-placed) narrow the queue
and leave the GitHub list alone rather than silently emptying it.

## Promote

**Promote** starts one queued item as a `priority` session immediately: the same
`WorkBacklog::Start` the groomer's pull calls, at `priority` instead of `spot`, spawning a
`zimmer-router` session with the `open-reviewed-green-pr` goal, prompted with the issue URL. The
session is created and the item marked `started` in one transaction under the ranking lock, so a
click that races a pull cannot start the same item twice — the second one is told the item is no
longer queued and nothing is spawned.

The button posts to `WorkBacklogPromotionsController`, which is an `ApplicationController`
descendant. That is the point: `Api::V1::WorkBacklogItemsController#start_now` does the same thing,
but `Api::BaseController` authenticates an API key the whole agent fleet shares, so a form posting
there would put the human's lever back within reach of the thing it is being kept from. Promoting,
pinning and removing have no MCP tool for the same reason.

:::caution[This is not an authenticated human]
Zimmer's browser surface authenticates nobody — the perimeter is the tailnet, and agent sessions run
inside it ([#371](https://github.com/tadasant/zimmer/issues/371),
[#220](https://github.com/tadasant/zimmer/issues/220)). This boundary rules out a promote over the
shared API key, on the REST and MCP surfaces a session is actually offered. It does not rule out an
agent that goes looking for the route; CSRF means it would have to fetch a token off a Zimmer page
first, which is a speed bump, not a boundary. The page says so where the button is.
:::

## Where "convergent" and "divergent" come from

An issue's **direction** — does it close a gap the fleet already knows about, or open new surface
area — has three possible sources, and none of them is complete on its own. `Issues::Direction`
resolves them in order and the pill's tooltip says which one answered:

1. **The GitHub label**, `convergent` or `divergent`. GitHub is the source of truth and the issue
   gate applies the label on every rating, so this is where the answer lives.
2. **The backlog row's `scope_direction`**, for an issue the gate queued.
3. **The most recent `issue_work` gate decision** for that issue URL — the ledger covers everything
   the gate ever rated, including issues that never reached the queue.
4. Otherwise **unrated**, said out loud rather than guessed. That count is the pile the gate has not
   reached, and it is one of the more useful numbers on the page.

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
there is no second token to rotate. Two searches per repo, ten in all, run concurrently:

```
repo:<repo> is:issue is:open
repo:<repo> is:issue is:closed closed:>=<180 days ago>
```

The widest window is always the one fetched, so the 30- and 90-day views are slices of the same read
rather than three loads of GitHub.

The transformed result goes in `Rails.cache` for **five minutes**, and the page states how old the
read is with a **Refresh** button beside it. The cache is a request-coalescer, not a mirror: a cold
load is a few seconds, a cached one is well under a second, and clicking between windows, segments,
filters and pages costs one GitHub read rather than a dozen. There is deliberately **no mirror table
of issue state** — a poller writing issue rows into Postgres buys a fast page at the cost of a
second, always-slightly-wrong copy, and a page showing "open" for an issue closed ten minutes ago is
worse than a page that takes a second to load.

A repo whose search fails is **named on the page with the reason**, and the other four still render.
A repo silently showing zero open issues reads as good news, which is the one thing a failure must
never look like.

## What has no MCP counterpart, and why

`get_work_backlog` already answers the queue half of this page, and the human-only operations
(`start_now`, `pin`, `unpin`, `remove`) are REST-and-browser only
[on purpose](/operate/work-backlog/#who-may-do-what). The GitHub-joined view — the trend series, the
direction chain, the loose-issue list — has **no MCP tool and is not getting one**: an agent that
wants GitHub issue state has `gh` and the GitHub MCP servers already, and a Zimmer tool that
re-serves a cached five-minute-old copy of it would be a worse answer with an extra hop.
