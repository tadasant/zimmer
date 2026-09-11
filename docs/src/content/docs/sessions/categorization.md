---
title: Auto-categorization
description: How a new session gets sorted into a category, what Zimmer records when you correct it, and how to tune it and check whether the tuning helped.
---

Zimmer sorts every new session into one of your dashboard categories. You correct it by
dragging the card somewhere else. This page covers both halves: how the sort works, and
what happens to your correction.

## How a session gets its category

`SessionTitleJob` runs about two minutes after a session is created, and again when it
pauses or fails. It makes **one** cheap inference call (Haiku by default) that returns the
session's title and its category together. Title and category are two summaries of the same
context, so they share the call.

The context is the early transcript, capped at 8 KB. With no transcript yet, it falls back
to the human's own prompt. A failed session is categorized from its prompt, because a crash
transcript misleads the model.

The candidates are your non-frozen categories. Each one goes into the prompt as
`name: description`, so **the category description is the classification signal**. A
category with no description is matched on its name alone.

The categorizer is conservative on purpose:

- It is told to answer `NONE` when in doubt, and a `NONE` leaves the session in
  Uncategorized with a timeline note that says why.
- An answer that names two categories, or none, matches nothing. It never gets coerced
  into the nearest bucket.
- A category you set by hand is never overwritten. The job checks before it starts, and
  again on a fresh read just before it writes.

The prompt, the model choice, the answer parsing and the matching live in
`CategorizationService`. The job owns the session: which context to feed in, and what to
write when the answer comes back. That split is what lets a context be scored without being
applied, which is what replay needs.

## What gets recorded

Every outcome is written to `category_feedback_events` **before** anything can overwrite
it. There are three kinds of row:

| Kind | Written when | What it tells you |
| --- | --- | --- |
| `auto_assigned` | The categorizer picked a category. | What it chose, and from what. |
| `uncategorized` | It answered `NONE`, nothing, or a name that matched nothing. | Your categories may not cover this kind of work. |
| `correction` | You moved a session the categorizer had already ruled on. | The right answer, next to the wrong one. |

Every row carries `context_snapshot`: the exact string the model saw. A correction row
copies it forward from the answer it overrules, so each correction stands alone as a
`(context, wrong answer, right answer)` triple. The rows survive the session being deleted
and the category being deleted. The foreign keys are nullified, and the category names are
stored alongside the ids.

A correction is recorded from every surface that moves a card: the dashboard's drag and
right-click menu, `set_category`, the REST API's `set_category` and `reorder`, and the
`manage_categories` and `action_session` MCP tools. That works because the hook sits on the
column (`SessionCategorization`, an `after_update_commit` on `category_id`), not on any one
controller, so a surface added later records corrections without extra work. `source` says
which surface it was. A surface that doesn't name itself is recorded as `unattributed`
rather than dropped.

Moving a session the categorizer never ruled on records no correction. There's no answer to
disagree with. Moving one into a **frozen** category records none either: frozen categories
are never candidates, so no config could have picked it. Both moves still get a timeline
note.

A call that times out or fails records nothing. It hasn't declined anything, and counting it
as a decline would make the decline rate measure inference availability.

A session left Uncategorized is tried again each time it pauses, so one session can have
several `uncategorized` rows and, eventually, an `auto_assigned` one.

Every manual move writes a timeline note in the same voice as the auto path's:

```text
Auto-assigned to category "Bugs"
Moved to category "Research" (was "Bugs")
```

Before this, the manual move logged nothing, and a human correction couldn't be told apart
from an auto-assignment after the fact.

## Tuning it

Open **Settings → Categorization** (`/settings/categorization`). There are three levers, in
the order to reach for them:

1. **Category descriptions.** The page lists what the model sees for each category and flags
   the ones with no description. Edit one from the pencil on its dashboard section. The
   **+ New category** button opens the same form, so a category can have a description from
   the start.
2. **Category guidance.** Free text, up to 2,000 characters, placed inside the category
   task between the built-in instruction and the candidate list, wrapped in
   `<operator_guidance>` tags and introduced as being about the category choice only. You
   can't edit or remove any of the fixed text around it: the title task, the response
   format, or "when in doubt, prefer NONE". That's confined, not sealed. Title and category
   share one inference call, so the same model reads your guidance while it writes the
   title, and something like "answer with only the name" can cost sessions their generated
   title. When the title line is missing, the session falls back to a title taken from its
   prompt.
3. **Model.** Any Claude Code model id. The call is served by `HeadlessInferenceService`,
   which drives the Claude CLI, so a model id from another runtime is rejected on save. It's
   checked again on every call, so an override the catalog has since dropped falls back to
   the default rather than failing every title. This moves titling as well.

The same three are available to agents through `manage_categories`: `tuning` reads them,
`set_tuning` writes the guidance and model, and descriptions are the tool's existing
`update` action.

## Checking whether it helped

**Replay** re-asks the current config the questions your corrections already answered, and
shows how many it now gets right.

- It scores the most recent correction **per session**. A card you moved twice counts as one
  opinion, not two.
- It uses the stored snapshot, never the live transcript. It still works after
  `TranscriptArchiveJob` has archived the transcript, and after the session is gone.
- It rebuilds the prompt in the same shape as the original call. If the original asked for a
  title as well, so does the replay.
- It **writes no session**: no category, no title, no timeline note. The only thing it writes
  is the `replay_*` columns on the correction rows it scored.
- It runs as `CategorizationReplayJob` on the two-thread `inference` lane. The button replays
  10; the MCP `replay` action takes a `limit`, capped at 50.
- A call that times out or fails is not counted as a wrong answer. That row keeps its previous
  verdict.

The score counts only rows that have been replayed and can still be scored. A corpus that
has never been scored shows "Not replayed yet" rather than 0%. A correction whose category
has since been deleted or frozen isn't scored and isn't replayed. The config can't be judged
on a category it's no longer allowed to pick.

Only one replay runs at a time. Pressing the button again while one is queued or running
says so instead of queueing another, so two replays can't hold both `inference` threads away
from titling.

The page also shows the **decline rate**: of the last 100 sessions the categorizer ruled
on, how many it left Uncategorized. It reads each session's latest outcome, so a session
that pauses often doesn't count once per attempt. A
high decline rate is a different problem from a wrong answer. It means the work isn't
covered by any category, so the fix is a new category rather than a sharper description.

The loop is: edit a description or the guidance, press **Replay**, reload, and keep the
change or revert it. No PR and no deploy.

## Where to read the raw rows

`/supervisor/category_feedback_events` lists every row, read-only, with filters for
corrections, declines and replayed rows. The show page includes the full context snapshot.

## Not built yet

Spawning a session to fix categorization automatically once enough corrections pile up is
the third phase of [#16](https://github.com/tadasant/zimmer/issues/16), and it is
deliberately not here. It needs the corpus and the replay score above to judge its own work
against. See [Known limitations](/limitations/#categorization-replay-does-not-tell-you-when-it-is-done).
