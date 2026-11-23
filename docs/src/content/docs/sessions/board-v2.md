---
title: Your board
description: The dashboard's decision board — the sessions the filters match, drawn as Last Touched cards and grouped into flat categories you make and drag sessions into by hand, most recently touched first inside each.
---

`/?view=board_v2` is **Your board**, the dashboard's desktop default and the
[iOS app](/extend/ios-app/)'s default view (see [On the iOS app](#on-the-ios-app)). It shows every
session the dashboard's filters match, grouped into **categories you make yourself**. A phone's
browser opens on **Last Touched** instead, until you pick a view; the choice you pick is kept in a
cookie.

The URL value is `board_v2` because the iOS app and `GET /api/v1/sessions?view=board_v2` already
use it. Older values that named a board are remapped rather than rejected: a bookmarked `?view=user`
or `?view=categories` gets a 302 to `?view=board_v2` with every other parameter kept, and a view
cookie holding `user` or `categories` resolves to this board (`LEGACY_VIEW_MODES` in
`SessionsController`).

## Categories are manual

A category is a name and nothing else. You create one with the **New category** box at the top of
the board, rename it from its header, and delete it from its header. They are flat: there is no
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
grip beside it. So a card on the board shows what it shows on Last Touched (status, title, agent root,
genesis and class, cost, PR link) and has the same controls: Snooze and backlog in its **⋯** menu,
Trash with Undo, and View. The board does not show a session's status summary, its CarPlay-fit
chip, a Merge button or its precedence (see [Limitations](/limitations/#the-web-board-has-no-merge-button-and-no-status-summary)).
Inside a category the cards wrap into the Last
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

Dragging a card within its own category does nothing; it settles back into that order. Nothing on
the board writes `precedence`: the spot queue's order is set on the
[Ranked view](/sessions/spot-and-priority/#the-ranked-view).

## Snoozing or backlogging a whole category

A category carries the same `visibility` and `snoozed_until` pair a session does, with the same
snooze presets, the same browser-timezone handling and the same rule that a snooze
[ends by being read](/sessions/board-visibility/). It can be `snoozed` until a time, `backlogged`,
or `visible`. It cannot be `hidden`.

It applies to the category **as a unit**. A snoozed or backlogged category leaves the board's main list,
sessions and all, and sits in **Snoozed & backlogged categories** at the bottom as a header with a
session count and a **Wake** button. When a snooze runs out it is simply back. A session dragged into
a snoozed category is hidden with it.

It never writes its sessions' own visibility. Each session keeps whatever it had, so waking the
category brings back exactly the sessions that were in it, and the views that know nothing of
categories (Last Touched, Created, Ranked) keep showing them. That is the reason for the unit design
over snoozing every session in the category: a fan-out would lose each session's own snooze state on
wake, would not cover a session dragged in later, and would hide the sessions from those views too.

The dashboard's **Board visibility** filter applies to sessions, not categories: choosing
*Backlogged* or *All* shows backlogged sessions inside the visible categories, but a snoozed or
backlogged category stays in the tray until you wake it.

Like all board visibility it is **presentation only**. It does not touch `status`, scheduling class,
precedence, the spot queue, triggers or wake-ups. A session in a snoozed category runs exactly when
it would have run otherwise.

## The cap

The board draws at most 500 sessions across all visible categories, chosen by last touched, so on a
very large board it is the least recently touched sessions that drop off, wherever they sit. It
says so when it has truncated. Sessions in snoozed and backlogged categories are only counted, not
fetched, so a big parked category never crowds out the live ones.

## On the iOS app

Your board is the [iOS app](/extend/ios-app/)'s **default view**: the one it opens on until you
pick another from the view menu, which it then remembers. It draws the same groups in the same order,
with Last Touched's compact rows, read from
`GET /api/v1/sessions?view=board_v2`, which answers the rows and the categories together.

| Do | How, on the phone |
| --- | --- |
| Put a session in a category | Press and hold the row, then **Move to Category**, and pick one (or Uncategorized). |
| Collapse a category | Tap its header. Stored on the category, as on the web. |
| Wake a snoozed or backlogged category | **Wake**, in *Snoozed & backlogged categories* at the foot. |

A search on the phone draws its hits flat, most recently touched first, so a hit in a collapsed or
tucked-away category is never hidden. Creating, renaming, deleting, reordering, snoozing and
backlogging categories are on the web board and MCP only.

## Over REST

`GET /api/v1/sessions?view=board_v2` answers the rows the board draws, in its order, each with its
`board_category_id`, plus `board_categories`: every category in board order, the ones off the board
last with `on_board: false` and a `session_count`. One page, capped at 500, with `truncated`.
`view=user` is accepted as an alias and answers exactly the same, so an older iOS build still gets a
board. The writes are `PATCH /api/v1/sessions/:id/board_category`,
`PATCH /api/v1/board_categories/:id` (`collapsed`) and `PATCH /api/v1/board_categories/:id/visibility`.
See the [REST API](/extend/rest-api/).

## Over MCP

`get_user_view` reads the board in this order by default (`order: "board"`): Uncategorized, then
each category on the board, most recently touched first inside each, with a `**Category:**` line on
every row. Rows in a snoozed or backlogged category are not listed. One line names each such
category and how many matching sessions it holds. See
[Zimmer's MCP server](/extend/mcp-server/#the-tool-surface).

`manage_board_categories` (the `sessions` tool group) does everything the board does: `list`,
`create`, `rename`, `delete`, `reorder`, `set_collapsed`, `set_visibility` and `assign` (put a
session in a category, or back in Uncategorized). Its description tells an agent to assign only when
a person asked; there is no "suggest" action.

## How the page loads

The dashboard is two requests. `/` is the shell: the header, the menu, the Filters, the Quick
Router and the view switcher. It reads the query string and your cookies and touches no session
row, so it answers in tens of milliseconds whatever the board holds. The board itself (Your board's
categories, or the card grid, or the Ranked queue) is `GET /board`, which the shell's
`<turbo-frame id="sessions_board">` asks for as soon as the page arrives. It passes the shell's own
query string, so both halves resolve the same filters and the same view. Until it lands, the
frame shows grey placeholder rows shaped like the real ones.

`/board` is its own path rather than a frame variant of `/` for the reason the session drawer's is:
Turbo's prefetch cache is keyed on the URL alone. Links and buttons inside the board navigate the
whole page, never just the frame.

Opening a session in the drawer is a third request, `GET /sessions/:id/drawer`. That body is the
heaviest thing the dashboard asks for, so the drawer does not wait for it with an empty panel: it
slides in on a grey skeleton shaped like the session header, and the skeleton's Close button already
works. The real body replaces it when it lands.

The follow-up composer does not wait for that body either. Typing needs nothing from the server, so
the skeleton carries a composer of its own, pinned where the real one sits, and you can start your
message the moment the drawer opens. Its Submit button stays disabled until the body arrives,
because whether a message is sent now or queued behind a running turn is the real form's call. What
you type there is saved as the session's draft on every keystroke. When the body lands, the real
composer takes over the text, the caret position and the focus (`lib/composer_handoff.js`), so you
keep typing without noticing the swap. A link that already knows the session is archived opens the
drawer without that composer, because the body would bring no composer to hand the text to.

The full session page (`/sessions/:id`) needs none of this. Its composer is part of its own
response, outside the lazy Transcript and provenance frames, so it is there at first paint.

A browser that has loaded Zimmer before downloads none of the page's scripts or stylesheets again.
They are digest-stamped and cached for a year (see
[Static files in `public/`](/operate/deploying/#static-files-in-public-are-not-digest-stamped)), so
the board's fetch starts as soon as the shell arrives. The *tucked away* count in the Filters legend
arrives with the board, because it is counted through every filter the board applies. After a
phone wakes the page, the reconnect backfill re-fetches `/board` to bring its rows up to date.

## The card views follow their filters live

The two card views (**Sort By Last Touched** and **Created**) update over one Turbo Stream,
`sessions_index_individual`, that every open dashboard shares. The server cannot tell which page is
filtered to what, so a changed or new session is not sent as a `replace` of its card. It goes out
as an envelope (`_card_delivery`, from `Session#broadcast_update_to_sessions_index` and
`#broadcast_create_to_sessions_index`). The envelope carries the session's filterable facts and its
card, rendered inside an inert `<template>`. The page's `session-grid` controller judges it against
the filters that page was rendered with:

| The page's filters say | What happens |
| --- | --- |
| it is on the page and still matches | the card is replaced in place |
| it is on the page and no longer matches | the card leaves |
| it is not on the page, matches, and the page may insert | the card is inserted where the sort puts it |
| anything else | the envelope is discarded |

So with **Status** set to *Needs input* alone, a card whose session goes back to `waiting` leaves,
and one that comes to rest in `needs_input` arrives without a reload. Status, scheduling class,
board visibility and CarPlay fit can all change under an open page. A change to any of them
re-sends the card, so each can take a card away or bring one in. Genesis and agent root never
change after a session is created, so they only decide whether a session the page has never shown
may be inserted.

Archiving is the same delivery. A board of live work drops the card, and a board whose operator
ticked *Archived* keeps it, reading *Trashed*. The exception is a card you trashed from this page:
it stays gone even on a board that shows every status. **Undo** puts it back through the same
envelope, so it lands in sort order, and only on a page whose filters admit the restored session. The count beside the heading and the
empty state follow the grid however a card arrived or left. That includes Trash, a snooze, Undo
and a live update. Deleting a session still sends a plain `remove`, because there is nothing left
to judge.

An insert happens only on the first page. A later page cannot tell an arrival that belongs on it
from one that belongs on an earlier page. A card that lands inside a full first page pushes the last
card on to the next page. The grid does not insert anything while a text search is narrowing it,
because only the server can evaluate the search. Cards still leave under a search. The gaps are
listed in [Limitations](/limitations/#the-card-grids-live-filtering-is-approximate-at-the-edges).

## Data

| Table / column | Holds |
| --- | --- |
| `board_categories` | `name`, `position`, `collapsed`, `visibility`, `snoozed_until` |
| `sessions.board_category_id` | The category, or `NULL` for Uncategorized. `ON DELETE SET NULL`. |

These are separate from the `categories` table and the `sessions.category_id` and
`sessions.sort_order` columns, which the removed auto-categorizer
([#16](https://github.com/tadasant/zimmer/issues/16)) left behind. They stay in the database, unread,
until a later two-phase drop. Reusing them would have brought back the auto-categorizer's
assignments, and the board holds only assignments a person made.
