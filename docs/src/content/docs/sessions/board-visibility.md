---
title: Board visibility
description: Snooze or hide a session's card to tidy the dashboard. A second axis beside status that decides nothing — it changes what is drawn, never what runs.
sidebar:
  order: 11
---

There is more work queued than anyone gets to in a day. Most of it is not wrong, or stuck, or
finished — it is simply not for this afternoon. A dashboard that shows all of it equally is a
dashboard you stop reading.

**Board visibility** is the answer: a second field on a session, entirely separate from `status`,
whose only job is deciding whether the card is on screen.

| Value | Means |
| --- | --- |
| `visible` | On the board. The default; every session starts here. |
| `hidden` | Off the board until you put it back. No end time. |
| `snoozed` | Off the board until `snoozed_until`, then back on its own. |

## It decides nothing

This is the property to internalize before anything else, because the whole feature is worthless if
it is not true.

Nothing in Zimmer's scheduling reads `visibility`. Not the state machine, not the spot queue, not
precedence, not the quota gate, not triggers or wake-ups. A snoozed session is started, ranked,
followed up on and finished at exactly the moments it would have been had nobody touched it. The
only difference is that a card is not being drawn.

Setting it never starts, stops, sleeps, wakes or reorders a session. It is a single write to two
presentation columns, through `Sessions::SetVisibility`, which is the one writer behind all three
surfaces.

:::caution[Snoozing a card is not sleeping a session]
A snoozed session runs exactly when it would have run anyway — it is simply not on screen. Nothing in
the web UI sleeps a session: that is `wake_me_up_later` and `action_session`'s `pause_into_spot_queue`
over MCP ([Triggers and schedules](/sessions/triggers/)). Reading a snooze as a pause is how work you
meant to merely tidy away looks like work you stopped, so the panel says so before you click.
:::

## A snooze ends by being read

There is no sweeper job. `snoozed_until` is compared against the current time on every read, and a
snooze whose time has passed simply reads as visible:

```ruby
scope :board_visible, ->(now = Time.current) {
  where(
    "sessions.visibility = :visible OR (sessions.visibility = :snoozed AND sessions.snoozed_until IS NOT NULL AND sessions.snoozed_until <= :now)",
    visible: VISIBLE, snoozed: SNOOZED, now: now
  )
}
```

Two things follow, and both are the point.

The session comes back on its own, with no request made and no row written. And there is no
background writer that could ever race the lifecycle — which is what makes the orthogonality above
something the design guarantees rather than something the code has to remember.

The stored choice is left alone. A session whose snooze ran out last week still reads `"snoozed"` in
the column; it is `effective_visibility` that reports `"visible"`. Read the first to know whether a
snooze was ever set, the second to decide whether to draw something.

`board_hidden` is the exact complement, and `Session#board_visible?` is the row-level counterpart
that must answer identically — the dashboard filters with the scope and draws badges with the
predicate, and the two disagreeing would put a card on screen that the page believes is not there.

## Using it

**On a card.** The ⋮ menu on every session card — in the category grid, the Starred group, both flat
sort views and the search results — offers *Snooze until…* and *Hide*. The snooze panel holds a
handful of presets (later today, tomorrow, in 3 days, this weekend, next week) and a
date/time picker for anything else. The presets are computed in **your browser's** timezone, so
"Tomorrow" means your 9am.

**In the Ranked view.** The compact row's ⋮ menu carries the same two entries and the same panel.
The ranked queue is a list of work that has not started, which makes it exactly the list worth
thinning out — and snoozing a row there leaves its precedence untouched, so the queue behind it does
not move.

**On the session page.** A *Snooze* pill in the header; on a phone, a row in the bottom sheet.

## Finding a session you hid

The dashboard's **Filters → Board visibility** control has three settings: *On board* (the default),
*Snoozed & hidden*, and *Both*. When anything is tucked away, the legend says how many, so a board
that is holding cards back always says so.

Revealed cards carry a badge saying which kind of tucking-away it is and, for a snooze, when it ends
— and their menu grows a *Put back on the board* row. Nothing is ever unrecoverable.

## Over the API and MCP

Both surfaces can read, write and filter it, and both say plainly in their descriptions that it does
not affect scheduling — so neither a human nor an agent mistakes it for something that controls
whether work runs.

- **REST** — `PATCH /api/v1/sessions/:id/visibility`, and `visibility` / `effective_visibility` /
  `snoozed_until` on every serialized session. See
  [Board visibility](/extend/rest-api/#board-visibility).
- **MCP** — `action_session` with `action: "set_visibility"`, and a `**Visibility:**` line on
  `quick_search_sessions` and `get_session` results whenever a session is tucked away.

One default is deliberate and worth knowing about: **agent-facing session search is unfiltered on
this axis.** `quick_search_sessions` and `GET /sessions` return hidden and snoozed sessions unless
you explicitly pass `visibility`. Zimmer's own agents call that search to check whether a piece of
work already has a session; a session a human tidied off their board is still that session, and
hiding it from a duplicate check would produce duplicate work with no visible cause. Human-facing
boards filter by default; the machine-facing ones do not.

`set_visibility` is **not** exposed on the self-session tool group. A session tidying its own card
off a human's board is not self-management — it is editing somebody else's view.
