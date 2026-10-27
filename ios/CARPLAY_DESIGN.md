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
| "Primary modality of voice upon launch" | The car talks first: a spoken briefing on connect |
| "Only hold an audio session open when voice features are actively being used" | The audio session is held while the car speaks or a call runs, never idle |
| Recording "only in conjunction with the voice control template" | The microphone is open only while the voice control template is on screen: the Live Mode call |
| "Don't show text or imagery in response to queries" | Answers are spoken; the screen shows state and one line of context, never a transcript |
| Voice control template: up to 2 action buttons, leading and trailing bar buttons (26.4+) | Mute and Hang up on the call; Talk and Dismiss on the briefing |
| Some cars cap a list at 12 items; a grid holds up to 8; a tab bar up to 5 tabs | Lists stop at 12, the grid has 4 tiles, the tab bar 3 tabs |
| Notifications: communication, EV charging, parking, public safety and driving task apps only | **This category cannot show notifications in CarPlay.** The car is proactive by speaking instead |

Everything below fits inside that table. Where a nicer design wanted something outside it — a
Now Playing-style status card, an overlay of the call over the board, a notification — the
section says what it would take.

## Decisions

**One voice path, and it is Live Mode.** The first CarPlay app had two voices: an on-device
speech recogniser with a small command grammar (yes, archive, next, reply …) and, under it, a
section that started a Live Mode call. Two voices are one too many for a driver, who should never
have to wonder which one is listening, and the command grammar could not do what the driver
actually wants (ask what is going on, start something, follow up in their own words). The
recogniser is gone. Live Mode, the OpenAI Realtime call that delegates to Zimmer's MCP surface, is
the conversation. The car still speaks on its own, with the system voice, for the things that are
not a conversation: the briefing, a card read aloud, a confirmation that a tap worked.

**The default is Talk to Zimmer.** It is the big button on the briefing screen when the car
connects, the first tile on the home tab, and *Talk about it* on every card. One tap, no choice to
make: the open Live Mode conversation with voice on, or a new one with voice on. *New
conversation* and *Resume* were two buttons for a question a driver should not be asked; the
phone keeps both.

