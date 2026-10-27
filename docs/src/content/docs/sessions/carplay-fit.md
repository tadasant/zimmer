---
title: CarPlay fit
description: A per-session mark saying whether the next thing a session needs from you can be done by voice from a car, or needs a laptop. Derived from the status summary at every rest, overridable by hand, stale the moment the session moves, and read by nothing that schedules.
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
| `carplay_fit_source` | `auto`, `human`, `assistant`, `session` | Who wrote the mark. |
| `carplay_fit_set_at` | a time | When. |
| `carplay_fit_line_count` | an integer | The session's transcript line count when the mark was written. |

The five travel together through one writer, `Sessions::SetCarplayFit`, which every surface calls:
the status-summary harvest, the web UI, the REST endpoint and the `set_carplay_fit` MCP action.

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
- **`assistant`** — `action_session` → `set_carplay_fit` on the full `sessions` surface, which is
  what [Live Mode](/sessions/live/) calls during a drive after reading a summary.
- **`session`** — the same action on the `self_session` surface, a session speaking about itself.
  Unlike `set_visibility`, which that surface excludes, "what I need from the human next" is exactly
  self-knowledge; the `open-pr` skill holding a PR for a merge decision is the obvious caller.

**Precedence** is enforced in the writer. At the same transcript position `human` beats `assistant`
and `session`, which beat `auto`; equal rank overwrites. A write the rule refuses is reported, not
raised — the MCP action answers with "CarPlay Fit Kept" and the reason — because the caller that
loses is usually the summary fork, and a lost precedence contest is not an error.

## Staleness is counted in transcript lines

A mark is **current** while the session has not written a line past `carplay_fit_line_count`, and
**stale** once it has. That is the status summary's own freshness model, reused on purpose: a session
that became laptop-only after opening a PR that needs a diff read has *moved*, and the mark written
before that move was about an earlier state. Every filter treats a stale mark as untagged; every
summary line names it as stale, with how many messages have landed since. When the session next comes
to rest, the fork writes a fresh `auto` mark, and a mark written against a later position always wins
whoever wrote it.

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
| `untagged` | Never marked, or marked against an earlier transcript. |
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
CarPlay fit, and which tools filter and set it. Zimmer states the fact; what to do with it belongs to
the `live-mode` root's own `modes/voice.md`, which is where the driving guidance lives. See
[Live Mode](/sessions/live/#the-agent-root-is-the-system-prompt).
