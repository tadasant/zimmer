# Zimmer in the car

The design for Zimmer's CarPlay app: what a driver can do with Zimmer at a glance and by voice,
and what the car keeps out of reach. This is the engineering design doc for `App/Zimmer/CarPlay/`
and `Sources/ZimmerKit/Driving/`; the user-facing prose is
[docs: The iOS app → CarPlay](https://docs.zimmer.tadasant.com/extend/ios-app/#carplay).

## The moment it is for

Someone is driving. Their hands are on the wheel and their eyes are on the road, so a screen gets
a glance of a second or two and a tap gets a large target. They want three things from Zimmer:
to know whether anything is waiting on them, to deal with it without stopping, and to start or
steer work as it occurs to them. All of that is best done by talking, with the screen as a
second channel that confirms what was heard and shows what the voice is about.

The reference is the Claude CarPlay app: very few, very large buttons, one obvious default.

## What Apple allows

Zimmer's CarPlay scene is a **voice-based conversational app**, the category Apple added in iOS
26.4 (`com.apple.developer.carplay-voice-based-conversation`). Apple's CarPlay App Programming
Guide (the 2026-10-13 edition) fixes what such an app can be:

| Rule | What it means here |
| --- | --- |
| Templates: action sheet, alert, grid, list, tab bar, information, voice control (26.4+) | No Now Playing, contact, map, point of interest or search template |
| Depth of 3 templates, the root included | Root → one pushed screen → one more; modals (alerts, sheets, the voice control template) sit on top |
| "Primary modality of voice upon launch" | The one default button is the voice conversation; the car itself stays silent until the driver taps it (see Decisions) |
| "Only hold an audio session open when voice features are actively being used" | The audio session is held only while a call runs, never idle |
| Recording "only in conjunction with the voice control template" | The microphone is open only while the voice control template is on screen: the Live Mode call |
| "Don't show text or imagery in response to queries" | Answers are spoken; the screen shows state and one line of context, never a transcript |
| Voice control template: up to 2 action buttons, leading and trailing bar buttons (26.4+) | Mute and Hang up on the call |
| Some cars cap a list at 12 items; a grid holds up to 8; a tab bar up to 5 tabs | Lists stop at 12, the grid has 3 tiles, the tab bar 3 tabs |
| Notifications: communication, EV charging, parking, public safety and driving task apps only | **This category cannot show notifications in CarPlay.** The car is proactive through the badge and the counts, silently |

Everything below fits inside that table. Where a nicer design wanted something outside it — a
Now Playing-style status card, an overlay of the call over the board, a notification — the
section says what it would take.

## Decisions

**One voice, and it is Live Mode's.** The first CarPlay app had two voices that listened: an
on-device speech recogniser with a small command grammar, and a Live Mode call. The redesign
(#1396) cut the recogniser but kept a second voice that *spoke*: the system's `AVSpeechSynthesizer`,
for a briefing, a card read aloud, and "Told it to go ahead." after a tap. Tadas heard it in the car
and cut it ([#1410](https://github.com/tadasant/zimmer/issues/1410)): *"I should never hear the
robotic voice that just reads stuff. It should always be real-time."* The car now has exactly one
voice, the OpenAI Realtime call, and no other code path can make a sound. A source guard
(`CarPlayTests`) fails the build on any `AVSpeechSynthesizer` in the app.

**One thread.** In the same message: *"there should be no separate ways to talk to single
sessions… Everything should just be managed by the live mode. There should only be one thread
throughout the whole CarPlay app."* So the car has no per-session screen and no per-session
buttons. The session cards (Merge, Go ahead, Restart, Archive, Read aloud, More) are gone. A
session's row is a way into the one conversation: tapping it starts, or carries on, the Live Mode
call with an opening line that names the session, and Live Mode does the rest with its own tools
(`action_session`, `authorize_merge` through the gateway, and so on), with its own guardrails: it
confirms before anything consequential, including merges. A source guard fails the build on any
direct follow-up, merge, restart or archive call in the CarPlay scene.

**The default is Talk to Zimmer.** It is the first tile on the home tab. One tap, no choice to
make: the open Live Mode conversation with voice on, or a new one with voice on. *New conversation*
and *Resume* were two buttons for a question a driver should not be asked; the phone keeps both.

**Silent until asked.** Opening the app says nothing: it lands on the home tab, and nothing is
heard until the driver taps Talk to Zimmer or a row. The first version of this design spoke a
briefing on connect and a line for every session that entered Needs you while driving; Tadas cut
both. A car that starts talking when you get in, or interrupts the radio because a session failed,
is the car deciding when you are listening. The category's "primary modality of voice upon launch"
is read as *the default action is voice*, not *the app speaks first*.

**Live Mode unavailable is shown, never spoken.** When the call cannot connect, or drops, the Talk
tile says *Live Mode unavailable, retrying…* and the car tries again after 2, 5 and 15 seconds,
silently (`LiveRetry`). Once those are spent it says *Live Mode unavailable. Tap to retry*; a tap
is a fresh budget, and hanging up ends the retries. There is no fallback voice to fall back to.

**Unavailable while driving:** trash, new conversation, Live settings, typing, transcripts, logs,
links, the hierarchy, notes, scheduling, effort, catalog changes, and every per-session button. The
phone has all of them. The car offers what fits in one glance and one tap, and the conversation.

**Proactive, but silent.** The category cannot show CarPlay notifications, and the car does not
speak unasked, so what is proactive is what the eye catches in a glance: the board is re-read
every minute, and the badge on the *Needs you* tab and the counts on the home tiles change. A
spoken line for a session that enters Needs you while driving was in the first version of this
design and is cut; if it comes back it belongs inside an active Live Mode call, where the model
can mention it in the conversation, or behind a setting that defaults to off. Push notifications
still reach the phone; CarPlay just does not display them for this category.

**A status board instead of Now Playing.** The Now Playing template is audio apps' only. What the
driver wanted from it — what is running, at a glance — is the *Running* tab: each session at work
with one line of what it is doing, from its status summary, and the count on the home tile. While
a call is up, the call screen's title names the session the conversation is about.

**Siri is a follow-up, not part of this.** Siri App Intents ("Hey Siri, what needs me on Zimmer?")
work in CarPlay without any CarPlay entitlement and would be a good second way in, but they are a
phone-app surface (`App/Zimmer/`, outside the CarPlay scene) with its own review and test needs.
Not built here; see Follow-ups.

## Screens

```mermaid
flowchart TD
  connect([Car connects, silently]) --> tabs
  subgraph tabs [Tab bar — root, depth 1]
    home["Zimmer (grid)\n[Talk to Zimmer]\n[Needs you · n] [Running · n]"]
    needs["Needs you (list, ≤12)\nneeds input, then failed\n● badge while any"]
    running["Running (list, ≤12)\nrunning, then waiting"]
  end
  home -- Talk to Zimmer --> call
  needs -- row: talk about this session --> call
  running -- row: talk about this session --> call
  call["Live Mode call (voice control template, modal)\nstate picture + title with the subject session\nactivity label in the bar\n[Mute] [Hang up]"]
  call -- Hang up --> tabs
  call -- cannot connect, or drops --> retry["Talk tile: Live Mode unavailable, retrying…\n(2 s, 5 s, 15 s, silently)"]
  retry -- retry connects --> call
  retry -- retries spent --> tap["Talk tile: Live Mode unavailable. Tap to retry"]
```

| Screen | Template | Depth | Why this template |
| --- | --- | --- | --- |
| Root | Tab bar, 3 tabs | 1 | One tap between the three questions, no back button; the *Needs you* tab wears the red badge |
| Zimmer (home) | Grid, 3 tiles | 1 (a tab) | A grid's tiles are the largest targets CarPlay draws |
| Needs you, Running | List, ≤ 12 rows | 1 (a tab) | A row is a title and one line; the car may show only 12 |
| Live Mode call | Voice control template | modal | The only screen allowed while recording |

Nothing is pushed. The call screen is the only modal, and it is presented, rebuilt and dismissed
through `CarPlayNavigator`, one change at a time.

### The home tab

Three tiles: **Talk to Zimmer** (first; *Back to the call* while one runs; *Live Mode unavailable,
retrying…* or *Tap to retry* when the call will not connect), **Needs you · n** and **Running · n**
(each switches to its tab). The counts are the glance; the tiles are the taps. This is what the car
opens on, and it opens quietly.

### Needs you and Running

Each row is the session's title and one line: the first sentence of its status summary as plain
words, or, when there is none, what its status means ("Waiting for your reply.", "Failed. Restart
it, or talk it through.", or for a session at work with nothing to say yet, "Running · 12m").
Needs input comes before failed; running before waiting; within each, the session the person
touched last comes first, as the board's own view orders it. Sessions hidden or snoozed off the
board stay off the car's lists too. Both lists stop at twelve.

Tapping a row starts the Live Mode call — or, with one up, puts the line to it — with an opening
that names the session: "Let's talk about session 1038, "PR #1261 is green — merge it?". It is
needs input. Tell me where it stands in a sentence, then ask me what I want to do."

### The Live Mode call

While a call runs the screen is the voice control template, as the category requires of an app
that is recording. It carries everything the template can:

- **The call's state**, as the picture and the title: Connecting, Listening, Thinking, Speaking,
  Working on it. **Five states, one per call state** (`LiveCallScreen`), because CarPlay keeps the
  first five a voice control template is given and ignores the rest. "· Muted" is in the title, so
  muting rebuilds the screen. The first version built ten states (each with a muted twin), and
  CarPlay dropped Speaking and Working.
- **The session the conversation is about**, in the title's long variant: "Listening · Investigate
  the flaky poller test: running". It is the session the conversation touched last through a tool
  call — started with `quick_router`, checked with `get_session`, followed up with
  `action_session` — read from `GET /live_conversations/:id/sessions` every time the call relays
  a call or records a line. A voice control state's title is fixed when the state is made, so a
  new subject rebuilds the template and presents it in place of the old one: a blink, unanimated,
  after a moment's wait so a burst of tool calls is one rebuild. Muting rebuilds at once. With no subject yet, the
  long title says how many sessions need the driver.
- **What the call is doing**, while it works, as a trailing bar button used as a label:
  "Starting work…", "Checking on a session…", "Following up…". A bar button is the one text on
  this template that can change in place. An error on the call shows there too.
- **Mute** and **Hang up**, the two action buttons.

The call is the phone's `LiveCall`, so a call started at the desk carries on in the car and the
other way round; hanging up in the car ends it everywhere. A call already running when the car
connects is shown at once.

On iOS 27 the voice control template can be presented as an overlay over another template, which
would let the Needs you list stay visible under the call. CI builds with Xcode 26.6, which has no
iOS 27 SDK, so that is a follow-up.

A read of the board that fails never becomes "nothing needs you": the lists say the error.

## Crash-proofing

What made the first TestFlight builds crash in the car, and what holds each fix:

| Cause | Fix | Held by |
| --- | --- | --- |
| Template changes (present, dismiss, push, pop) made with `completion: nil`. CarPlay throws an exception when it refuses one of those and has no completion to report to, and it refuses a present over another modal or a change made mid-animation, which a call failing fast made easy | Every modal change goes through `CarPlayNavigator`, one at a time, against what is on screen at that moment. `CarPlayInterface.swift` calls the interface controller only through its async forms, which always give CarPlay a completion | `CarPlayTests`: the navigator against a strict fake that refuses what CarPlay refuses; a source guard on every interface-controller call |
| A voice control template built with ten states; CarPlay keeps five | Five states, muted in the title | `LiveContextTests`, and a source guard on how `CarPlayLive` builds them |
| The Live call's `AVAudioEngine` restarted on the route-change notification's thread while a hang-up stopped it on the main one — the car connecting or disconnecting is a route change | `LiveAudioEngine` is main-actor only; its observers run on the main queue; a media-services reset ends the call rather than touching a dead engine | Review; no test can drive AVAudioEngine on Linux |
| A microphone tap installed with a format read before the route settled | The tap takes the node's own format (`format: nil`) and reads each buffer's rate | Review |
| The system voice and its `.playback` audio session, switched on and off around a running call's `.playAndRecord` one | No system voice | `CarPlayTests` source guard |

## Voice triage, end to end

1. The car connects. The scene sets the tab bar as root and reads the board
   (`GET /sessions?view=user&status=needs_input,failed,running,waiting&include=board_row`, which
   carries each session's status summary in one call). The tiles show the counts; nothing is said.
2. The driver taps **Talk to Zimmer**. The scene reads
   `GET /live_conversations` for the open conversation, or starts one with `POST
   /live_conversations {mode: voice}`, and `LiveCall` turns voice on, mints the Realtime secret
   and opens the WebSocket. The call screen comes up. If it cannot, the Talk tile says so and the
   car retries, silently.
3. The driver talks. Live Mode's agent root (`live-mode`, in `tadasant/tadasant-internal`) has
   Zimmer's MCP surface: it checks sessions with `get_session` and `quick_search_sessions`,
   starts work with `quick_router`, passes answers with `action_session`, and answers questions
   with `respond_to_elicitation`. Each call is relayed by the phone to `POST
   /live_conversations/:id/tool_calls`, which records it as a tool turn.
4. The scene watches the call's activity. After each relay it reads
   `GET /live_conversations/:id/sessions`, the sessions those tool turns name, and the call
   screen's title names the newest.
5. Tapping a session's row starts the same call with an opening line, put to the model as if
   typed (`conversation.item.create` with a user message, then `response.create` under the
   conductor's usual rule) and recorded on the thread: "Let's talk about session 1038, "PR #1261
   is green — merge it?". It is needs input. Tell me where it stands in a sentence, then ask me
   what I want to do." The model reads the session and answers about that one first.
6. Hang up. The call screen goes, the board is read again, and the lists show what changed.

Every delegation a car-driven call makes is tagged `live_voice` for the receiving session, so the
background agent keeps its report short enough to be said aloud.

### What Live Mode's prompt should learn

The `live-mode` root's `modes/voice.md` already assumes the person may be driving and sends
anything long to the phone. Two things would make car triage better, and both belong to that root
in `tadasant/tadasant-internal`, not here:

- When the client surface is `carplay`, or the person says they are driving, open a resumed
  conversation with what needs them: one quick `quick_search_sessions` for `needs_input` and
  `failed`, read in a sentence each, then ask what to do with the first.
- Treat "yes", "go ahead" and "archive it" said about a session just read out as that session's
  answer (`action_session` follow-up, or archive), confirming a merge or an archive in one
  question first, as the guardrails already say.

## Driver-distraction checklist

| Guideline | How the app follows it |
| --- | --- |
| Voice is the primary modality at launch | The default button is the voice conversation; nothing is heard until it, or a row, is tapped (a deliberate reading, see Decisions) |
| Audio session only while voice is in use | `LiveCall` holds the only audio session, and only for the call; nothing is held while the home tab sits there |
| Record only with the voice control template | The microphone is opened only by `LiveCall`, whose screen in the car is the voice control template; the car has no other recogniser |
| No text or imagery in answer to queries | Answers are spoken by the model; the call screen shows a state word, one subject line and one activity label |
| Depth of 3 | Tab bar (1); nothing is pushed; the call screen is modal |
| Lists may be capped at 12 | `DrivingBoard.listLimit = 12`; the counts still say how many there are |
| Grid up to 8, tab bar up to 5 | 3 tiles, 3 tabs |
| Voice control template keeps 5 states | 5 states, one per call state (`LiveCallScreen`) |
| Few, large targets | Grid tiles; list rows of a title and one line |
| No dense text | A row is one line; nothing scrolls but a list |
| Destructive actions confirmed | The car has no destructive button; Live Mode confirms a merge or an archive out loud before it acts; trash is not offered |
| Nothing a driver cannot act on | A call that will not connect says so on the Talk tile and retries; a read that fails never claims an empty board |

## The backend

One route is new: `GET /api/v1/live_conversations/:id/sessions`, the sessions a conversation's
tool turns name — the `session_id`/`id` in a Zimmer gateway call's arguments, and the `**ID:**`
line, `/sessions/<id>` URL or "session #<id>" in a tool's output — most recently named first,
each with its board row (agent root, status summary). `LiveConversation#referenced_session_ids`
does the reading. A read, like `show`, so an API key may call it; the web's thread page could use
it to show the same strip.

## What is proven, and what is not

- `DrivingBoard`, `DrivingCard`, `DrivingWords`, `LiveActivity`, `LiveContext`, `LiveCallScreen`,
  `LiveRetry`, `CarPlayNavigator`, `LiveReferencedSessions` and the conductor's opening line are in
  ZimmerKit and tested on Linux and macOS on every iOS pull request: the split, the order, the
  caps, the row's opening line, the title variants, the rebuild rule, the five states, the retry
  budget, and the navigator against a strict fake that refuses what CarPlay refuses.
- `CarPlayTests` also reads the scene's source: no interface-controller call outside
  `CarPlayInterface.swift` or without a completion, no system speech anywhere in the app, no
  direct session action from the car, and the call screen built from `LiveCallScreen.states`.
  Each of those guards fails against the scene as it was before #1410.
- The Rails route and the id reading have controller and model tests.
- The CarPlay scene compiles in CI's Xcode job and is built into every TestFlight build, which
  signs in the entitlement. It has run in a car, where the first builds crashed (#1410).
- **The CarPlay drill** (`App/ZimmerUITests/CarPlayDrillUITests.swift`, run by
  `ios/bin/ui-test --carplay` in CI's `ios_carplay` job on every iOS pull request) opens Zimmer in
  the iOS Simulator's CarPlay window, which the script switches on from the Simulator's I/O menu,
  and drives the real templates through XCUITest (`CarPlayTemplateUIHost`): the home grid, a Live
  call that cannot connect and its retries, giving up on the tile, a tap after that, hanging up
  mid-connect, a Needs you row. Any crash fails it. Not driven: the audio route moving to a car
  (the Simulator has none), and a call that connects (CI has no microphone or OpenAI key), so the
  listening, speaking and working states and a subject rebuild are confirmed only by driving.

## Follow-ups

- **iOS 27 overlay.** Present the call over the Needs you list instead of in place of it. Needs
  Xcode 27 in CI.
- **Siri App Intents.** "What needs me?" and "Tell Zimmer to …" without opening the app; works in
  CarPlay without the entitlement. A phone-app change.
- **Crash reports.** The app ships no crash reporter; a crash in the car is visible only in
  TestFlight's crash feedback in App Store Connect. MetricKit (`MXCrashDiagnostic`) posted to Zimmer,
  or the Sentry SDK against GlitchTip, would bring them where an agent can read them.
- **A spoken new-arrival alert, opt-in or in-call.** Cut from this design; if wanted, it belongs
  inside an active Live call (the model mentions it) or behind a phone Setting that defaults off.
- **The prompt**, above, in `tadasant/tadasant-internal`.
