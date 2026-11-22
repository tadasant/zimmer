---
title: Your board v2
description: The dashboard's category tab — the same sessions as Your board, grouped into flat categories you make and drag sessions into by hand, most recently touched first inside each.
---

`/?view=board_v2` is the **Your board v2** tab, beside [Your board](/sessions/user-view/). It shows
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
| Put a session in a category | Drag the row by its handle (the dots on its left) into the category. Drag it into Uncategorized to take it out. |
| Reorder categories | Drag a category by the handle in its header. |
| Collapse a category | The chevron in its header. Stored on the category, so it stays collapsed across reloads and devices. |
| Snooze or backlog a category | The **Snooze** button in its header. See below. |

Every row is the [Your board row](/sessions/user-view/#what-a-row-shows), so Merge, Snooze, CarPlay
fit and Trash are all there and behave identically.

## The order inside a category

**Most recently touched first.** "Touched" is the last time a person opened, messaged or acted on
the session — `metadata.last_user_activity_at` — falling back to when the session was created. It
is the same rule as the **Last Touched** tab and `get_user_view`'s `order: "last_touched"`.

It is deliberately not `updated_at`. Every heartbeat, transcript append and status write bumps
`updated_at`, so sorting on it would order each category by which agent was most active, not by what
you were last on. Dragging a session into a category does not count as touching it either: the row
lands where its own last-touched time puts it.

Dragging a row within its own category does nothing; it settles back into that order. Unlike Your
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
