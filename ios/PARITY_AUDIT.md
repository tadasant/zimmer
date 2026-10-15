# iOS parity and design audit

A screen-by-screen comparison of the iOS app against the web UI, as a person uses it on a phone
(the PWA), plus a judgement of each screen's density and look against the Motet iOS app. Each
finding is tagged **parity** (the PWA can do it, the app cannot), **density** (the app spends
more screen on it than it should) or **design** (it does not look the way Motet does). Findings
are grouped into slices, each one PR or a server PR and an app PR, and the status column is kept current as they land.

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
| 4. Quick Router advanced and attachments | P3, P4, P5 | merged, #1296 (a parameter change on the same route, no auth change) |
| 5. The other tabs | D15–D18 (P11 needs a server field; recorded) | merged, #1297 |
| 6. Transcript parity | P6, P7, P12 | merged, #1298 |

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
  inline-only parsing, and code blocks in the monospaced face. **Slice 6.** Then block markdown
  (headings, nested lists, quotes, tables, rules), cut into blocks by ZimmerKit's
  `MarkdownBlock` and drawn by `MarkdownText`.
- **P7 — parity.** The PWA's transcript loads tail-first and reads back as you scroll up. The app
  shows the last 100 and says how many it left out. Plan: a *Show earlier* row that raises the
  limit. **Slice 6.** It stops at the server's 200-message cap; see G6.
- **P12 — parity.** The PWA's transcript has a log-level filter (Minimal / Condensed / Show Logs /
  Verbose). The app folds tool calls behind one toggle and keeps logs on their own screen. Plan:
  Minimal, Condensed and Verbose on the conversation; Show Logs is the logs screen. **Slice 6.**

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

### What this audit got wrong

The first pass matched on feature names. "Filters ✅" was true of the word and false of the control:
the app had one status chip at a time where the web UI's form ticks any number of statuses and
narrows them by scheduling class, agent root and genesis together. Tadas hit it on his phone. The
control-by-control re-audit below replaces the "already at parity" list that stood here, which
also claimed search, goal, heartbeat, snooze, trash, reorder and promote/demote. Each of those
turned out partial. The rest of that list (views, swipes, long press, bulk trash, refresh all,
rename, notes, effort, model, catalog, start now) was checked again and holds.

