---
title: The User view
description: The dashboard's decision board — one list of every session the filters match, with Trash, Snooze and Merge on the row, and a Reprioritize button that hands the ordering to an agent.
---

`/?view=user` is the dashboard's default and the screen Zimmer is meant to be read on. It is one
list of every session the filters match, and every decision you can take on a session is **on the
row**. Nothing here asks you to open a session to find out what it is.

That is the whole design premise. A board of fifty sessions parked in `needs_input`, each holding a
pull request waiting for a merge call, is untenable if the only way to judge one is to click into
it. So the row carries what the judgement turns on — the title, the status, the agent root, Zimmer's
own [status summary](/sessions/status-summary/) of where the session stands, and the PR with its
lifecycle state and CI colour — and three buttons that act without leaving the page.

## What a row shows

| | |
| --- | --- |
| **Title** | Opens the session in the right-side drawer on a plain click, so you keep your place. Middle-click and ⌘/Ctrl-click still open a new tab. |
| **Priority / Spot badge** | Which half of the ordering this row is in. The list is not split into sections, so this badge is the only thing that says it. |
| **Status** | The same status pill the cards carry. |
| **Generated status** | The cached blurb an agent wrote when the session last came to rest, clamped to three lines with the full text on hover. Marked stale by **message count**, not by age: a summary rots because the session said something new, not because time passed. |
| **Agent root** | Which root the session runs as. |
| **Precedence** | Where it sits in the queue. Rewritten in place when you drag the row. |
| **PR** | The session's most recent pull request. The glyph's shape and colour carry the lifecycle state (open / merged / closed) and the dot beside it carries CI. |
| **Merge** | Offered only on an open, CI-green PR. See below. |
| **Snooze** | The [board-visibility](/sessions/board-visibility/) control. Presentation only — it does not pause, start or stop anything. |
| **Trash** | Archives the session. The same `POST /sessions/:id/archive` every other Trash affordance posts to, so the queued-message speed bump and the Undo toast come with it. |

## The order, and dragging it

Top to bottom the board is:

1. every `priority` session above every `spot` one;
2. within each, **precedence** descending (an absolute scale — 100000 comes before 50);
3. within each, oldest first.

Step 1 cannot be an `ORDER BY`: a session's [scheduling class](/sessions/spot-and-priority/) is the
one it names if it named one and its genesis's default otherwise, resolved live. So the two halves
are queried separately and concatenated. `Sessions::UserView` is that rule, and it is shared with
the `get_user_view` MCP tool so an agent reordering the board reads exactly the board you are
looking at.

**Dragging a row writes its `precedence`** — the same integer the spot queue is actually started in.
That is deliberate: reordering this board is a scheduling decision, not a display preference. The
drag names its new neighbours and the server derives the value
(`Sessions::ReorderPrecedence`), so the midpoint rule and its nudge live in one place.

Precedence cannot express "this spot session outranks that priority one", because the class is the
primary sort key and no integer beats it. A row dropped outside its own class block is therefore
**reseated into that block**: the neighbours sent to the server are the nearest rows of the same
class, and the list re-sorts itself after the write. It settles visibly rather than pretending.

