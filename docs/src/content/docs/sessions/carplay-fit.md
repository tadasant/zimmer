---
title: CarPlay fit
description: A per-session mark saying whether the next thing a session needs from you can be done by voice from a car, or needs a laptop. Derived from the status summary at every rest, sticky for a session you touched from CarPlay, overridable by hand, and read by nothing that schedules.
sidebar:
  order: 12
---

Triage a board from a car and you hit the same wall every drive. About half the sessions parked in
`needs_input` want a credential pasted into a console, a test run on your Mac, or a long document
read. The other half want a yes or no, a merge call, or a short reply. From the driver's seat the two
halves look the same, so every drive re-triages the laptop-only rows from scratch.

**CarPlay fit** is the mark that tells them apart. It is a judgement about the session's next human
action, with a reason, a provenance and a staleness rule. It is not a tag, and it decides nothing
about when a session runs.

## What the mark holds

| Column | Values | Means |
| --- | --- | --- |
| `carplay_fit` | `carplay_ok`, `laptop_only`, or none | The decision: can the next human action be taken by voice from a car? |
| `carplay_fit_reason` | `decision`, `short_answer`, `long_read`, `manual_steps`, `credential`, `local_device`, `nothing_needed` | What kind of action the session is waiting on. |
| `carplay_fit_source` | `auto`, `human`, `assistant`, `session`, `carplay` | Who wrote the mark. `carplay` is the CarPlay-engagement default, and is only ever `carplay_ok`. |
| `carplay_fit_set_at` | a time | When. |
| `carplay_fit_line_count` | an integer | The session's transcript line count when the mark was written. |

The five travel together through one writer, `Sessions::SetCarplayFit`, which every surface calls:
the status-summary harvest, the web UI, the REST endpoint, the `set_carplay_fit` MCP action and
CarPlay engagement. A sixth column, `carplay_engaged_at`, records when a person last touched the
session from CarPlay.

## It decides nothing

Nothing in Zimmer's scheduling reads these columns. Not the state machine, not the spot queue, not
precedence, not the quota gate, not triggers or wake-ups. The board's order is untouched too: a
laptop-only session keeps its place for the laptop. The mark changes which rows a caller *asks for*,
never when anything runs. That is the same contract [board visibility](/sessions/board-visibility/)
has, and it is the one to keep.

## Derived at every rest, overridable by hand

The ordinary writer is the [status summary](/sessions/status-summary/). The fork that writes the
blurb when a session comes to rest is asked, in the same turn, to end its answer with one
machine-read line:

```text
carplay-fit: laptop_only; reason: credential
```

`StatusSummaryAnswer` strips that line from the stored blurb — any last line opening with
`carplay-fit:`, parseable or not, so the reader never sees one — and writes the mark as an `auto`
one, stamped at the blurb's own line count. An answer that is *only* the trailer is a summary
failure, not a mark: there is no blurb to stamp it against. It costs no second inference: the blurb's first sentence
already says what the human must do, and the fork holding the conversation is the one thing that
can say whether that is voice-able. A summary that fails, or answers without the line, leaves the
mark untouched and the session reads as untagged, which is the honest answer.

Three other writers can override it:

- **`human`** — the CarPlay fit control on the session page, the User view row and the phone's
  bottom sheet, and `PATCH /api/v1/sessions/:id/carplay_fit` from the iOS app acting as its person:
  the *CarPlay fit* item in the app's session menu, which names the mark in force and offers each
  side with its reasons, or Clear.

  On the session page (beside the heart and bell icons) and on each User view row (beside Snooze
  and Trash) the control is a car icon that toggles CarPlay-ok. It reads as on while a *current*
  CarPlay-ok mark stands, whoever wrote it. Clicking it on writes a `human` CarPlay-ok, replacing a
  laptop-only mark and its reason if one stands. Clicking it off clears the mark, the same as *Clear mark*, rather than writing laptop-only: "not
  CarPlay-ok" does not mean the session needs a laptop. A mark Zimmer, an assistant or the session
  wrote gets a dashed outline, and a solid one is yours. Laptop-only shows as the car struck
  through. The chevron beside the car opens the full set of choices: Laptop only, a reason, or
  Clear. The phone's bottom sheet keeps the full menu.
- **`assistant`** — `action_session` → `set_carplay_fit` on the full `sessions` surface, which is
  what [Live Mode](/sessions/live/) calls during a drive after reading a summary.
- **`session`** — the same action on the `self_session` surface, a session speaking about itself.
  Unlike `set_visibility`, which that surface excludes, "what I need from the human next" is exactly
  self-knowledge; the `open-pr` skill holding a PR for a merge decision is the obvious caller.

- **`carplay`** — CarPlay engagement, below. Ranks with `assistant` and `session`.

**Precedence** is enforced in the writer. At the same transcript position `human` beats `assistant`
and `session`, which beat `auto`; equal rank overwrites. A write the rule refuses is reported, not
raised — the MCP action answers with "CarPlay Fit Kept" and the reason — because the caller that
loses is usually the summary fork, and a lost precedence contest is not an error.

## CarPlay engagement is the sticky default

A session you start or touch from the car is one you want to keep track of from the car. So whenever
a person engages a session from CarPlay, `Sessions::RecordCarplayEngagement` stamps
`carplay_engaged_at` and writes a `carplay_ok` mark with source `carplay`. Every CarPlay entry path
calls it:

- **Creating** a session with a CarPlay turn source: the app's CarPlay screen over REST, or a Live
  conversation on CarPlay calling `start_session` or `quick_router`.
