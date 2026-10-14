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
  its CI dot and a notes marker; a star for a favourite; and a snoozed or hidden one adds when
  the snooze ends. A trashed session reads in the quieter ink and says when its restore window
  closes ("Expires Oct 16", from `trash_after`; "Deletion pending" once that date has passed), as
  the web page's "Expires 3 days from now" does, as a date. What is deleted then is what was held
  for a restore — the preserved clone, the scratch directory, prompt attachments — not the session. On *Your board*, as on the web
  board's, each row also carries the session's "where things stand" as inline markdown on up to
  three lines, then how current it is (*Up to date*, *Stale* with the messages since, or
  *Regenerating*), when it was written, and the agent root, or the genesis where it has none
  (`GET /api/v1/sessions?view=user&include=board_row`, and the same on search). A row an action
  just answered keeps its summary until the next read; a server that sends no rows draws none.
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
  generated") and *Regenerate*; for a failed session, why it failed (`metadata.failure_reason`,
  the exception and exit status, the web's failure details); then one divided card: the **Goal
  check** (the web panel's verdict and one line per criterion, when the goal is a catalog goal
  with checks; its tally names the goal, and a router that recorded no PR of its own says whose
  PRs were judged, "Judged on PRs recorded by #1044, which this session spawned", each session a
  tap away), the **goal** (a catalog goal by its name from `GET /api/v1/configs`, whether the
  session stores its id or its words, with its words under it; your own words as they are, where
  the web page says "Custom" and keeps the words for a hover), the notes (two lines each until
  tapped), the **MCP servers** (a chip per server the session has wired, `all_mcp_servers`, green,
  red or grey for connected, failed or pending from `custom_metadata.mcp_servers_status`, the
  injected ones dashed; a failed server's error is a tap away, and *Edit* opens the checklist),
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
  link, and which plugin brought an MCP server. The
  conversation follows, newest last, each message with its age, rendered the way the web renders
  it as far as a phone's text goes: inline markdown (emphasis, code spans, links) and fenced code
  in the monospaced face; list markers and headings stay as typed, where the web draws them as
  structure. The web UI's log-level filter is a menu on it: *Minimal* (the words alone, the
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
  default), Model (the models the session's runtime lists), MCP Servers, Skills, Hooks and Plugins
  (each a checklist of its catalog, from the next turn), Promote to priority / Demote to spot (to the head of the spot queue), the
  heartbeat (the web's heart and its popout: on or off, and *Beat every* from 30 seconds to an
  hour, `PATCH /api/v1/sessions/:id/heartbeat` with `interval_seconds`, which leaves it on or off
  as it is), Generate Status Summary when there is none, and Open in browser. *Snooze until…*
  ends in *Custom…*, as on the row. A trashed session's header says when its restore window closes. A promotion that could
  not start the session says why. The star and the trash (or restore) are in the toolbar.
- **Sends a follow-up** from a box at the bottom, with quick replies for the common answers. A
  follow-up to a session mid-turn is queued, and the app says so; touch and hold the button to
  *Send Now* instead, which ends the turn in flight (`force_immediate`, the web UI's Send Now).
  It is recorded as your message if the app's connection acts on your behalf (below).
  What you type and do not send is kept per session for seven days, across leaving the screen and
  relaunching, as the web UI keeps a composer's draft.
- **Keeps itself current.** A session's page reads again every five seconds while a turn is
  running or about to start, and every twenty otherwise (not while the queue's manager is open,
  and never for a session in the trash); the board reads again every thirty seconds while it is
  the screen in front and you are not selecting or reordering. Both read at once when the app comes back to the front.
  The web UI streams these changes; the app asks, so a change can take that long to show. A session
  opens at its newest message, as the web UI's transcript does, and follows new ones while you are
  at the end; scrolled back, it stays where you are.
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
  the default rather than preselecting it. The sparkles in the bar open the sheet with the words
  typed so far. Opened from a session, the new one threads under it (*Thread under #id*, the
  bubble's `parent_session_id`), which you can switch off. All of it goes to
  `POST /api/v1/quick_router`. **Or from the full form** (the
  pencil in the Sessions toolbar): the web UI's new-session
  form, with agent root, runtime, model, reasoning effort, prompt, title, goal (a predefined one or
  your own words), scheduling class, and the MCP servers, skills, hooks and plugins, each starting
  at the root's defaults. The create is retry-safe (`idempotency_key`), and its prompt is recorded
  as your message when the app acts on your behalf.
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
- **Says which deployment a build is for.** A Staging or development build shows a strip at the top,
  and Settings prints `env=… host=… source=…`.

Every action above is a route on `/api/v1/sessions` that the app's token could already reach; none
of them widened what the phone can do on the server.

### Not in the app yet

*Reprioritize* and *Authorize merge* are not in the app yet, nor is the web composer's camera
button: taking a photo cannot be exercised in the simulator, so it waits on a change verified on
a device. Fork from a message and answering an
elicitation each need a server change first — the conversation endpoint does not say where a
message sits in the transcript the fork service counts, and no route lists a session's pending
elicitations — and come in their own change. So do switching a trigger's *Enqueue messages* and
*Resuscitate archived* (the app's token reaches a trigger's toggle and invoke, not its update),
saying whether re-arming a failed trigger fires it again (the trigger JSON does not say whether a
one-time wake was already spent; the web page does), and
the Costs page's burn rate (not in `GET /api/v1/costs`). So does the rest of the web card's refresh: on the
web it also resumes a failed session and sends the continue nudge to a stalled waiting one, but
`POST /api/v1/sessions/:id/refresh` only re-reads the transcript, so the row's refresh is
*Refresh Transcript* and a failed session is restarted with *Restart Session*. On the hierarchy,
the web says why a row is *drawn under* a session that did not spawn it — reached through a senior,
or placed there because the tree was cut short — and the app says only that it is: the hierarchy
nodes do not carry `ceiling_placed`. The admin pages (API keys, inference accounts, connectors,
settings) stay in the browser; *Open in browser* on any session gets you there.

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

**Then Zimmer**, as a public OAuth client of [Zimmer's authorization server](/auth/mcp-authorization-server/),
under the built-in `zimmer-ios` client:

1. You type your Zimmer's https address, unless the build already carries one.
2. The system sign-in sheet opens `/oauth/authorize` with a PKCE challenge. Zimmer's
   [web sign-in](/auth/web-sign-in/) does the rest, as it does in a browser: Google, restricted to
   the deployment's domain, then the second factor. Zimmer then shows a consent screen for
   "Zimmer for iOS". It asks for a [connection level](/auth/mcp-authorization-server/#relay-only-or-acts-on-my-behalf) like every
   other OAuth connection. Both levels reach the same API. **Acts on my behalf** records what you
   send from the app (follow-ups, Quick Router prompts) as your message, the way it does for an
   assistant; **Relay only** records nothing.
3. Approving sends the sheet to `com.tadasant.zimmer:/oauth/callback` with a 60-second code. The app
   redeems it at `/oauth/token` on the app origin with the verifier only it holds.
4. The access and refresh tokens go into the Keychain (`AfterFirstUnlockThisDeviceOnly`). The app
   refreshes the access token before it expires and calls
   [the REST API](/extend/rest-api/#the-ios-apps-bearer-token) with it.

No Google credential and no API key ever reaches the phone. The connection is listed on
**Settings → API keys** with every other OAuth connection, and revoking it there signs the phone out
on its next request. Signing out in the app revokes it too.

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

**The scene is inert until Apple grants the entitlement.** The entitlement lives in
`App/Zimmer/CarPlay.entitlements`, which is wired into nothing, and `testflight` refuses to sign
CarPlay in. This is the same arrangement as Motet's.

## How it is built and shipped

| Check | Where it runs | What it proves |
| --- | --- | --- |
| `ios/bin/ci-swift` | `ios_swift_linux` (self-hosted Linux) and `ios` (macOS) | The `ZimmerKit` logic: sign-in protocol, token refresh, edge-refusal handling, list ordering |
| `ios/bin/build-app` | `ios` (GitHub-hosted `macos-latest`) | The app compiles and links for the simulator |
| `ios/bin/testflight check` | `ios` | An unsigned Release archive is uploadable in shape (bundle keys, icon, privacy manifest, no entitlements) |
| `ios/bin/ui-test` | `ios` | The app runs on a simulator against its debug fixture, and the screenshots are kept as the `ios-ui-test` artifact, with the app's crash reports in `crashes/` and their crashed threads printed in the job's log |
| `ios/bin/testflight upload` | `testflight.yml`, on push to `main` | Signs in Apple's cloud at export, uploads, and waits for processing |

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
