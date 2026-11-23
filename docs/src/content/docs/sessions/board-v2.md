---
title: Your board v2
description: The dashboard's category tab — the same sessions as Your board, drawn as Last Touched cards and grouped into flat categories you make and drag sessions into by hand, most recently touched first inside each.
---

`/?view=board_v2` is the **Your board v2** tab, beside [Your board](/sessions/user-view/), and the
iOS app's default view (see [On the iOS app](#on-the-ios-app)). It shows
the same sessions — every filter the dashboard applies narrows it exactly as it narrows Your board —
grouped into **categories you make yourself**. Your board is unchanged; v2 is there to try, side by
side.

## Categories are manual

A category is a name and nothing else. You create one with the **New category** box at the top of
the tab, rename it from its header, and delete it from its header. They are flat: there is no
nesting.

A session is in a category because a person dragged it there. Nothing assigns one on its own — no
categorizer, no heuristic, no suggestion. Every new session starts in **Uncategorized**, the group
at the top, which is the pile you sort from.

Deleting a category moves its sessions to Uncategorized. Nothing else about them changes.

| Do | How |
| --- | --- |
| Put a session in a category | Drag the card by its grip, the grey tab down its left edge. While you drag, a **Drop on a category** bar appears at the bottom of the screen with Uncategorized and every category in it, snoozed and backlogged ones included: drop the card on one. You can also drop it straight onto a category's own list. Drop it on Uncategorized to take it out. |
| Reorder categories | Drag a category by the handle in its header. |
| Collapse a category | The chevron in its header. Stored on the category, so it stays collapsed across reloads and devices. |
| Snooze or backlog a category | The **Snooze** button in its header. See below. |

Every session is drawn as the **Last Touched** card — the same partial, not a copy — with the drag
grip beside it. So a card on v2 shows what it shows on Last Touched (status, title, agent root,
genesis and class, cost, PR link) and has the same controls: Snooze and backlog in its **⋯** menu,
Trash with Undo, and View. Your board's heavier row (the status summary, its freshness line, CarPlay
fit, Merge, the precedence readout) is not on v2. Inside a category the cards wrap into the Last
Touched grid, so a wide screen shows several side by side and a phone shows one column.

### Why the drop bar

Cards are tall, and Uncategorized is drawn first, so on a busy board most categories start
several screens below the card you want to move. Carrying a card that far means holding it at the
edge of the screen while the page scrolls, which on a phone is close to impossible. The bar puts
every category within one short drag of wherever the card started. It is shown only while a card
is in hand, and lists every category, the snoozed and backlogged ones after the rest. A card
dropped on a snoozed or backlogged category is filed there and leaves the board with its category;
the count beside that category in *Snoozed & backlogged categories* goes up by one, and the card
comes back with the category. The bar is a scrolling box capped at 40% of the screen, and the
snoozed and backlogged targets come last in it, so on a board with many categories they can sit
below its fold while a card is in hand.

The grip takes the touch for the drag rather than for scrolling, so on a phone or tablet: press the
grip, hold for a moment, then drag. Anywhere else on the card scrolls the page as usual.

## The order inside a category

**Most recently touched first.** "Touched" is the last time a person opened, messaged or acted on
the session — `metadata.last_user_activity_at` — falling back to when the session was created. It
is the same rule as the **Last Touched** tab and `get_user_view`'s `order: "last_touched"`.

It is deliberately not `updated_at`. Every heartbeat, transcript append and status write bumps
`updated_at`, so sorting on it would order each category by which agent was most active, not by what
you were last on. Dragging a session into a category does not count as touching it either: the card
lands where its own last-touched time puts it.

Dragging a card within its own category does nothing; it settles back into that order. Unlike Your
board, nothing on v2 writes `precedence`.

## Snoozing or backlogging a whole category

