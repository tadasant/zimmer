# iOS parity and design audit

A screen-by-screen comparison of the iOS app against the web UI, as a person uses it on a phone
(the PWA), plus a judgement of each screen's density and look against the Motet iOS app. Each
finding is tagged **parity** (the PWA can do it, the app cannot), **density** (the app spends
more screen on it than it should) or **design** (it does not look the way Motet does). Findings
are grouped into slices, one PR each, and the status column is kept current as they land.

The web UI's inventory behind this: the Quick Router is `shared/_chat_bubble.html.erb` (on every
page, `fixed bottom-4 right-4`), the board's phone prompt box is `sessions/index.html.erb`
(`md:hidden`, "What do you want to do?"), and the session page's phone layout is the compact
header in `sessions/_detail.html.erb` (title, status, `#id`, cost), the panel group (Status open,
Goal check open, Hierarchy and Transcript collapsed) and the joystick (`_mobile_joystick.html.erb`).
Motet's design layer is one `Theme` file: a ground, a surface, ink at three opacities, hairlines,
no shadows, serif titles against small tracked sans labels, metadata joined with `·` on one line,
tabular digits everywhere, read state shown by dimming rather than by a badge.

## Status

| Slice | Findings | Status |
| --- | --- | --- |
| 1. Quick Router everywhere | P1, P2, D1 | merged, #1293 |
| 2. Session page density | D2–D9, P8, P9, P10 | merged, in #1295 |
| 3. Board density and type | D10, D11, D13 (D12's search and D14 kept as they were, on reflection) | merged, #1295 |
| 4. Quick Router advanced and attachments | P3, P4, P5 | this PR, #1296 (a parameter change on the same route, no auth change) |
| 5. The other tabs | D15–D18 (P11 needs a server field; recorded) | this PR |
| 6. Transcript parity | P6, P7, P12 | planned |

## Findings, by priority

### Quick Router (parity, design)

- **P1 — parity.** The PWA has the Quick Router bubble in the bottom-right corner of every page
  (`_chat_bubble.html.erb`, `data-turbo-permanent`; Cmd/Ctrl+K). The app has it behind the pencil
  on the Sessions tab and as the first item of a session's ⋯ menu; the Inbox, Triggers, More, Costs
  and Health screens have no way to start work. **Slice 1.**
- **P2 — parity.** On the PWA's board the phone layout has a prompt box, "What do you want to do?",
  as its own element above the list (`sessions/index.html.erb`, `md:hidden`). The app's board has
  only the pencil in the toolbar. Tadas: it should be the most prominent thing on the main screen.
  **Slice 1.**
- **D1 — design.** The Quick Router sheet is titled "New session" and its placeholder is an example
  sentence; the PWA's is "Quick Router" and "What do you want to do?". **Slice 1.**
- **P3 — parity.** The PWA's panel has **Advanced**: harness, model, and *Run as spot*
  (`_quick_router_advanced.html.erb`; `SessionsController#chat_bubble` reads `agent_runtime`,
  `model`, `scheduling_class`). `POST /api/v1/quick_router` takes none of them, so the app cannot
  offer them until the route does. The controller already declares `accepts_native_app_tokens`, so
  this is a parameter change, not an auth change. **Slice 4.**
- **P4 — parity.** The PWA's panel attaches photos, camera shots and files (`images[]`, `files[]`).
  The API route takes none; the follow-up route's inline attachments (#1286) are the shape to
  copy. **Slice 4.**
- **P5 — parity.** The PWA's bubble on a session page sends `parent_session_id`, so the new session
  is a child of the one you were reading. The API route has no parent. **Slice 4.**

### Session page (density, parity)

The named offender. On the fixture's richest session the page above the fold is: a status row, a
two-line title at `title2`, a two-line monospaced metadata line, a PR chip row, the status summary
card, the goal card, the hierarchy card. The conversation starts below the fold. With real data
(a 120-character title, four PRs, a long goal, notes, a six-node hierarchy) the conversation is
two screens down.

- **D2 — density.** The header spends five rows (status, title, metadata, PR chips) where the
  PWA's phone header spends two (title; status · `#id` · cost). Plan: title at `title3`, then one
  wrapping chip line: status, Priority, `#id`, age, each PR, visibility. **Slice 2.**
- **D3 — density.** Root · runtime · model · effort is a two-line monospaced sentence. Plan: one
  caption line in the secondary ink, `·`-joined, monospaced only for the id. **Slice 2.**
- **D4 — density.** Goal, Notes and Hierarchy are three free-standing cards with 16pt padding and
  a label each. The PWA keeps them in one divided panel with Hierarchy collapsed. Plan: one card
  with hairline-divided rows; Goal and Notes clamp to two lines and expand on tap; Hierarchy is a
  disclosure whose closed row says "parent #1038 · 2 children". **Slice 2.**
- **D5 — density.** "Where things stand" has no "as of" line. The PWA says "up to date as of …" or
  "3 messages since summary generated", and the API already returns `generated_at` and
  `messages_since_generated`. Plan: a caption under the text, and *Regenerate* as a glyph. **Slice 2.**
- **D6 — density.** Conversation bubbles use `body` (17pt) with 14/10 padding; the PWA's transcript
  is `text-sm` (14px). Plan: `subheadline` for text, tighter padding, the agent's words as plain
  text under a hairline rather than a card (Motet draws hierarchy from type, not boxes), yours on
  the accent wash. **Slice 2.**
- **D7 — density.** No message shows when it was said. Plan: "AGENT · 6m" as the role label.
  **Slice 2.**
- **D8 — density.** The composer carries three quick-reply pills at 34pt and a sentence of hint
  text below the field while a turn runs. Plan: 30pt pills in `footnote`, and the hint folded into
  the placeholder ("Queue message — hold to send now"). **Slice 2.**
- **D9 — density.** Vertical spacing between sections is 16pt and card padding 16pt throughout.
  Plan: 10 and 12. **Slice 2.**
- **P8 — parity.** The PWA shows a failed session's failure reason and exception on the phone
  (`_failure_details.html.erb`: `metadata.failure_reason`, `exception_message`, `exception_class`,
  `exit_status`). The app shows nothing about why a session failed. The fields are in
  `session.metadata`, which the app's `SessionMetadata` has to start decoding. **Slice 2.**
- **P9 — parity.** The PWA's **Goal check** panel (met / unmet / pending per criterion) is always
  open under Status. The API returns `goal_check`; the app ignores it. **Slice 2.**
- **P10 — parity.** The PWA's provenance panel lists **Human messages** (who said what, through
  which channel). The API's show response carries `human_messages`; the app ignores it. **Slice 2**
  as a row in the divided card, collapsed.