There is **no paginator**, for the same reason the [Ranked view](/sessions/spot-and-priority/#the-ranked-view)
has none — a drag between two rows means nothing if one of them is on another page. The list is
capped at 500 rows instead and says so when it has truncated. At the board's own default filter
(`needs_input` only) that is an order of magnitude of headroom.

## The Merge button

**This is the one sanctioned path for an agent to merge its own work.** Zimmer's standing
convention is that it never does: the pull request is the human review gate, and a session that
opened one holds it until a person decides. The Merge button *is* that person deciding, so the
click is the sign-off.

It is offered only when the row's PR is **open and CI is green**. Nothing else counts as green —
`pending` is a run in progress, and an absent CI key means the PR has no checks at all. Clicking it
sends the session a message (`AutomatedPrompts.merge_authorization_message`) that tells it to
confirm the PR is still open, **resolve any merge conflict with the base branch first**, merge, and
then archive itself.

Three records are written, and they are not equal:

- a `HumanMessage` row, written through the same capture every web-UI input goes through. **This is
  the provenance record.** Only the browser controllers write one; the MCP and REST surfaces cannot.
- the message itself, marked `[HUMAN-AUTHORIZED MERGE]` and naming the surface. That marker is what
  the merging session reads, but it is not proof on its own — `action_session`'s `follow_up` can
  deliver any text, marker included — so an audit keys on the `HumanMessage`, not the marker.
- `merge_authorized_prs` on the session's `custom_metadata`, keyed by PR url, which is what the
  button reads to show **Merge sent**.

The claim is taken under the session's row lock with a fresh read, so two requests landing together
(two tabs, a retried POST) send one message, not two. Once the poller sees the PR merge, the button
reads **Merged**.

An authorization stops counting once the session has **come back to rest without merging** — it is
in `needs_input` again, has taken a turn since the click, and holds no undelivered copy of the
message. That is the path the message itself prescribes when a merge cannot happen (a conflict it
cannot resolve, CI gone red), and it puts the **Merge** button back so you can retry after fixing
whatever stopped it, rather than leaving the row reading **Merge sent** forever.

**The message is queued, never an interrupt.** A session parked in `needs_input` — which is the
population this button exists for — takes it immediately as its next turn. A session mid-turn gets
it at the next turn boundary rather than having work it was not asked to abort torn down. A session
asleep in `waiting` on its own self-wake is woken by it: `EnqueuedMessage`'s `after_create_commit`
schedules a drain for any session already at rest, both resting states included.

## The Reprioritize button

At the top of the board. It hands the ordering to an agent: read the rows, work out which ones the
human is most likely to want next, write the order back.

It reaches the board **over MCP**, not by scraping the page. Two tools, both in the `sessions` tool
group (so the `zimmer-sessions` catalog server carries them):

| Tool | Does |
| --- | --- |
| `get_user_view` | Returns the board in the order it is drawn, paginated, with every fact a row shows. `quick_search_sessions` is not a substitute: three of the four facts a decision turns on — the root, the blurb and the PR — are not on its rows at all. |
| `reorder_user_view` | Takes the whole ordering as one argument and writes it in one transaction, spacing the values so you can still drag any row afterwards. Partial orders are fine: sessions you do not list keep their own rank, below the ones you do. |

**It is one durable session, reused, not one per click.** A session per press would leave a trail of
them in the action queue this view exists to empty, and each would start cold. So the button fires a
[trigger](/sessions/triggers/) — `Dashboard reprioritizer`, seeded on first press — with
`reuse_session` and `resuscitate_archived` set. The second press lands as a follow-up in a
conversation that already knows what this board is and what it did last time. The trigger is
`disabled`, because it must never fire on its own: it is a template a button invokes, and
`Triggers::ManualFire` deliberately does not filter on status, exactly as the Invoke button on the
trigger page relies on.

The session runs as the `dashboard-reprioritizer` agent root. Its ranking policy is in the trigger's
prompt, so it is editable at `/triggers` without a deploy: easy decisions that unblock other work
first, then anything asked for with stated priority, then cheap decisions over expensive ones, then
work stuck on a person over work stuck on a machine.

It suggests an order; it does not impose one. Every row is still draggable afterwards.

## What replaced what

The User view replaced the **Categories** view — the category-grouped card grid that was the
dashboard's desktop default. Categories themselves are untouched as a data concept:
[auto-categorization](/sessions/categorization/) still runs, `category_feedback_events` are still
recorded, and categories are still managed through the `manage_categories` MCP tool, the REST API
under `/api/v1/categories`, and the `/supervisor` dashboards. What went is the *grid*: the
per-category sections, their drag-and-drop, the pinned Starred group, the per-category paginator and
the per-category Refresh buttons.

A cookie that still says `categories` is remapped to `user`, so an operator who had chosen the grid
lands on the view that replaced it rather than silently on the mobile default.