Owned elsewhere, and still true: push and CarPlay (#1265, #1266); attachments on a follow-up and
the new-session form (#1286, #1287, #1278).

### Known limitations kept

- The Running badge does not age as the web's does (no last-activity time in the list).

## Control-by-control re-audit (2026-10-13)

Every control on every PWA screen, checked against the app and against what the REST API answers
the app's token. The PWA's views and Stimulus controllers are the reference. One row per gap,
ordered by how often a person using Zimmer on a phone would hit it. **Server** marks a gap that
needs an API change first, which is its own clearly-labelled PR. **Held** marks one waiting on a PR
the merge gate holds for Tadas.

The letters group gaps into slices, each one or two PRs (a server half first where one is needed):
**A** board filters · **B** keeping current · **C** opening a session (read marks, full content) ·
**D** the board's rows and trash · **E** waiting and recovery banners · **F** session-page detail
and the composer · **G** transcript rows, slash commands, desktop-only settings · **H** triggers and
costs.

| # | Gap | PWA | App today | Server? | Slice / status |
| --- | --- | --- | --- | --- | --- |
| G1 | Board filters don't combine | Status checkboxes (any number, *Waiting* included), scheduling class, agent root, genesis, quick filters *All* / *All Unarchived* / *All Priority Unarchived*, remembered in a cookie; Ranked opens on waiting+running+needs_input+failed | One status chip at a time, no *Waiting*, no class/root/genesis, the filter not remembered (the view is), Ranked opens on needs_input | Yes: `agent_root`, several statuses | A: #1304 (server), #1305 (app) |
| G2 | Nothing updates live | Turbo streams on the board and the session page | Loads once; refreshes only on pull, a filter change or your own action, and not on returning to the app | No (poll and refresh on foreground) | B: #1307 |
| G3 | A session opens at the top | Opens at the newest message and follows it | Opens at the header; the conversation is below the cards | No | B: #1307 |
| G4 | MCP prompts can't be answered; no *Fork from here* | Approval banner with the prompt's form; fork from any message | Neither | Yes | Held: #1281, #1282 |
| G5 | Opening a session doesn't mark it read | Marks all of the session's notifications read and touches *last touched* | From the Inbox, that one notification is marked read; from the board or a push, nothing is, and *last touched* is never set | Yes | C: #1308 (server), #1309 (app) |
| G6 | Long messages and long histories cut off | Full text; scroll back to the start | Each message cut at 4,000 characters; history stops at 200 messages | Yes: full content, a cursor | C: #1308 (server), #1309 (app) |
| G7 | Drafts lost | Composer drafts kept for 7 days; an undelivered prompt put back | Lost on leaving the screen | No | B: #1307 |
| G8 | Trash refuses running or queued sessions, no Undo | Trashes a running session outright; *Archive anyway* only when messages are queued; an Undo toast | The API refuses a live turn or a non-empty queue without `force` (a 422 shown as an error); no undo | Yes: `end_turn` | D: #1312 (server), #1310 (app) |
| G9 | Status summary unreadable | Markdown with live links (`#message-N`, PRs, sessions); on every *Your board* row | Raw markdown on the session page; not on rows | Yes: `include=board_row` | D: #1311 (server), #1313 (app) |
| G10 | No "why is it waiting" | Spot hold, queued turn with *Force start*, auth outage with reset time, starvation banners | None | Yes: waiting reason, `force_start` | E: #1314 (server), #1315 (app) |
| G11 | Merge and Reprioritize | Row *Merge* on *Your board*; *Reprioritize* | Missing | Yes | Held: #1283, #1284 |
| G12 | Title search silently capped | Pages through every match | 100 matches, no notice | No | A: #1305 says when there are more |
| G13 | Rows thin | Agent root, Spot/Priority, genesis, precedence, cost, running elapsed | Status, Priority, `#id`, age, PR | Cost and elapsed: yes, but not sent yet (see below) | D: #1313 (agent root, else genesis); cost, running elapsed and precedence on rows not yet |
| G14 | Recovery banners missing | MCP OAuth reconnect, lost approval request, undelivered messages | None | Yes: banners as data | E: #1314 (server), #1315 (app) |
| G15 | Board ordering controls | Drag on *Your board*; inline precedence and promote/demote on Ranked rows | Drag only in Ranked's spot queue | No | D: #1313 (Your board drag) |
| G16 | Session page detail | Goal picked from the catalog with its name; goal check's delegated sessions; hierarchy root, genesis, markers; human messages here/elsewhere and capture gaps; MCP connection status per server | Free-text goal, raw ids, less detail | Mostly no | F: #1320 (Slack permalink and plugin attribution need fields; see below) |
| G17 | Composer capture | Camera; paste an image | Photo library and files only | No | F: #1317 (paste); camera waits on a device-verified change |
| G18 | Small controls | Custom snooze time, heartbeat interval, per-row refresh and rename, trash expiry date, restart confirm on a takeover | Missing | No (two follow-ups below) | F: #1317 (board refresh re-reads the transcript only; see below) |
| G19 | Transcript rows | Thinking, compaction, errors, runtime notices, queue events, image badges; highlighted code with copy | Text and tool calls only; plain code | No: the conversation endpoint sends text and tool calls only (see below) | G: #1321 (Copy on code); the other rows need the server first |
| G20 | Slash commands | Typeahead from the repo's skills and commands | None | Yes | G: #1321 (catalog skills; clone skills need a route) |
| G21 | Desktop-only session settings | Per-session push, auto-compact window, precedence, *Derive* class | Partial | Class, precedence: yes; push, auto-compact: no | G: #1321 (class with *Derive it*, precedence); push and auto-compact need routes |
| G22 | Triggers beyond on/off | Show page toggles for *Enqueue messages* and *Resuscitate archived*; create and edit | List, on/off, invoke | Yes | H: #1316 (app), #1318 (auth: the two switches); create/edit stays in the browser by choice |
| G23 | Costs drill-down | Custom date range, scope to an agent root or a session, burn rate | Fixed windows, fleet only | Burn rate: yes | H: #1316 (app), #1319 (server: burn rate) |
| G24 | Outcomes, backlog, gate decisions | Pages of their own | Not in the app | Yes (no token reach) | Not planned: operator surfaces, *Open in browser* |
| G25 | Settings (Sign-in, API keys and connections, Deployment Information); inference, connectors, models, Health's operator actions | Admin pages | Settings and API keys: in the app; the rest: browser | — | The rest: browser by choice |

## Server gaps found while building the slices

Building slices D–H against the real API turned up these. Each one keeps a PWA control off the phone
until the server carries it. None is an auth change.

- **Transcript rows (G19).** `GET /api/v1/sessions/:id/conversation` sends each message's role,
  words, time and tool flags. `Session#formatted_conversation` drops everything else: thinking blocks,
  compaction markers, errors, runtime notices, queue events and images. `GET …/transcript`
  renders some of them into one plain-text string, which is not rows. The audit's "Yes, for rows"
  was wrong.
- **Slash commands (G20).** No route lists the skills and commands in a session's clone
  (`.claude/skills`, `.claude/commands`, plugin skills); the app offers catalog skills only.
- **Session settings (G21).** No route toggles a session's push notifications, and the session JSON
  doesn't say whether push is on. `auto_compact_window` is serialized but not permitted on
  `PATCH /api/v1/sessions/:id`. That PATCH also writes none of the "Scheduling class set to … /
  Precedence set to …" log lines the web writes. While a class is chosen, the JSON gives only the
  class in force, so *Derive it* can't say what the genesis would pick.
- **Restart confirmation (G18).** The app works out the web's `restart_confirmation` wording from
  fields the API sends. Sending the server's own wording would retire the app's duplicate of that
  logic.
- **Board refresh (G18).** `POST /api/v1/sessions/:id/refresh` re-reads the transcript. The web card's
  refresh also resumes a failed session, restores a running one's lost job, and nudges a stalled
  waiting one.
- **Session detail (G16).** A Slack message's permalink (`human_messages`), which plugin brought an
  MCP server, and `ceiling_placed` on hierarchy nodes.
- **Triggers (G22).** `spent_one_shot_wake?`, which the web uses to say whether re-arming a failed
  trigger fires it again.
- **Rows (G13).** Cost and running elapsed per row.