A category carries the same `visibility` and `snoozed_until` pair a session does, with the same
snooze presets, the same browser-timezone handling and the same rule that a snooze
[ends by being read](/sessions/board-visibility/). It can be `snoozed` until a time, `backlogged`,
or `visible`. It cannot be `hidden`.

It applies to the category **as a unit**. A snoozed or backlogged category leaves v2's main list,
sessions and all, and sits in **Snoozed & backlogged categories** at the bottom as a header with a
session count and a **Wake** button. When a snooze runs out it is simply back. A session dragged into
a snoozed category is hidden with it.

It never writes its sessions' own visibility. Each session keeps whatever it had, so waking the
category brings back exactly the sessions that were in it, and Your board — which knows nothing of
categories — keeps showing them. That is the reason for the unit design over snoozing every session
in the category: a fan-out would lose each session's own snooze state on wake, would not cover a
session dragged in later, and would reach into Your board, which v2 is meant to leave alone.

The dashboard's **Board visibility** filter applies to sessions, not categories: choosing
*Backlogged* or *All* shows backlogged sessions inside the visible categories, but a snoozed or
backlogged category stays in the tray until you wake it.

Like all board visibility it is **presentation only**. It does not touch `status`, scheduling class,
precedence, the spot queue, triggers or wake-ups. A session in a snoozed category runs exactly when
it would have run otherwise.

## The cap

The tab draws at most 500 sessions across all visible categories, chosen by last touched, so on a
very large board it is the least recently touched sessions that drop off, wherever they sit. It
says so when it has truncated. Sessions in snoozed and backlogged categories are only counted, not
fetched, so a big parked category never crowds out the live ones.

## On the iOS app

Your board v2 is the [iOS app](/extend/ios-app/)'s **default view** — the one it opens on until you
pick another from the view menu, which it then remembers. It draws the same groups in the same order,
with Last Touched's compact rows rather than Your board's, read from
`GET /api/v1/sessions?view=board_v2`, which answers the rows and the categories together.

| Do | How, on the phone |
| --- | --- |
| Put a session in a category | Press and hold the row, then **Move to Category**, and pick one (or Uncategorized). |
| Collapse a category | Tap its header. Stored on the category, as on the web. |
| Wake a snoozed or backlogged category | **Wake**, in *Snoozed & backlogged categories* at the foot. |

A search on the phone draws its hits flat, most recently touched first, so a hit in a collapsed or
tucked-away category is never hidden. Creating, renaming, deleting, reordering, snoozing and
backlogging categories are on the web tab and MCP only.

## Over REST

`GET /api/v1/sessions?view=board_v2` answers the rows the tab draws, in its order, each with its
`board_category_id`, plus `board_categories`: every category in board order, the ones off the board
last with `on_board: false` and a `session_count`. One page, capped at 500, with `truncated`, as the
User view. The writes are `PATCH /api/v1/sessions/:id/board_category`,
`PATCH /api/v1/board_categories/:id` (`collapsed`) and `PATCH /api/v1/board_categories/:id/visibility`.
See the [REST API](/extend/rest-api/).

## Over MCP

`manage_board_categories` (the `sessions` tool group) does everything the tab does: `list`,
`create`, `rename`, `delete`, `reorder`, `set_collapsed`, `set_visibility` and `assign` (put a
session in a category, or back in Uncategorized). Its description tells an agent to assign only when
a person asked; there is no "suggest" action.

## Data

| Table / column | Holds |
| --- | --- |
| `board_categories` | `name`, `position`, `collapsed`, `visibility`, `snoozed_until` |
| `sessions.board_category_id` | The category, or `NULL` for Uncategorized. `ON DELETE SET NULL`. |

These are new rather than the old `categories` table and `sessions.category_id`, which the removed
auto-categorizer left behind and which wait to be dropped (see
[What replaced what](/sessions/user-view/#what-replaced-what)). Reusing them would have brought back
the auto-categorizer's assignments, and v2 holds only assignments a person made.