### Board (density, design)

- **D10 — density.** Each row is a card with 14/12 padding, an 18pt radius and 8pt between the
  title and its line: about 96pt per two-line row, so a phone shows six. Plan: rows in one grouped
  surface with hairline dividers, 10pt vertical padding, and a 4pt gap: nine to ten rows per
  screen. **Slice 3.**
- **D11 — density.** Relative times read "41 min. ago" and "3 hr. ago". Plan: a `Format.age`
  giving "41m", "3h", "2d", tabular. **Slice 3.**
- **D12 — design.** The filter chips are 34pt in `subheadline`; the search field is a full-height
  system field that stays on screen. Plan: 30pt chips in `footnote`, and the search drawer that
  hides on scroll (`.automatic`). **Slice 3.**
- **D13 — design.** The row's title is `body` medium, emphasised to semibold only for needs-input.
  Motet dims what is done rather than emphasising what is not. Plan: titles in `subheadline`
  semibold; archived and waiting rows in the secondary ink. **Slice 3.**
- **D14 — density.** The row shows the status word as a badge and, when present, a Priority word
  in red. Plan: keep the badge; Priority becomes a small `P` glyph beside the id. **Slice 3.**

### Transcript (parity)

- **P6 — parity.** The PWA renders the transcript's markdown (`shared/_enhanced_markdown`). The app
  shows the raw text, asterisks and backticks included. Plan: `AttributedString(markdown:)` with
  inline-only parsing, and code blocks in the monospaced face. **Slice 6.**
- **P7 — parity.** The PWA's transcript loads tail-first and reads back as you scroll up. The app
  shows the last 100 and says how many it left out. Plan: a *Show earlier* row that raises the
  limit. **Slice 6.**
- **P12 — parity.** The PWA's transcript has a log-level filter (Minimal / Condensed / Show Logs /
  Verbose). The app folds tool calls behind one toggle and keeps logs on their own screen. Plan:
  the same four levels on the conversation. **Slice 6.**

### The other tabs (density, design, parity)

- **D15 — density.** Inbox rows carry a kind line, a title line and a badge line. Plan: the kind
  as the small label, the title, and one `·` line. **Slice 5.**
- **D16 — density.** Trigger rows list every condition on its own line. Plan: one line, `·`-joined,
  clamped to two. **Slice 5.**
- **D17 — design.** More is three system rows on a card with the system's grouped look. Plan: the
  theme's rows with tracked labels. **Slice 5.**
- **D18 — design.** Costs and Health keep system list styling in places. Plan: the theme's rows,
  tabular figures. **Slice 5.**
- **P11 — parity.** The PWA's phone header on a session shows the estimated cost
  (`session_cost_badge`); the app has it only on the Costs tab. The session JSON carries no cost,
  so this needs a server field first. Recorded; not planned.

### Already at parity or owned elsewhere

- Board views, filters, search, swipes, long press, snooze, trash, bulk trash, refresh all, rename,
  goal, notes, effort, model, catalog, heartbeat, promote/demote, start now, reorder: #1270,
  #1271, #1274–#1279.
- Attachments on a follow-up and the new-session form: #1286, #1287.
- Elicitations and Fork from here: #1281, #1282 (held). Merge and Reprioritize: #1283, #1284
  (held). Not touched here.
- Push and CarPlay: #1265, #1266.
- The admin pages, triggers' create and edit, Health's operator actions: browser by design.

### Known limitations kept

- The Running badge does not age as the web's does (no last-activity time in the list).
- Quick Router sessions from the app are always priority; the PWA's *Run as spot* comes with P3.
