---
title: The iOS app
description: Zimmer on an iPhone — the session list, signing in through Zimmer's own OAuth server and through the edge's access proxy, how it is built and shipped to TestFlight, and what has not been proven on a device yet.
sidebar:
  order: 7
---

Zimmer's iOS app puts the sessions that need you on your phone. It lives in
[`ios/`](https://github.com/tadasant/zimmer/tree/main/ios) in this repo. It is set up the same way as
the Motet iOS app (`tadasant/motet`, `ios/`): a checked-in Xcode project, a Swift package whose
logic is tested on Linux, every check a script under `ios/bin/`, and a TestFlight upload on every
merge. [`ios/README.md`](https://github.com/tadasant/zimmer/blob/main/ios/README.md) is the
engineering design doc. This page covers what the app does and how it reaches Zimmer.

:::caution[Not yet proven on a phone]
The app host and its Access application are being added in the private companion repo. Until that
is applied and this route is deployed, nothing has run the two sign-ins end to end on a device. See
[Known limitations](/limitations/#the-ios-apps-two-sign-ins-have-not-run-end-to-end).
:::

## What it does

The app follows the web UI's board and session page: the same words, the same status colours
(needs input blue, running green, waiting purple, failed orange, trashed gray), the same actions.
Where the web UI has a button, the app has a swipe, a long press, or a menu item.

It looks like the web UI, too. The colours are the web UI's: a gray-50 page, white cards with
hairline borders, indigo as the one accent, and the web's pastel status badges. The web UI has no
dark mode, so the app's dark mode is built on the PWA's navy (the manifest's `#000e2b` and
`#031942`, the same navy as the otter mark). The gold of the mark shows up in a few small places:
the sign-in screen, empty states, the status summary's edge, the favourite star. Every token is in one file,
`ios/App/Zimmer/Support/Theme.swift`. It is laid out the way the Motet app's design layer is.

- **Lists sessions** in one of the web UI's four board views, from the view menu: *Your board*
  (priority above spot, then precedence, then oldest first — `Sessions::UserView`), *Last
  Touched* (the default, as it is on the web UI on a phone), *Created*, and *Ranked* (the same
  order as *Priority* and *Spot queue* sections). The server orders each view
  (`GET /api/v1/sessions?view=`), so the app shows the same sessions the web board does: the first
  500 by Last Touched or Created, or the top 500 of Your board and Ranked; when more match, the list
  says so. In Ranked, *Reorder Spot Queue* (view menu) puts drag handles on the spot queue; on
  Your board, *Reorder Board* puts them on its spot rows. A drop tells the server the nearest spot
  rows it landed between, as the web UI's drag-and-drop does, and the list is read again: a row
  dropped among the priority rows settles back into the spot block, since precedence cannot lift
  it out. Priority rows do not drag: the server places a drop by its spot neighbours only, so a
  priority row would lose its precedence. *Start Now*
  (press and hold a waiting session, or its session menu) takes its next turn now.
- **Filters** as the web UI's filter form does, every filter combining with every other. The
  chips are one-tap presets: *Needs input* (the default), *Active* (everything not archived),
  *Waiting*, *Running*, *Failed* and *Archived*. The *Filters* button opens the whole form: any
  number of statuses, a scheduling class (*Priority* or *Spot*), an agent root and a genesis from
  the catalog, board visibility, and the web UI's quick filters (*All*, *All unarchived*, *All
  priority, unarchived*). A combination the chips cannot show is spelled out under them with a
  *Reset*. Filters and board visibility are remembered across launches, as the web UI remembers
  them in a cookie. Over the default filters *Ranked* shows waiting, running, needs-input and failed
  together, worked out each time as the web does, so leaving Ranked is back to *Needs input*. With no status ticked the list is every status but Archived, where the web reads ticking
  nothing as everything. Board visibility is *On board* by default, like the web UI's board, with
  *Snoozed & hidden* and *Both* in the view menu and the form. Pull to refresh. Rows sit on one surface with hairlines between them,
  as the web board's Your board and Ranked rows do: the title on up to two lines, then one line
  with the status pill, a *Priority* tag, `#id`, a compact age ("41m", "3h"), the latest PR with
  its CI dot and a notes marker; then the web rows' facts on one quiet line — the agent root
  (the card's, `_user_view_row`'s and `_ranked_row`'s), the genesis (the card's `genesis · class`
  pill; the class is the *Priority* tag above), the precedence as "rank 50" (`_user_view_row`'s
  `#N` and Ranked's rank; "rank", since `#` is the id) and a heart when the heartbeat is on (the
  card's top-right heart), all off `session_json`; a star for a favourite; and a snoozed or hidden
  one adds when the snooze ends. A trashed session reads in the quieter ink and says when its restore window
  closes ("Expires Oct 16", from `trash_after`; "Deletion pending" once that date has passed), as
  the web page's "Expires 3 days from now" does, as a date. What is deleted then is what was held
  for a restore — the preserved clone, the scratch directory, prompt attachments — not the session. On *Your board*, as on the web
  board's, each row also carries the session's "where things stand" as inline markdown on up to
  three lines, then how current it is (*Up to date*, *Stale* with the messages since, or
  *Regenerating*), when it was written, and the agent root, or the genesis where it has none
  (`GET /api/v1/sessions?view=user&include=board_row`, and the same on search). A row an action
  just answered keeps its summary until the next read; a server that sends no rows draws none.
  Press and hold a row for the card's actions; *View PR* lists every PR the session opened, as
  the session menu does, where the row's line has room for the newest alone. On Ranked the long
  press also has the web row's ⋮ items *Promote to Priority* (which starts a waiting session; a
  promotion that could not start it says why) and *Demote to Spot* (to the head of the spot
  queue, `PATCH /api/v1/sessions/:id` with `place: top_of_spot`), and on Last Touched and
  Created, the views the web draws as cards, the card's heart: *Turn Heartbeat On* / *Off*
  (`PATCH /api/v1/sessions/:id/heartbeat`); the interval is set from the session's page.
- **Selects several to trash** (*Select Sessions* in the view menu). A session mid-turn goes, ending
  the turn, as in the web UI's bulk Trash (`end_turn`); one with queued messages is refused with the
  server's reason and stays; the rest go.
- **Refresh All**, after a confirmation, through `POST /api/v1/sessions/refresh_all`: re-reads
  transcripts, restarts failed sessions, and continues sessions waiting on you that you did not
  pause, up to 50 of those together.
- **Searches** titles and metadata from the search box, or transcripts too with the
  *Transcripts* scope (the web UI's "Search transcript contents"; the first page of one bounded
  scan, and the list says so when the scan stopped before reading every session).
- **Acts on a row.** Swipe right to star or unstar. Swipe left to trash (or restore, in Archived)
  and to snooze (*Later today*, *Tomorrow*, *In 3 days*, *This weekend*, *Next week*, the web UI's
  presets, worked out in the phone's time zone; or *Custom…*, a date and time of your own from
  the next whole minute on, the web menu's picker) or hide. Press and hold for the rest: pause,
  restart, rename, *Refresh Transcript* (not on a running session, which is live already, as the
  web card hides its refresh), view the PR, open the session in the browser.
- **Asks before a restart that takes a session over.** Restarting a failed session goes at once.
  Restarting one waiting on you takes it over, so the app asks first in the web UI's words for
  what the restart will do: send an automated "continue" into its conversation, re-send a prompt
  its turn never delivered, or start over when its setup never finished. The server does not send
  its answer, so the app works it out from the fields it is made from (`session_id`,
  `metadata.clone_path`, `metadata.failure_reason`, `prompt`). The server's "never ran" is a blank
  `session_id` and no stored transcript, which the API does not say; a session whose runtime id was
  released as stale keeps its transcript with a blank id. So the session page counts the
  conversation it read, and the board, which cannot tell, never says the setup never finished
  from a blank id alone.
- **Opens a session**, laid out the way the web UI's phone page is: the title, then one line of
  chips (status, priority class, `#id` and age, each PR coloured by state with its CI dot, board
  visibility) and one line of what runs it (agent root, runtime, model, effort). Then *Where
  things stand* with how fresh it is ("as of 12m · 2 new since", the web's "messages since summary
  generated") and *Regenerate*. The summary is drawn by the transcript's markdown renderer, as
  the web's Status panel draws it, so its links open on a tap and offer Copy Link on a long press
  (a [Zimmer link opens the browser](/limitations/#a-zimmer-link-in-the-ios-app-opens-the-browser)); for a failed session, why it failed (`metadata.failure_reason`,
  the exception and exit status, the web's failure details); then one divided card: the **Goal
  check** (the web panel's verdict and one line per criterion, when the goal is a catalog goal
  with checks; its tally names the goal, and a router that recorded no PR of its own says whose
  PRs were judged, "Judged on PRs recorded by #1044, which this session spawned", each session a
  tap away), the **goal** (a catalog goal by its name from `GET /api/v1/configs`, whether the
  session stores its id or its words, with its words under it; your own words as they are, where
  the web page says "Custom" and keeps the words for a hover), the notes (two lines each until
  tapped), the **MCP servers** (always there, as the web page's line is: a chip per server the
  session has wired, `all_mcp_servers`, green, red or grey for connected, failed or pending from
  `custom_metadata.mcp_servers_status`, the injected ones dashed and one a plugin brought, in
  `all_mcp_servers` but neither chosen nor injected, in italics as the plugin's; a failed
  server's error is a tap away; with none, the agent root's defaults marked *agent root default*,
  or *None*; *Edit*, or *Add* when there are none, opens the checklist), the **skills, hooks and
  plugins** (a line each, the same way: the chosen ids, or the root's defaults, or *None*, and
  *Edit* or *Add*),
  the **hierarchy** (who spawned it and what it spawned, each a tap away; folded when wider than
  four sessions; the closed row names the origin, and each row its agent root, its genesis and
  class, "this session", "origin", and "drawn under #id" where the session above did not spawn
  it, with the server's truncation reason when the walk was cut) and the **Human messages**
  (folded; the closed row has both counts, "1 message in this session · 1 elsewhere in the
  hierarchy", or "none recorded anywhere in this hierarchy" and what that search could not
  cover; inside, each channel capture is not configured for, as the web panel's amber notice,
  then who said what, through which channel, tagged *this session* or *elsewhere*, an elsewhere
  message with the session it was said in a tap away). *Modify Goal* (in the menu or the goal's
  *Edit*) is the web page's goal picker: the catalog's goals by name with their words, stored as
  their words as the web picker stores them, your own words, or none. Two things the web panels
  show are not on the phone, because the API carries neither: a Slack message's *view in Slack*
  link, and *which* plugin brought an MCP server (the app marks the server as a plugin's without
  naming it), and the skills and hooks a session's plugins bring (the web lists them read-only;
  the app's line says only that its plugins may bring some). The
  conversation follows, newest last, each message with its age, rendered the way the web renders
  it: headings, paragraphs, lists that nest, quotes, tables and rules drawn as blocks, with
  emphasis, code spans and links inside them, and bare URLs made links as the web's autolink
  makes them. A link opens on a tap. A long press on a paragraph or list item that holds
  links opens a menu with *Open Link*, *Copy Link* and *Share…* for each of them, and *Copy Text*,
  so a long signed URL in an agent's message can be pasted elsewhere; a paragraph with links is
  copied through that menu rather than selected. A link in a heading or a table cell opens on a
  tap and has no menu. Two places the app reads markdown more leniently than the web's Redcarpet: `#1293` at
  the start of a line stays text rather than becoming a heading, and a table or list may follow
  a paragraph's line without a blank line between. Fenced code is in the monospaced face, scrolling sideways rather than wrapping,
  with a *Copy* button in the block's corner that puts the code on the clipboard, as the web's
  code blocks have; the code is one colour where the web colours it by language. A table's
  widest columns wrap to fit the phone, and a table with too many columns to fit even so scrolls
  sideways in its box, as the web's does. The web UI's log-level filter is a menu on it: *Minimal* (the words alone, the
  default on a phone), *Condensed* (each tool call as one line naming the tool and what it was
  given) and *Verbose* (the tool traffic whole, rendered the same way); the web's *Show Logs* is
  the logs screen in the menu. The page reads the newest hundred messages, each whole up to
  100,000 characters (`GET /api/v1/sessions/:id/conversation?limit=&full_content=true`), and
  *Show earlier* reads a hundred more each time: the window widens to the server's 200, then pages
  back from there to the first message (`before=`). While the page is open it reads the last
  twenty messages and joins them to what is on screen, reading the whole window again only when
  more arrived than that. Opening a session marks its
  notifications read and touches it as last touched, as the dashboard's page does
  (`GET /api/v1/sessions/:id?viewed=true`), and the Inbox badge follows.
- **Says why a session is waiting**, under the header, as the web page's header does: the spot
  gate's hold or quota pause, a turn queued for a worker, an account pool out of quota or logged
  out, a starvation-lane admission, a renewed MCP grant the agent has not picked up, an MCP server
  that needs authorizing, an approval request that expired or was lost, and the wake-up a session
  is asleep on (the one banner the web page does not draw). The words are the server's — `waiting`
  on `GET /api/v1/sessions/:id`, the web partials' own sentences — so the phone says what the page
  says, and the banners change as the page reads again. Each shows its headline and first
  paragraph, with the rest behind *More*, amber for a warning and sky for information. A banner's
  one control does what the web button does: *Make this session priority* promotes it (which
  starts a waiting session), *Force* stops the turn that most recently took a worker thread and
  gives the thread to this session's queued turn, after a confirmation in the web page's words
  naming that turn (`POST /api/v1/sessions/:id/force_start` with the `expected_victim_id` it
  named, so a different turn is never the one stopped; a refusal shows the server's reason),
  *Reconnect now* sends the reconnect message as a follow-up, and *Authorize in the browser* opens
  the session's web page, since MCP OAuth is a browser round-trip. A banner the app does not know
  is still shown, without a control.
- **Manages the queue**: the messages waiting for the turn in flight to end, in delivery order,
  each with *Send Now* (ending the turn), *Edit* and *Delete*; *Manage* opens the whole queue to
  drag into a new order or swipe away. An edit is recorded as your message when the app acts on
  your behalf, as the web UI records one. The app adds to the queue only through a follow-up.
  Above the queue, read-only as on the web, are the messages that were **never delivered**
  (`status=undelivered`): the session was archived before they went, or Zimmer retired a notice
  whose news had already gone stale.
- **Shows the logs** (*Show Logs*, newest first, fifty at a time) and **the subagents** a session
  ran (*Subagents*), each transcript read into messages.
- **Detaches an "also senior" link** from the hierarchy, after a confirmation, as the web UI's
  amber chip does.
- **The session menu** (the ⋯ button) is the web UI's mobile *Session actions* sheet, in its order:
  Quick Router, Edit Notes, Show Logs, Subagents, View PR, Snooze until… / Hide / Put back on the board, Refresh
  Transcript, Copy Transcript (the whole transcript as text), Pause Session, Restart Session. Then what the web UI's metadata block and Ranked view
  edit: Rename, Modify Goal (the catalog's goals by name, or your own words), Effort (the levels the session's model accepts, or the model
  default), Model (the models the session's runtime lists), *Modify MCP Servers, Skills, Hooks,
  Plugins* (a submenu with an item a kind and its count, so the menu stays short enough to show
  its last items; the page's rows are the main way in; each a checklist of the whole
  catalog, searchable by name and description, an unavailable MCP server listed last with its
  reason, a chosen id the catalog no longer lists shown unticked, since the server refuses a list
  naming it, so saving drops it; saving replaces the
  session's list, as the web's does, from the next turn; a server that needs OAuth is named with
  a link to the session's web page, where it is authorized), the web page's *Scheduling class* select
  (*Derive it*, which clears the class chosen for the session so its genesis decides again and
  names the class that gives; *Priority*; *Spot*; each sent as the web select sends it, the class
  alone with the precedence left as it is, `PATCH /api/v1/sessions/:id` with `scheduling_class`,
  `null` for *Derive it*; a change that makes a waiting session priority starts it, as the
  server does on any change into priority), *Precedence* (the session's rank in the spot queue,
  higher worked first, with the web page's note on what it does for this session), the
  heartbeat (the web's heart and its popout: on or off, and *Beat every* from 30 seconds to an
  hour, `PATCH /api/v1/sessions/:id/heartbeat` with `interval_seconds`, which leaves it on or off
  as it is), Generate Status Summary when there is none, and Open in browser. *Snooze until…*
  ends in *Custom…*, as on the row. A trashed session's header says when its restore window closes. A promotion that could
  not start the session says why. The star and the trash (or restore) are in the toolbar.
  The header carries what the session has spent, beside the id, as the web header's muted
  `session_cost_badge` does: `GET /api/v1/costs?session_id=` from the day the session was made
  to today (the server caps `days` at a year but takes explicit bounds), the total at list
  price, three places under a dollar, and nothing at all for zero — a session not swept into the
  ledger yet is not free. It is read beside the page on each load, not on the polls between.
  The metadata line adds "compacts at N tokens" for a Claude Code session whose auto-compact
  window was set to something other than the default; the editor itself has no API route.
- **Sends a follow-up** from a box at the bottom, with quick replies for the common answers.
  Typing "/" at the start of a line or after a space opens the web composer's typeahead in the
  quick replies' place: the session's own catalog skills that a person may invoke
  (`user_invocable`, from `GET /api/v1/skills`), narrowed as you type by name or description,
  names starting with what you typed first, ten at a time; a tap puts `/name ` in the box. A
  follow-up to a session mid-turn is queued, and the app says so; touch and hold the button to
  *Send Now* instead, which ends the turn in flight (`force_immediate`, the web UI's Send Now).
  It is recorded as your message if the app's connection acts on your behalf (below).
  What you type and do not send is kept per session for seven days, across leaving the screen and
  relaunching, as the web UI keeps a composer's draft.
- **Keeps itself current.** A session's page reads again every five seconds while a turn is
  running or about to start, and every twenty otherwise (not while the queue's manager is open,
  and never for a session in the trash); the board reads again every thirty seconds while it is
  the screen in front and you are not selecting or reordering (ten seconds after a read that
  failed). Both read at once when the app comes back to the front, and the board tries again two
  seconds later if that read fails. The board also reads whenever you close a session's page, and
  when you choose the Sessions tab again (unless it was read in the last five seconds), so a
  session trashed on the web, by a router or by its own agent leaves the board as you return to
  it. A read never replaces the board once a later read has, nor when it was asked before a row
  action on the phone, so a slow answer never puts a trashed row back.
  The web UI streams these changes; the app asks, so a change on a board you are looking at can
  take up to thirty seconds to show. A session
  opens at its newest message, as the web UI's transcript does, and follows new ones while you are
  at the end; scrolled back, it stays where you are.
- **Keeps every part of a session's page a tap away.** A strip pinned under the navigation bar
  has a chip for each part the page draws: *Overview* (the top), *Hierarchy* and *Human messages*
  (when the details card has those rows) and *Transcript* (the newest message). A chip scrolls
  there and opens the row if it is folded, so on a long transcript the hierarchy and the human
  messages do not sit a hundred messages up. The chip for the part being read is filled. On a
  phone's width the words shorten (*Top*, *Humans*), and at the largest text sizes they become
  symbols. The web UI's session page has no such strip.
- **Reads a transcript full screen.** The button at the end of the strip covers the page with the
  conversation alone, without the header, the cards or the composer; *Done* goes back to the page
  at the message you reached.
  Full screen is never remembered: a session always opens on its page.
- **Attaches photos and files** to a message with the paperclip beside the box: *Photo Library*,
  *Choose Files*, or *Paste Image* when the clipboard holds one (the
  web composer takes a pasted image; iOS asks whether Zimmer may paste from the app it came
  from), up to 20 and 75 MB altogether, shown as chips you can remove before sending. Photos,
  picked or pasted, go as JPEG, scaled down if needed to fit the 10 MB image limit; the library's own HEIC is not a
  type the server keeps as an image. A file from Files whose bytes are a PNG, JPEG, GIF or WebP goes
  as an image, anything else as a file the agent is told to read, as the web composer's two pickers
  send them. Anything that would be refused, or could not be read, is named rather than dropped
  quietly. They go with the message however it is delivered: now, queued behind a turn, or with
  *Send Now*.
- **Answers an MCP server's prompt** (an elicitation). A session stopped on one shows an
  *Approval Needed* card above the conversation, as the web UI shows its banner. Tapping it opens the prompt's
  form, one control per field in the banner's order: a switch, a menu of choices, a number or a
  text field. *Accept* sends the fields. A required field left empty is refused in the app, by name,
  before anything is sent. *Decline* refuses, and *Dismiss Without Answering* tells the server
  nobody decided. Only a connection that acts on your behalf may answer. A relay-only one shows
  the server's refusal in the form.
- **Forks at a message.** Touch and hold a message for *Fork from Here* (and *Copy*). After a
  confirmation, the fork, a new session holding the conversation up to that message, opens on top.
- **Merges.** On a session whose newest PR is open with CI green, the web UI's row *Merge* button is
  a swipe right, a long-press item, and the first item in the session menu (*Merge #1261*). After a
  confirmation, the session is told it may merge (`POST /api/v1/sessions/:id/authorize_merge`). The
  tap is the sign-off, and it is recorded as your message. Only a sign-in that acts on your behalf
  may give it; a relay-only one shows the server's refusal. The app does not show the web row's
  *Merge sent* state: a second tap is answered "already authorized" and sends nothing.
- **Reprioritizes** the board from the view menu in *Your board* and *Ranked*, after a confirmation:
  the deployment's reprioritizing session re-ranks it and writes the order back.
- **Trashes** a session as the web UI's Trash does: no question first, and an *Undo* on the board,
  shown for 30 seconds as the web UI shows it (`UNDO_ARCHIVE_WINDOW`), which restores the session.
  A session with a turn in flight goes outright, ending the turn
  (`POST /api/v1/sessions/:id/archive` with `end_turn`). A session with messages queued for it is
  asked about first, naming the discard: the web UI's *Archive anyway* (`force`). Undo does not
  bring back discarded messages or resume an ended turn.
  Restores one from the trash.
- **Starts a session from a sentence** through the Quick Router, then opens it. The Quick Router is
  where the web UI puts it: a field pinned to the foot of the Sessions screen ("What do you want
  to do?", the web board's prompt box), and a button in the bottom-right corner of every other
  screen (the web's bubble), which opens the sheet. The sheet is the web bubble's panel: the
  words, photos and files from the paperclip, and under *Advanced* the harness, the model and
  *Run as spot* (wait for quota room, at the top of the spot queue), each picker leading with
  the default rather than preselecting it. While the field has the keyboard, a *Cancel* beside it
  empties it and puts the keyboard away, as the search box's *Cancel* does. The sparkles in the bar
  open the sheet with the words typed so far. A start from the sheet empties the bar too; closing the sheet without starting
  (*Cancel*, or a swipe down) gives the bar the sheet's words, edits included. The sheet cannot
  be closed while a start is in flight, and a failed start keeps the words where they were
  typed. Opened from a session, the new one threads under it (*Thread under #id*, the bubble's
  `parent_session_id`), which you can switch off, and carries that session's page, as the bubble
  sends the page it was typed on ("Page context is included: …"): its web URL and title as
  `page_url` and `page_title`, and five facts off the header — id and title, status, agent root,
  class, goal — as `page_context`, which is what makes the server wrap all three into the prompt.
  That is much less than the bubble sends, which is the page's DOM reduced to markdown, up to
  20,000 characters; from the board and the other tabs no page goes. *Open the session when it
  starts* is on, the bubble's *Submit & Open*; off, the bubble's plain *Submit*: the session starts
  and the screen stays, which the endpoint allows since it answers with the id and never
  navigates. The class goes only as *Run as spot*; a native start the server classes priority. All
  of it goes to `POST /api/v1/quick_router`. **Or from the full form** (the
  pencil in the Sessions toolbar): the web UI's new-session form, with agent root, runtime,
  model, reasoning effort, the auto-compact window (for Claude Code alone, as the web shows it;
  blank is the default, 1,000,000), prompt, title, goal (a predefined one or your own words),
  scheduling class, precedence (blank is 0; a value that is not a whole number is refused in the
  form), the MCP servers, skills, hooks and plugins, each starting at the root's defaults, and
  *Clone Only*, which sets the clone up with no first turn (`clone_only: true`; the prompt is
  dropped, as the web button drops it, and the session opens needing input). The class starts at
  *From its origin*, the web form's shape, and sends nothing: `POST /api/v1/sessions` classes a
  create from the app priority when it says no class — a person is waiting on it as they are on
  the web form's — so the option says so, and *Priority* and *Spot* choose. The create is
  retry-safe (`idempotency_key`), and its prompt is recorded as your message when the app acts
  on your behalf.
- **Has the web UI's other pages as tabs**, their rows in the board's shape (one surface, hairlines,
  compact ages). *Inbox* is the notifications inbox, with the unread count on its badge: each row
  is the kind as a small label, the session's title, and its status, id and age; unread rows are in
  the full ink with a dot. Tap one to open its session (and mark it read), swipe to mark one read or
  dismiss a read one, and mark all read or dismiss all read from its menu. *Triggers* lists each
  trigger with what fires it on one line (two at most), its root, when it last fired and how many
  sessions it has made; turn one on or off (a trigger that is off reads in the quieter ink), invoke it now (after a
  confirmation, then open the session it started), or open its last session. Tap one for its page
  (`GET /api/v1/triggers/:id`): its status and the web page's labels beside it (*Re-uses session*,
  *Enqueues messages*, missed fires and the rest), why it failed and a *Re-arm* switch if it did,
  when it last fired and the session it last started, each condition and when it last fired, the
  agent root (flagged when the catalog has no such root), the re-use settings, the goal and prompt
  template, and the ten sessions it made most recently. *Enqueue messages* and *Resuscitate
  archived* are shown, not switched: the API that would switch them is the trigger update, which
  the app's token does not open. Creating and editing a trigger, and those two switches, stay in
  the browser; *Open in browser* on a trigger's page gets you there. *More* holds *Costs* and
  *Health*, read-only. *Costs* is the window's total, spend by day as a chart, by agent root and by
  model, and the most expensive sessions with their titles, calls and tokens, each a tap away. Its
  window is one of the web page's horizons (24 hours to a year) or a range of calendar days from
  the two date fields, both ends included, in the phone's time zone. Tap an agent root to narrow
  the whole page to it, or, on the page for every root, swipe a session and choose *Only This*,
  the web page's drilldown; the
  page then says what it covers, and *All agent roots* widens it again. The burn rate by harness
  and model is on the web page only: `GET /api/v1/costs` does not return it. *Health* is the
  overall status and each section's; its operator actions stay in the browser.
- **Talks to Zimmer, live** ([Live Mode](/sessions/live/)). The waveform button on the session
  list lands in the current conversation with voice on and the call starting, or a new
  conversation with voice on when none is open. Leaving the thread before that call connects hangs
  it up. The microphone prompt appears the first time; if
  it is refused, the call controls say so and *Type instead* still works. One tap on *Type
  instead* turns voice off in the same thread. *New conversation* on the thread's toolbar, then
  its confirmation, starts a fresh one in the thread's mode. Back leads to the Live list: whether
  Live Mode can start (and why not), *Resume conversation* for the open one, *New conversation*,
  and the recent ones. When Live Mode cannot start and nothing is open, the button stops on that
  list, where the reason shows. A conversation is one thread: typed and spoken
  lines, each tool call as a line that opens to its output (`zimmer → quick_router`), read again
  every two seconds. Typed, it has a composer with *Enable voice* beside it. With voice on, it has
  *Talk* and *Type instead*. Starting a call turns voice on for the conversation (`POST …/mode`),
  then the phone asks Zimmer for a short-lived OpenAI Realtime secret, opens a WebSocket to OpenAI with
  it, and streams the microphone up and the reply down through one `AVAudioEngine` with voice
  processing on, so the model does not hear itself. Function calls go to Zimmer and back, and
  finished lines are recorded in the thread. What to do with each Realtime event is
  `RealtimeConductor` (ZimmerKit), the same sequencing as the web's call dock and unit-tested on
  Linux. The call keeps going with the screen locked (`UIBackgroundModes` `audio`), and the car
  shares it.
- **Says which deployment a build is for.** A Staging or development build shows a strip at the top,
  and Settings prints `env=… host=… source=…`.

Every action above except answering a prompt is a route on `/api/v1/sessions` that the app's token
could already reach. Prompts are the one exception: they are listed at
`/api/v1/sessions/:id/elicitations` and answered at `/api/v1/elicitations/:id/respond`, both opened
to the app's token for this (see the [REST API](/extend/rest-api/#elicitations)).

### Not in the app yet

*Reprioritize* and *Authorize merge* are not in the app yet, nor is the web composer's camera
button: taking a photo cannot be exercised in the simulator, so it waits on a change verified on
a device. Switching a trigger's *Enqueue messages* and
Every action above is a route on `/api/v1/sessions`. Merge is the one the app's token reaches
where an API key cannot: only a person may give it (see the [REST API](/extend/rest-api/)).

### Not in the app yet

The web composer's camera button is not in the app yet: taking a photo cannot be exercised in the
simulator, so it waits on a change verified on a device. Fork from a message and answering an
elicitation stay in the browser until the app draws them; the API they need is in place. Switching a trigger's *Enqueue messages* and
*Resuscitate archived* (the app's token reaches a trigger's toggle and invoke, not its update),
saying whether re-arming a failed trigger fires it again (the trigger JSON does not say whether a
one-time wake was already spent; the web page does), and
the Costs page's burn rate (not in `GET /api/v1/costs`) come in their own change. So does the rest of the web card's refresh: on the
web it also resumes a failed session and sends the continue nudge to a stalled waiting one, but
`POST /api/v1/sessions/:id/refresh` only re-reads the transcript, so the row's refresh is
*Refresh Transcript* and a failed session is restarted with *Restart Session*. On the hierarchy,
the web says why a row is *drawn under* a session that did not spawn it — reached through a
senior, or placed there because the tree was cut short — and the app says only that it is: the
hierarchy nodes do not carry `ceiling_placed`. The admin pages (API keys, inference accounts,
connectors, settings) stay in the browser; *Open in browser* on any session gets you there.

Parts of the web session page wait on the API carrying them. The conversation endpoint returns
each message's role, words, time and whether it holds a tool call or result, and nothing else, so
the transcript's thinking blocks, compaction markers, errors, runtime notices, queue events and
image badges are not on the phone. The web composer's "/" also offers the skills and commands
found in the session's own clone (`.claude/skills`, `.claude/commands`), which no API route
returns; the app offers the session's catalog skills alone. The web header's per-session push
notifications bell and the *Context window* (auto-compact window) editor have no API route (the
window is set on the create form and read on the page, not edited), and the
session JSON does not say whether push is on; *Derive it* cannot name the genesis's class while a
class is chosen, because the API reports only the class in force. A class or precedence changed
from the app is not in the session's log: the web page writes "Scheduling class set to … (was …)"
and "Precedence set to … (was …)" there, and `PATCH /api/v1/sessions/:id` writes neither. The
Ranked row's inline precedence field is not on the phone's row: the rank is read there and edited
from the session's page. The session's cost is one more read per page load; the board's rows carry
no cost, since `session_json` does not.

## Two origins

A deployment can serve the app from two origins:

- **The web origin** (`zimmer.tadasant.com` for Tadas's) is where you sign in. `/oauth/authorize`
  runs there, and it is the OAuth issuer.
- **The app origin** (`zimmer-app.tadasant.com`) is where every machine call goes: `POST
  /oauth/token`, `/oauth/revoke`, `/api/v1/*`, and the edge handoff below. It is a separate hostname
  through the same tunnel to the same Rails, guarded by its own Cloudflare Access application that
  admits only the deployment's Google policy. There is no service token and no bypass.

A deployment without an app host uses one origin for both, and there is no edge sign-in.

## Signing in

On a deployment with an app host, the app signs in twice, and the two credentials stay independent.

**The edge first.** The system sign-in sheet opens
`https://<app origin>/native/access-handoff?state=<random>`. Access runs its own Google login and
forwards the request with the `Cf-Access-Jwt-Assertion` it minted. Rails checks that assertion
(`NativeAccessAssertion`):

- an RS256 signature from a key in the team's JWKS at `/cdn-cgi/access/certs`, cached for an hour;
- `iss` equal to the team domain (`ZIMMER_NATIVE_ACCESS_TEAM_DOMAIN`, default `tadasant.cloudflareaccess.com`);
- not expired;
- an `aud` that includes `ZIMMER_NATIVE_ACCESS_AUD`, the native app's Access audience tag. This is
  required. With the variable unset, every handoff is refused, because a JWT minted for any other
  Access application of the team would otherwise pass.

Rails then redirects to the hard-coded `com.tadasant.zimmer:/access/callback?state=…#cf_access_token=…`.
The JWT is in the fragment, which no server or request log ever sees. Anything invalid gets a 403,
and a malformed `state` gets a 400. The route has no web sign-in wall and
no CSRF check: it hands back only what Access minted for this requester, and every API call still needs
Zimmer's own token. The app checks `state` from the query, reads the JWT from the fragment, keeps it in the Keychain,
and sends it as `cf-access-token` on every machine call, never in `Authorization`. The edge passes
`Authorization` through untouched. The REST API takes the app's token only on the actions a
controller names with `accepts_native_app_tokens`, and `test/config/native_app_api_coverage_test.rb`
reads the app's Swift sources and fails unless an action behind every path the app calls accepts it. Paths are joined so that none contains `//`, which the app
host's tunnel answers with a 404. The JWT lives about 30 days. The app
runs the handoff again when less than a day is left, or when Access refuses a call: a redirect to
`*.cloudflareaccess.com`, which the app never follows, or a 401/403 page with `cf-access-aud`.

**Then Zimmer**, as a public OAuth client of [Zimmer's authorization server](/auth/mcp-authorization-server/#tokens),
under the built-in `zimmer-ios` client:

1. You type your Zimmer's https address, unless the build already carries one.
2. The system sign-in sheet opens `/oauth/authorize` with a PKCE challenge. Zimmer's
   [web sign-in](/auth/web-sign-in/) does the rest, as it does in a browser: Google, restricted to
   the deployment's domain, then the second factor. Zimmer then shows a consent screen for
   "Zimmer for iOS". It asks for a [connection level](/auth/mcp-authorization-server/#relay-only-or-acts-on-my-behalf) like every
   other OAuth connection. Both levels reach the same API, with one exception. **Acts on my behalf**
   records what you send from the app (follow-ups, Quick Router prompts) as your message, the way it
   does for an assistant, and is the only level that may answer an MCP server's prompt (an
   elicitation), because an answer approves or refuses what that server does next. **Relay only**
   records nothing, and may read a prompt but not answer it.
3. Approving sends the sheet to `com.tadasant.zimmer:/oauth/callback` with a 60-second code. The app
   redeems it at `/oauth/token` on the app origin with the verifier only it holds.
4. The access and refresh tokens go into the Keychain (`AfterFirstUnlockThisDeviceOnly`). The app
   refreshes the access token before it expires and calls
   [the REST API](/extend/rest-api/#the-ios-apps-bearer-token) with it.

No Google credential and no API key ever reaches the phone. The connection is listed on
**Settings → API keys** with every other OAuth connection, and revoking it there signs the phone out
on its next request. Signing out in the app revokes it too.

Only the token endpoint signs the app out. The app returns to the sign-in screen when `/oauth/token`
answers `invalid_grant` (the connection was revoked, or its refresh token expired) or
`invalid_client`. Everything else keeps the sign-in: a network error, a 5xx, or a 401 from an
endpoint that still refuses after a fresh token. That last one means the endpoint does not take the
app's token. It shows up as an error on that screen. A refresh whose answer never reached the phone
does not end the connection either; see
[refresh-token rotation](/auth/mcp-authorization-server/#tokens). A Keychain read that fails at launch,
which happens before the phone's first unlock, is retried on the next request rather than treated as
signed out.

## Push notifications

The app asks for permission after sign-in and registers the phone (`POST /api/v1/apns_devices`). It
sends the APNs token and the environment it belongs to: `sandbox` for a development or Staging build,
`production` for TestFlight. Tapping a notification opens its session. Signing out unregisters the
phone (a connection can unregister only its own phones), and revoking its connection stops its pushes
even if it never signs out.

The server sends the same notifications the web push does (*needs input*, a question waiting for an
answer, *finished*, *failed*, and a custom message) from `SendPushNotificationJob`, through `ApnsService`, but **the lock screen only says
what kind of thing happened**: "Zimmer — A session needs you.", "A session failed." and so on. A web
push is encrypted end to end, so the browser's push service relays ciphertext; an APNs alert is
readable by Apple. So the session's title, the summary of its last message, a failure detail and a
custom message's text never go to Apple. The push carries the session id, and tapping it opens the
session in the app, which reads it over its own authenticated connection. That is one HTTP/2 request per
phone to Apple, authenticated with an ES256 provider token signed by the APNs key. The key is
`APNS_AUTH_KEY_P8`, `APNS_KEY_ID` and `APNS_TEAM_ID` in the secret chain. **Until all three are set, it
sends nothing and logs why.** A token Apple reports dead is disabled with Apple's reason, and an APNs
failure never affects the web push or the notification record. Registered phones, and why one went
quiet, are listed at `/supervisor/apns_devices`.

The build signs in the `aps-environment` entitlement only when the `testflight` environment's
`ZIMMER_IOS_PUSH_ENABLED` variable is `1`. Set it once Push Notifications is ticked on the App ID.

## CarPlay

Every request the app makes carries `X-Zimmer-Client: ios/<version>`. A follow-up spoken in CarPlay's
voice loop says `carplay/<version>` and `voice_dictation`, so the session receiving it is told it
was dictated in the car ([turn sources](/sessions/turn-sources/)).

Zimmer's CarPlay scene is a **voice-based conversational app**, Apple's category for apps whose
primary way in is talking (`com.apple.developer.carplay-voice-based-conversation`, iOS 26.4+). None of
the other categories fit: Zimmer isn't audio, navigation, messaging, or a driving task. When the
phone connects, it says how many sessions need you and reads the first, its title and *Status
summary*, then listens:

- **"Yes"** (or "go ahead", "merge it") sends *Yes, go ahead.*
- **"Reply …"**, or anything else, is a reply in your own words. It is read back, and sent when you
  say yes. A bare **"reply"** asks what to say.
- **"Archive"** archives, after you say yes.
- **"Next"** skips, **"repeat"** reads it again, and **"stop"** ends the conversation.

Archive and replies wait for a spoken "yes", so a misheard word costs a sentence, not a session.
"Yes" on its own sends the approval at once, because it is the usual answer and only tells the agent
to carry on. If an action fails, the app says why and doesn't claim it worked. If Zimmer can't be
reached, the app says that instead of "nothing needs you". The screen underneath lists up to five sessions that need input. Each row is an action
sheet (Approve, Reply by voice, Archive) for a driver who would rather tap, and a Talk button
restarts the conversation. The voice control, list and action sheet templates are all ones the
category allows, and the stack never goes deeper than three. Speech is recognised on the phone only
(`requiresOnDeviceRecognition`), so a spoken reply never goes to Apple's servers. A phone that can't
recognise its language on the device says so instead of asking for an answer, and offers Approve and
Archive on the screen without Reply by voice. The audio session is held only while
the conversation runs. The rules live in `DrivingFlow`, which the unit tests cover.

**Live Mode in the car, voice on.** Under the list, a *Live Mode* section starts a *New
conversation* or resumes the open one (*Resume conversation*), turning voice on in it whether it was
typed until then or not. It then shows a call screen whose status row
follows the call (Connecting, Listening, Thinking, Speaking, Working on it) and has *Mute* and
*Hang up*. It is the same call as the phone's (`LiveCall.shared`), so a call started at the desk
carries on in the car. While a call runs, the section offers *Back to the call*.

Apple granted the entitlement as a managed capability, and it is enabled on the App ID. It lives
in `App/Zimmer/CarPlay.entitlements`, which `testflight` signs into every TestFlight build. The
archive is signed ad hoc so it carries the key into export. `check` fails if the archived app lacks
it, and `upload` fails afterwards if export's summary shows it was dropped. To use it, the phone needs iOS 26.4 or later; add Zimmer under Settings → General
→ CarPlay → your car → Customize if it isn't on the car's home screen.

## How it is built and shipped

| Check | Where it runs | What it proves |
| --- | --- | --- |
| `ios/bin/ci-swift` | `ios_swift_linux` (self-hosted Linux) and `ios` (macOS) | The `ZimmerKit` logic: sign-in protocol, token refresh, edge-refusal handling, list ordering |
| `ios/bin/build-app` | By hand; in `ios`, `ios/bin/ui-test` builds the same app (Staging is Debug plus its environment) for the simulator it runs on | The app compiles and links for the simulator |
| `ios/bin/testflight check` | `ios` | An ad hoc signed Release archive is uploadable in shape (bundle keys, icon, privacy manifest) and its signature carries the admitted entitlements (CarPlay) |
| `ios/bin/ui-test --smoke` | `ios` (GitHub-hosted `macos-latest`), on every pull request | The app builds for the simulator, launches against its debug fixture, reports the server it was built with, and starts a session from a sentence in the Quick Router bar and opens it. Every class in a UI test file the pull request changed runs too |
| `ios/bin/ui-test` | `ios-ui-tests.yml`, on push to `main` and on dispatch | Every UI test, and a photograph of every key screen in both appearances, kept as the `ios-ui-test-<configuration>` artifact (none when the run is pointed at a real server) with the app's crash reports in `crashes/` and their crashed threads printed in the job's log |
| `ios/bin/testflight upload` | `testflight.yml`, on push to `main` | Signs in Apple's cloud at export, uploads, checks export signed the entitlements in, and waits for processing |

The full UI suite does not gate pull requests. It is some 70 tests driven one at a time plus some 70
photographs, up to an hour on a loaded runner, which is too long to gate every iOS pull request on. A UI test that
the smoke run does not cover is therefore first run on `main`, where a failure alerts like any other.
To get the whole run and the screenshots for a branch before it merges, dispatch it:
`gh workflow run ios-ui-tests.yml --ref <branch>`.

The iOS jobs run only when `ios/**` or one of the three workflows changes. The `ios-changes` job
decides, and when it cannot tell it builds anyway. All three are in `all-checks-pass`. The macOS
runner is GitHub-hosted, which costs nothing on a public repository. It is the one exception to the
self-hosted pool, because nothing in the pool is a Mac.

`testflight.yml` is fenced the way Motet's is. Its only triggers are a push to `main` and a dispatch;
it refuses any other ref or repository; the App Store Connect key is a secret of the `testflight`
*environment*, behind a `main`-only branch policy; and it runs on an ephemeral hosted runner. Until
that environment has its key, the run says so in a notice and skips the upload, staying green.

## What a human does, once

[`ios/README.md`](https://github.com/tadasant/zimmer/blob/main/ios/README.md#what-a-human-does-once)
has the full list: register the App ID `com.tadasant.zimmer`, create the App Store Connect record,
create or reuse the Admin API key, and create the `testflight` environment with its secrets and the
`APPLE_TEAM_ID`, `ZIMMER_IOS_WEB_BASE_URL` and `ZIMMER_IOS_API_BASE_URL` variables. On the server,
set `ZIMMER_NATIVE_ACCESS_AUD` to the app host's Access audience tag. Both Kamal configs read it from
the deploy's environment: `deploy-staging.yml` forwards the `ZIMMER_NATIVE_ACCESS_AUD` repository
variable, and production's deploy workflow has to forward it the same way.