- **Following up**, on every delivery path (`Session#tag_turn`), and **queueing** a message, at the
  moment it is queued.
- **Any other `action_session` action** a CarPlay Live conversation takes on a session (unarchive,
  pause, restart, change_goal, …), and the matching member writes over REST from the CarPlay client.

Reads are not engagement: an assistant triaging the board looks at every row, and marking them all
would empty the axis. Neither is `set_carplay_fit` (it says what the mark should be), hiding or
snoozing the card, a refresh, a fork, an archive, or a message Zimmer puts back in the queue.

The `carplay` mark is **sticky**: unlike every other mark it does not go stale when the session says
something new, so the session stays in the driver's `not_laptop_only` view however long it runs.

**Demotion needs clear evidence.** When an engaged session comes to rest, the status-summary fork is
told it was engaged from CarPlay and to answer `laptop_only` only when the next step clearly needs a
screen or a keyboard: a credential, a console or checklist, the person's own device, a long read.
When it is ambiguous it answers `carplay_ok`. A `laptop_only` answer, written against a later
transcript position than the engagement, replaces the sticky mark as an ordinary `auto` mark, and
the session's timeline records the demotion. So does a `laptop_only` from the session itself, an
assistant, or you. A `human` mark still outranks everything at the same position, and a `carplay_ok`
from the fork for a session already holding the sticky mark leaves it in place, filling in the
reason. A current `human` `carplay_ok` is not replaced by engagement (it outranks
`carplay`), so it goes stale the ordinary way until the next rest re-judges it.

**Re-promotion.** The fork's `carplay_ok` for an engaged session is written as the sticky `carplay`
mark again. It still ranks as an automatic judgement, so at the same transcript position
it never overwrites an `assistant`, `session` or `human` mark. That is how a session demoted for a credential gets back into the driver's view once the
credential is in. Re-engaging from CarPlay does *not* override a **current** `laptop_only`: the
session has not moved since it was judged, so the requirement still stands. The engagement is still
recorded. It is usually a follow-up, so the session soon moves past the demotion, and the next rest
re-judges it with the engagement in mind. A **stale** `laptop_only` is promoted at once.

## Staleness is counted in transcript lines

A mark is **current** while the session has not written a line past `carplay_fit_line_count`, and
**stale** once it has. That is the status summary's own freshness model, reused on purpose: a session
that became laptop-only after opening a PR that needs a diff read has *moved*, and the mark written
before that move was about an earlier state. Every filter treats a stale mark as untagged; every
summary line names it as stale, with how many messages have landed since. When the session next comes
to rest, the fork writes a fresh `auto` mark, and a mark written against a later position always wins
whoever wrote it.
The CarPlay-engagement mark (source `carplay`) is the one exception, above: it does not go stale.

There is no sweeper and no expiry job. Staleness is a comparison on read, which is what guarantees
no background writer can ever race the lifecycle.

## Filtering on it

Every listing takes the same `carplay_fit` filter, and every one of them leaves it **unset by
default**, for the reason visibility does: a laptop-only session is still the session a duplicate
check is looking for.

| Value | Returns |
| --- | --- |
| `carplay_ok` | Marked good for a driver, and the mark is current. |
| `laptop_only` | Marked as needing a screen or a keyboard, and the mark is current. |
| `untagged` | Never marked, or marked against an earlier transcript (a `carplay` mark never counts). |
| `not_laptop_only` | `carplay_ok` plus `untagged`. The driving default. |

The filter is on the dashboard's Filters form, the iOS app's Filters sheet, on
`GET /api/v1/sessions` and `/sessions/search`, and on the `quick_search_sessions` and
`get_user_view` MCP tools. `get_user_view` rows always carry a
`**CarPlay fit:**` line; `quick_search_sessions` and `get_session` carry one whenever a mark exists,
stale ones included.

## The first drive after the deploy

A session already resting on the board when this shipped rested *before* the fork learned to answer
the question, and most such sessions will not rest again for days. `BackfillCarplayFitFromStatusSummaries`
is the [post-deploy task](/operate/deploying/#one-time-post-deploy-tasks) that covers them: it walks
every unmarked `needs_input` session that has a ready blurb and enqueues `CarplayFitBackfillJob` for
it, which runs `CarplayFitClassifier` — one short Haiku completion over the stored blurb, through the
same one-shot path a session title uses — and writes an `auto` mark at the blurb's line count. The
blurb itself is left exactly as it was. Its answer is in `post_deploy_task_runs` on `/health`, and the
marks are on the board.

## What Live Mode is told

When the client driving a Live conversation is CarPlay, `LiveConversations::SystemPrompt` adds one
line to the mechanics section Zimmer writes: that the person is in a car, that sessions carry a
CarPlay fit, that `get_user_view` filters on it and `action_session` sets it, and that a session it
starts, follows up or acts on is marked `carplay_ok` on its own. The line also says to leave
`carplay_fit` off a search for a particular session. The filter is for going through what needs the
driver, and a lookup is not that: a session auto-marked `laptop_only` is still the one they asked
about. When a `quick_search_sessions` call does pass the filter and it hides a match, the result says
how many it left out ([Finding an earlier session](/sessions/live/#finding-an-earlier-session)). Zimmer states the fact; what to do with it belongs to
the `live-mode` root's own `modes/voice.md`, which is where the driving guidance lives. See
[Live Mode](/sessions/live/#the-agent-root-is-the-system-prompt).