**The car speaks, the driver does not read.** The briefing on connect is spoken. Opening a card
speaks it. Each tap that touches Zimmer is confirmed out loud ("Told it to go ahead.", "Merge
authorized."), and a failure is spoken as the server worded it rather than announced as success.
The screen underneath carries the same words in large type for the glance that checks them.

**Decisions are taps; conversation is voice.** A yes-or-no decision on a session that needs the
driver — go ahead, merge, restart, archive — is a large button on a card, because a tap is
deliberate and a misheard word is not. Merge and archive ask once more (an alert with two
buttons); go ahead and restart act on the tap, because both only tell an agent to carry on.
Anything open-ended — a reply in the driver's own words, a question about a session, new work —
is *Talk about it* or *Talk to Zimmer*. Live Mode's own guardrails then apply: it confirms before
anything consequential, including merges and spending.

**Unavailable while driving:** trash (irreversible, and the card offers nothing it cannot say
aloud), new conversation, Live settings, typing, transcripts, logs, links, the hierarchy, notes,
scheduling, effort, catalog changes. The phone has all of them. The car offers what fits in one
glance and one tap.

**Proactive, without notifications.** The category cannot show CarPlay notifications, so the car
surfaces decisions three other ways: the spoken briefing on connect, a badge on the *Needs you*
tab and a count on its tile, and a spoken line — with *Talk about it* on screen — when a session
enters Needs you (or fails) while the car is connected. The board is re-read every minute. Push
notifications still reach the phone; CarPlay just does not display them for this category.

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
  connect([Car connects]) --> briefing["Briefing (voice control template, modal)\nspoken: what needs you, what is running\n[Talk to Zimmer] [Dismiss]"]
  briefing -- ends or Dismiss --> tabs
  briefing -- Talk to Zimmer --> call
  subgraph tabs [Tab bar — root, depth 1]
    home["Zimmer (grid)\n[Talk to Zimmer] [Briefing]\n[Needs you · n] [Running · n]"]
    needs["Needs you (list, ≤12)\nneeds input, then failed\n● badge while any"]
    running["Running (list, ≤12)\nrunning, then waiting"]
  end
  home -- Talk to Zimmer --> call
  home -- Briefing --> briefing
  needs -- row --> card
  running -- row --> card
  card["Session card (information template, depth 2)\nspoken on open\nNeeds you · Status · Pull request\n[Merge / Go ahead / Restart] [Talk about it] [More]"]
  card -- More --> sheet["Action sheet (modal)\nGo ahead · Read aloud · Archive"]
  card -- Merge / Archive --> confirm["Alert (modal)\n[Merge #1261] [Cancel]"]
  card -- Talk about it --> call
  call["Live Mode call (voice control template, modal)\nstate picture + title with the subject session\nactivity label in the bar\n[Mute] [Hang up]"]
  call -- Hang up --> tabs
  arrival([A session enters Needs you]) --> alert["Spoken alert (voice control template, modal)\n[Talk about it] [Dismiss]"]
  alert -- Talk about it --> call
```

| Screen | Template | Depth | Why this template |
| --- | --- | --- | --- |
| Root | Tab bar, 3 tabs | 1 | One tap between the three questions, no back button; the *Needs you* tab wears the red badge |
| Zimmer (home) | Grid, 4 tiles | 1 (a tab) | A grid's tiles are the largest targets CarPlay draws; four fill one row |
| Needs you, Running | List, ≤ 12 rows | 1 (a tab) | A row is a title and one line; the car may show only 12 |
| Session card | Information template | 2 | Large labels and up to three footer buttons: the one screen that must be read, kept to three lines |
| More | Action sheet | modal | The rest of the actions, the destructive one last |
| Merge? Archive? | Alert | modal | One question, two buttons |
| Briefing, spoken alert | Voice control template | modal | Apple's screen for a voice in use, with the two action buttons 26.4 allows |
| Live Mode call | Voice control template | modal | The only screen allowed while recording |

Nothing is pushed deeper than the card. A sheet, an alert or a voice screen is presented over
whatever is there, one at a time.

### The home tab

Four tiles: **Talk to Zimmer** (first; *Back to the call* while one runs), **Briefing** (says the
briefing again), **Needs you · n** and **Running · n** (each switches to its tab). The counts are
the glance; the tiles are the taps.

### Needs you and Running

Each row is the session's title and one line: the first sentence of its status summary as plain
words, or, when there is none, what its status means ("Waiting for your reply.", "Failed. Restart
it, or talk it through.", or for a session at work with nothing to say yet, "Running · 12m").
Needs input comes before failed; running before waiting; within each, the session the person
touched last comes first, as the board's own view orders it. Sessions hidden or snoozed off the
board stay off the car's lists too. Both lists stop at twelve.

### The session card

Opening a row pushes the card and speaks it. The card is an information template:

- **Needs you** (or **Now**): the headline, in the template's large type.
- **Status**: "Needs input · 12m".
- **Pull request**: "#1261 · open · CI green", when the session has one.

The footer holds at most three buttons, the decision first and drawn as the confirming style:

| Session | First | Second | More |
| --- | --- | --- | --- |
| Needs input, with an open green PR | **Merge #1261** | Talk about it | Go ahead · Read aloud · Archive |
| Needs input | **Go ahead** | Talk about it | Read aloud · Archive |
| Failed | **Restart** | Talk about it | Read aloud · Archive |
| Running or waiting | Talk about it | Read aloud | — |

*Go ahead* sends "Yes, go ahead." as a follow-up tagged `carplay` with no modality (a tap is not
dictation). *Merge* is the person's sign-off (`POST /sessions/:id/authorize_merge`), which the
server takes only from the app on a grant that acts as you. A successful action is spoken, the
card closes, and the board is read again. A speaker button in the bar reads the card again.

### The Live Mode call

While a call runs the screen is the voice control template, as the category requires of an app
that is recording. It carries everything the template can:

- **The call's state**, as the picture and the title: Connecting, Listening, Thinking, Speaking,
  Working on it; "· Muted" beside it. Ten states are built up front (five states, muted and not),
  so a state change is one `activateVoiceControlState`.
- **The session the conversation is about**, in the title's long variant: "Listening · Investigate
  the flaky poller test: running". It is the session the conversation touched last through a tool
  call — started with `quick_router`, checked with `get_session`, followed up with
  `action_session` — read from `GET /live_conversations/:id/sessions` every time the call relays
  a call or records a line. A voice control state's title is fixed when the state is made, so a
  new subject rebuilds the template and presents it in place of the old one: a blink, allowed only
  when the subject changes and not more than once in a couple of seconds. With no subject yet, the
  long title says how many sessions need the driver.
- **What the call is doing**, while it works, as a trailing bar button used as a label:
  "Starting work…", "Checking on a session…", "Following up…". A bar button is the one text on
  this template that can change in place. An error on the call shows there too.
- **Mute** and **Hang up**, the two action buttons.

The call is the phone's `LiveCall`, so a call started at the desk carries on in the car and the
other way round; hanging up in the car ends it everywhere.

On iOS 27 the voice control template can be presented as an overlay over another template, which
would let the Needs you list stay visible under the call. CI builds with Xcode 26.6, which has no
iOS 27 SDK, so that is a follow-up.

### The briefing and the spoken alert

On connect, after the board is read, the car speaks: "Two sessions need you. First: PR 1261 is
green — merge it? CI is green and the review is done. Second: Which Postgres version should staging
run? Waiting for your reply. One running." Up to three are read in full; the rest are counted. It
is spoken under a voice control template titled *Zimmer briefing* with two buttons, **Talk to
Zimmer** and **Dismiss**, which stays four seconds after the words end and then leaves on its
own. A call already running when the car connects is shown instead; the model is the voice then.

When a later read finds a session that was not in Needs you before, the car says "Zimmer: Rotate
the staging deploy key. It failed. The deploy key in the store is read-only for this session."
under the same screen, with **Talk about it** (which opens the call on that session) and
**Dismiss**. One arrival is spoken per read; the rest are on the list and the badge.

A read that fails never becomes "nothing needs you": the lists say the error, and the briefing
says "I couldn't check your sessions" and why.

## Voice triage, end to end

1. The car connects. The scene sets the tab bar as root, reads the board
   (`GET /sessions?view=user&status=needs_input,failed,running,waiting&include=board_row`, which
   carries each session's status summary in one call), and speaks the briefing.
2. The driver taps **Talk to Zimmer** (on the briefing, or the home tile). The scene reads
   `GET /live_conversations` for the open conversation, or starts one with `POST
   /live_conversations {mode: voice}`, and `LiveCall` turns voice on, mints the Realtime secret
   and opens the WebSocket. The call screen comes up.
3. The driver talks. Live Mode's agent root (`live-mode`, in `tadasant/tadasant-internal`) has
   Zimmer's MCP surface: it checks sessions with `get_session` and `quick_search_sessions`,
   starts work with `quick_router`, passes answers with `action_session`, and answers questions
   with `respond_to_elicitation`. Each call is relayed by the phone to `POST
   /live_conversations/:id/tool_calls`, which records it as a tool turn.
4. The scene watches the call's activity. After each relay it reads
   `GET /live_conversations/:id/sessions`, the sessions those tool turns name, and the call
   screen's title names the newest.
5. **Talk about it** on a card starts the same call with an opening line, put to the model as if
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
| Voice is the primary modality at launch | The briefing is spoken on connect; its big button is the call |
| Audio session only while voice is in use | `CarPlaySpeech` holds a playback session only while a line is spoken and releases it; `LiveCall` holds its own only for the call |
| Record only with the voice control template | The microphone is opened only by `LiveCall`, whose screen in the car is the voice control template; the car has no other recogniser |
| No text or imagery in answer to queries | Answers are spoken by the model; the call screen shows a state word, one subject line and one activity label |
| Depth of 3 | Tab bar (1) → card (2); everything else is modal |
| Lists may be capped at 12 | `DrivingBoard.listLimit = 12`; the counts still say how many there are |
| Grid up to 8, tab bar up to 5 | 4 tiles, 3 tabs |
| Few, large targets | Grid tiles; list rows of a title and one line; card footers of at most three text buttons; alerts of two |
| No dense text | A card shows three labelled lines; a row one line; nothing scrolls but a list |
| Destructive actions confirmed | Merge and archive ask; trash is not offered |
| Nothing a driver cannot act on | Failures are spoken and shown as the server worded them; a read that fails never claims an empty board |

## The backend

One route is new: `GET /api/v1/live_conversations/:id/sessions`, the sessions a conversation's
tool turns name — the `session_id`/`id` in a Zimmer gateway call's arguments, and the `**ID:**`
line, `/sessions/<id>` URL or "session #<id>" in a tool's output — most recently named first,
each with its board row (agent root, status summary). `LiveConversation#referenced_session_ids`
does the reading. A read, like `show`, so an API key may call it; the web's thread page could use
it to show the same strip.

## What is proven, and what is not

- `DrivingBoard`, `DrivingCard`, `DrivingAction`, `Briefing`, `DrivingWords`, `LiveActivity`,
  `LiveContext`, `LiveReferencedSessions` and the conductor's opening line are in ZimmerKit and
  tested on Linux: the split, the order, the caps, every button set, every confirmation, the
  spoken lines, the title variants and the rebuild rule.
- The Rails route and the id reading have controller and model tests.
- The CarPlay scene compiles in CI's Xcode job and is built into every TestFlight build, which
  signs in the entitlement. **No head unit or CarPlay Simulator has shown it.** The template
  tree, the voice control template's action buttons and bar buttons on iOS 26.4, the rebuild on a
  new subject, and how the car's audio ducks under the briefing are unobserved until the first
  TestFlight build is tried in a car. XCUITest cannot reach the CarPlay window, so there are no
  screenshots.

## Follow-ups

- **iOS 27 overlay.** Present the call over the Needs you list instead of in place of it. Needs
  Xcode 27 in CI.
- **Siri App Intents.** "What needs me?" and "Tell Zimmer to …" without opening the app; works in
  CarPlay without the entitlement. A phone-app change.
- **Tag the car's call as `carplay`.** The car's Live call is the phone's `LiveCall` on the phone's
  client, so its delegations are tagged `ios · live_voice`. A per-call client source on the live
  routes would make them `carplay`.
- **A quiet switch.** The spoken alert for a new arrival has no off switch yet; one belongs in the
  phone's Settings.
- **The prompt**, above, in `tadasant/tadasant-internal`.
