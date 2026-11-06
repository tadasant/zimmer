# Zimmer in the car

The design for Zimmer's CarPlay app: what a driver can do with Zimmer, and why it is so little.
This is the engineering design doc for `App/Zimmer/CarPlay/` and `Sources/ZimmerKit/Driving/`; the
user-facing prose is [docs: The iOS app → CarPlay](https://docs.zimmer.tadasant.com/extend/ios-app/#carplay).

## The moment it is for

Someone is driving. Their hands are on the wheel and their eyes are on the road. What they want
from Zimmer is a conversation: what needs me, deal with this, start that. Zimmer already has the
thing that does all of it by voice, Live Mode, the OpenAI Realtime call that delegates to Zimmer's
MCP surface. So the car is Live Mode, plus the one thing a call cannot do for itself: be repaired
when it has stopped working (*Break glass*, below).

## What Apple allows

Zimmer's CarPlay scene is a **voice-based conversational app**, the category Apple added in iOS
26.4 (`com.apple.developer.carplay-voice-based-conversation`). Apple's CarPlay App Programming
Guide (the 2026-10-13 edition) fixes what such an app can be:

| Rule | What it means here |
| --- | --- |
| Templates: action sheet, alert, grid, list, tab bar, information, voice control (26.4+) | Zimmer uses three: a grid (the home's tiles), the voice control template (the call) and a list (the voice settings, behind the call screen's gear) |
| "Primary modality of voice upon launch" | Each tile is a voice conversation, one tap away; the car stays silent until the driver taps one (see Decisions) |
| "Only hold an audio session open when voice features are actively being used" | The audio session is held only while a call runs, never idle |
| Recording "only in conjunction with the voice control template" | The microphone is open only while the voice control template is on screen: the call. The gear ends the call before its screen comes down, so the panel never records |
| "Don't show text or imagery in response to queries" | Answers are spoken; the call screen shows a state word, never a transcript |
| Voice control template: up to 2 action buttons, leading and trailing bar buttons (26.4+) | Mute and End; the gear to the voice settings is the leading bar button. A trailing bar button as a status line did not render in the Simulator's CarPlay window, so there is none |
| Voice control template: up to 5 states (`init(voiceControlStates:)`) | Exactly five, one per call state (`LiveCallScreen`) |
| Notifications: communication, EV charging, parking, public safety and driving task apps only | **This category cannot show notifications in CarPlay**, and Zimmer does not try to be proactive in the car |

## Decisions

**Continue or new: the driver chooses.** This reverses *one button, no choice to make* from
*Radically simple*, on purpose and only this far. Tadas, from the car: *"give the user two options:
start a new live session with Zimmer, or continue the most recent live session. Live mode is a
single thread, but the user wants an explicit choice."* The one button always resumed, so a fresh
start in the car meant ending the conversation on the phone or asking the live model to forget.

Live Mode is still one thread: New ends the open conversation, as the phone's New conversation does,
and nothing runs in parallel. The home is still the one grid, so no template was added.

| The home is | Its tiles |
| --- | --- |
| At rest, with a conversation open, or before Zimmer has said | **Continue** and **New** |
| At rest, with nothing open | **New** |
| Connecting, retrying, or in a call | The one tile saying so |
| Given up | **Retry** and **New** |

- **One tap, no confirmation.** An ended conversation stays readable, so New loses nothing, and an
  alert would be one more modal for CarPlay to refuse. The phone asks because a New there is a
  toolbar button in reach of a stray thumb on a thread being read; here it is a decision the driver
  came to the screen to make.
- **Nothing to continue is one tile, not a disabled one.** A tile that does nothing is a target a
  driver has to read to rule out.
- **Both tiles before Zimmer has answered.** A conversation stays open until something ends it, so
  one nearly always is. A *Continue* appearing beside *New* after a second would move the tile a
  finger is reaching for. If the read fails, or was stale, the tap reads again.
- **Continue means the open conversation.** A conversation that has ended cannot take a call, because
  `LiveConversations::Actions` mints a Realtime secret only for an open one. So the most recent
  conversation is continuable only while it is open, and otherwise the honest offer is New.
- **Continue never swaps threads.** If the tap finds nothing open, because it ended on the phone
  since the tiles were drawn, the car calls nobody: the falling notes play and the tiles come down
  to New. A retry or a dropped call that finds nothing open does the same. A new conversation in
  its place would sound like a live model that had forgotten everything, with nothing to say why.
- **New is spent when Zimmer answers it** (`CarLiveWish`). Starting ends the open conversation, so a
  retry that started again would end the one the driver had just asked for. Once Zimmer has answered,
  retries and drops go through Continue, onto that conversation. A start Zimmer never answered
  stays New, so Retry does not go back to the conversation the driver chose to leave.
- **A running call wins.** Any tile with a call up goes back to it and takes it over from the phone.
  A stale New tile never ends a call: End does that.
- **Given up keeps New.** A conversation that will not connect is when a fresh one is most useful,
  and Retry alone would hold the driver on it.
- **A second tap is not a second start.** The lookup is marked before the first `await`, so one
  arriving during it changes nothing.
- **The comeback is unchanged.** Closing the voice settings calls the same conversation again,
  whatever the tiles say. A tile tapped after that gives up makes the driver's own choice. Retry
  keeps a mute the comeback was holding. New lets go of it, because a driver who chooses a fresh
  start has asked to talk.

The home reads what is open when the scene connects and when the driver's call ends, not when the
phone ends a call the car started: there the tap finds out. It is a read, so the car stays silent
(*Silent until asked*).

**Break glass.** Everything else in the car is voice, and that is exactly what fails here: a call the
live model has mis-tuned cannot be asked to fix itself. Tadas asked for a touch way out, reachable
from the call. So the call screen has a gear, and behind it one list, the voice settings. This
reverses *radically simple* below on purpose and only this far: one list, reached only from the
call, holding only settings.

The request was for sensitivity, and there is no such setting. There is no microphone gain, no wake
sensitivity (the wake word is a regex), and the closest thing, `voice_vad_threshold`, is not what
broke anything. What the post-mortem of a broken call found (session 26864, call `40d6bb43`):

- `voice_max_output_tokens` at 180, set by the live model, truncated 12 of 13 replies and the 4 tool
  calls that failed. It is the panel's first row, and Reset clears it.
- A gated Listening dropped every line of a call handed from the car to the phone, which is what
  "it can't hear me" looked like: speech transcribed, then `respond=false`. A call that has been on
  the car now stays on Always until it hangs up, so the setting reaches only calls started on the
  phone. The row says so.
- Under Semantic turn detection `RealtimeSession` sends eagerness and nothing else, so threshold,
  pause and prefix padding go nowhere. A threshold of 0.92 was inert.

So the panel is built from what a call acts on (`CarVoiceSettings`). **It shows only what the
current turn detection sends to OpenAI, and Listening, marked Phone only:** under Semantic there is no threshold or pause row, and
Turn detection says the threshold needs Silence; under Silence there is no eagerness row. Prefix padding has
no row at all, being fine-tuning with no failure anyone has seen; Reset clears it.

All of it is the one `LiveSetting` row, through `LiveAPI`, into the same
`LiveConversations::SettingsUpdate` as the live model's `update_live_settings`. So a value voice left
is the value shown, and a change here lands in the history as "the iOS app".

**Reset to defaults** clears every setting the panel covers, a hidden one included, and nothing else.
It leaves the model, the voice and Call telemetry, which are somebody's choice and not a knob pushed
too far, and the guidance, which has its own history. It sits straight under the way back, and it asks for no
confirmation: it is the break-glass, every value it clears stays in the history, and an alert would
be one more modal for CarPlay to refuse. The app's Live settings screen and the live model's
`reset_to_defaults` are wider, for that reason: everything but the guidance.

**The gear ends the call; closing the panel brings it back.** CarPlay allows recording only with the
voice control template on screen, and a list cannot be presented over that modal: it has to be
pushed, and the call screen has to come down first. Muting would leave the microphone open, and
holding the call would mean a new state for an audio engine no test can drive. So the call hangs up,
which closes the microphone and releases the audio session, and whatever it was saying or doing on
the phone's side of the call stops: a reply is cut off, and a tool call still running on Zimmer's
side finishes with nobody to tell. When the panel closes, by its own *Back to the call* or by
CarPlay's Back, the same conversation is called again, muted if it was muted, with the same quiet
retries as any call. The rising notes say it is back. CarPlay's Back knows only the one template, so
from a row's choices it closes the panel too. The gear does nothing on a call already ended: the
screen stays tappable for a moment after End, and that must not redial it (`CarCallComeback`).

**Every change takes effect on the call that comes back, not before.** Nothing is listening while
the panel is up, and that call is minted from the row, so anything OpenAI fixes for a call's life
would apply too. Listening is the exception: the call that comes back is a car call, so a change
reaches the next call started on the phone. Closing waits for the driver's last write, showing *Saving…*, so the
call cannot read the row ahead of it. A write that failed keeps the panel up to say *Not saved*, and
the next Back closes it on what the row holds. With CarPlay's Back there is no panel left to say it
on, so the call comes back on the old value and the log records `settings_write_lost`. A call that starts on the phone meanwhile is the conversation: the panel goes, and the
call the gear ended stays ended. So does one whose car disconnects with the panel up.

**A call the car leaves goes to the phone's screen, without being asked and without being in the
way.** The audio has always carried on when the car goes; the phone used to stay on whatever it
showed, with no way to the call but opening Live. Now the phone lands on that call's thread
(`LiveHandover`, ZimmerKit; `LiveCall.carLeft`). A driver who has pulled in should find the call in
front of them, and the rules are mostly about when not to do it:

- **The route follows the audio.** It arms on `call.isActive` at disconnect, the same test that
  carries the call on, so Connecting… counts. A call waiting on its retry, one that ended moments
  before, and one the gear ended do not: all three are idle, and disconnect stops the retry and
  forgets the comeback, so nothing is carried on to look at.
- **Three seconds first.** CarPlay drops with the car moving, through a cable, wireless or a
  Bluetooth blip, and a phone on a dash mount should not change screens for one. So "immediately"
  costs up to three and a half seconds, and the car coming back inside that leaves the phone where
  it was. An outage longer than that does move the phone, and a reconnect then leaves it on the
  thread of the call the car is showing: the same call in two places, not two things to deal with.
- **The next foreground, for as long as the call lives.** iOS will not bring an app forward, so a
  locked or backgrounded phone waits. There is no timer: a call still up an hour later is still what
  the phone is doing. One landing, for that call: its end forgets the route, and the route is
  checked against the call again on arrival. It lives in memory, because the call does.
- **It only opens.** Nothing is dismissed, so nothing typed can be lost. While anything is presented
  over the tabs (asked of UIKit, because a session page's sheets are its own, and UIKit refuses a
  second presentation), or the keyboard is up, it waits, and goes when they clear. Live's own list
  gets the thread pushed; the call's own thread spends the route; another thread is left alone, since
  its composer may hold a draft, until the person backs out of it.
- **The person wins.** Opening a session, from a row, a push or a link, forgets the route, and so
  does closing Live: Done on another thread must not bring Live straight back up. The half second
  before the first look is what lets a push tap arrive first.
- **Nothing happens to the call.** The landing opens the thread with `voice: false`: no
  `POST …/mode`, no `call.start`, no microphone, no audio, no cue, no touch needed.

The state is on `LiveCall.shared`, not `AppModel`, because CarPlay can run the app with no phone scene
and so no model. `CarHandoverLanding` sits with the tabs, so a phone scene opening cold, signing
in or not, reaches it the same way as one open all along. The reconnect's `carCameBack` comes after
`didConnect`'s own tear-down, which would otherwise arm a route on every scene restart. Nothing
changes for the web or any other client: the call only ever lived in this process.

"The car came back" means Zimmer's scene connected, not that a cable went in. If the car returns and
nobody opens Zimmer on it, the scene stays away, so the call is still the phone's and the next
foreground lands on it. That is true to where the call is. A long-press menu is not a presentation
UIKit reports, so a landing can close one; nothing typed lives in a menu.

There is no nudge. A notification is a sound or a banner while possibly still driving, and a Lock
Screen Live Activity is a new surface, which is a product decision (*Follow-ups*). The call's own
audio is the signal.

**Radically simple: open, talk, mute, end.** After the first CarPlay builds crashed in a car
(#1410), Tadas cut the app to the flow a driver actually uses: *"open the app, start talking to
zimmer, mute, end conversation, maybe show some details while talking but keep em minimal, no
multi-page nav."* The car has two screens: the home, and the call, and the voice settings behind
it are the one exception (*Break glass*). The home was one button until *Continue or new*. Gone, deliberately: the tab
bar, the Needs you and Running lists and their counts, the minute-by-minute board read, the
per-session rows, the session cards and their Merge / Go ahead / Restart / Archive buttons, the
confirm alerts and action sheet, the call title naming the session being discussed and the screen
rebuilds it caused. Each was one more template, or one more template change, for CarPlay to refuse;
none was something to do while driving that Live Mode cannot do by voice. Bring one back only with
a drill step that drives it (see *The CarPlay drill*).

**One voice, and it is Live Mode's.** The car never speaks with the system voice: no briefing, no
read-aloud, no spoken confirmation, no spoken error. Tadas: *"I should never hear the robotic voice
that just reads stuff. It should always be real-time."* A source guard (`CarPlayTests`) fails the
build on any `AVSpeechSynthesizer` in the app.

**Hear the call, don't watch it.** A driver should never have to look to know whether Zimmer is
listening, working, stuck or finished. Silence alone cannot say which, so the call has short
synthesized cues, which are tones, not a voice (`LiveCue`; `LiveCueDirector` holds the event-to-cue
table):

| Cue | Sound | Plays |
| --- | --- | --- |
| connected | E5, B5, soft and rising | Once, when the call is up |
| heard | E5, short and quiet | 0.35 s after the driver stops talking, on a line that will be answered |
| thinking | a 520 Hz tick, once a second | From 1 s after the end of speech to the reply, no tool running; gives up after 45 s |
| working | E4, G4, a soft pair, every 2.5 s | While a tool runs, for as long as it runs |
| failed | F4, D4, low and falling | A tool failed, a reply failed or was cut short, an error ended the wait, or a loop gave up |
| ended | E4, one soft note | The driver hung up |
| disconnected | B5, E5, falling | The call dropped |

Rising is *on*, falling is *off*, and working shares neither pitch, length nor pace with the tick.
Success has no cue, because the answer follows and a chime on every tool would wear on a long
drive; so nothing can pass for it. The cues that repeat stay at the tick's level and are mostly
silence. Every cue stops the instant the driver talks or the reply's audio starts, and a cue
due during the tail of a reply waits it out. The cues play through the call's voice-processing
engine, so the echo canceller has them as reference, and while one sounds the microphone is sent as
silence (`LiveCueGate`), so turn detection never takes a cue for speech.

**A turn always ends.** OpenAI's turn detection over a WebSocket measures silence in the audio it
receives. A microphone that stops delivering mid-sentence leaves the turn open, and the call sits
on Listening for ever. After 300 ms without microphone audio the call sends silence in its place
and asks the engine to restart (`MicWatchdog`). It is the same rule as a muted call's silence
(#1372), applied to a microphone that went quiet on its own.

**Every call leaves a trace, and every trace has an end.** The car cannot be tested from CI, so each
call logs every step to Zimmer's shipped logs (`LiveTelemetry` → `POST /api/v1/live/telemetry` →
`ios.live` records in VictoriaLogs). `call.ended` is kept in `UserDefaults` until a batch carrying it
has been answered, and the open call is too, so a call the app died in gets `call.ended`
`reason=abandoned` on the next launch, carrying when it was last seen. The Live setting *Call
telemetry* turns it down or off without a build. See
[docs: observability](https://docs.zimmer.tadasant.com/operate/observability/#the-ios-apps-call-log).

**One thread.** Everything the driver says goes to the one Live Mode conversation: Continue resumes
the open conversation with voice on, and New ends it and starts another (*Continue or new*). Live Mode acts on sessions itself, with
its own guardrails (it confirms before a merge or anything that cannot be undone). The car has no
way to act on a session directly, and a source guard keeps it that way.

**Silent until asked.** Opening the app says nothing. The call starts only when the driver taps a
tile. The category's "primary modality of voice upon launch" is read as *the default action is
voice*, not *the app speaks first*.

**Live Mode unavailable is shown and heard, never spoken.** When the call cannot connect, or drops,
the tile says *Live Mode unavailable, retrying…* and the car tries again after 2, 5 and 15 seconds
(`LiveRetry`), with no voice. The falling notes sound at the first failure and again when it gives
up, so a driver knows without looking. Once the retries are spent, or 30 seconds have gone from the
tap or the drop, it says *Live Mode unavailable. Tap to retry*; a tap is a fresh budget, a call that
comes up earns it back, and ending the call stops the retries. A call that never came up has no
engine to play the notes, so it gets a short-lived one for them, in the call's own audio category
and for as long as they sound (`LiveAudioEngine.playAlone`).

**A call that will not connect gives up in 15 seconds.** The driver's answer comes quickly or it is
no use, and calls that work come up in 2 to 3 seconds. A call is up when its microphone is open and
OpenAI has said `session.created`, so *Listening* and the connected notes mean somebody can hear
you; the socket merely having been asked to open proves nothing. A tap answers at once (the tile
says *Connecting…*), a second tap is not a second attempt, and finding the conversation has the same
deadline. Two calls that each hang to the deadline come to about half a minute, then *Tap to retry*
(`LiveCallHealth`).

**Nothing that can block runs on the main thread.** One call sat on Connecting… for 770 seconds with
the time inside the audio engine's start, which was on the main thread: no deadline could fire, End
could not be pressed, and the screen could not change. Starting, restarting and stopping the engine
run on one serial queue (`LiveAudioEngine.queue`), and an engine out there is not the call's until
it comes back. A call can give up on one that is stuck, and whatever comes back is torn down. The
queue is serial on purpose, so a stuck engine holds up the calls after it too: they time out the same
way, the falling notes can't play, and calling works again only once it comes back.

**A dropped connection is noticed, and the car calls back.** A socket that errors ends the call, on
receive, send or ping. A socket that just goes quiet is pinged: after 10 quiet seconds, and once as
soon as the call is up, to learn that pongs come. Only a call that has had a pong can be called dead,
20 seconds after it last heard anything, so a server that does not answer pings costs the detection
and not the call. Then the falling notes play, the call ends, and the retries above start a new one
on the same conversation. There is no resuming the old socket: a Realtime session belongs to its
connection. The phone has no retries, so there the call says what happened and stops.

**A lost microphone says so.** Past 2 seconds without microphone audio the call screen goes back to
Connecting… (a sixth state is one CarPlay would drop), the phone says *Waiting for the microphone…*,
and the falling notes play if the audio is still ours. When it comes back the rising notes play. An
interruption can hold the microphone for 90 seconds, because they do come back (one ran 55 seconds
and the call carried on) and iOS does not promise to say when one ends; a microphone that stopped
on its own gets 20, counted from when the interruption let go of it. Then the call ends, as a drop
does. An app with a phone call in progress cannot
make a sound at all, so during one of those this is only shown.

## Screens

```mermaid
flowchart TD
  connect([Car connects, silently]) --> home["Zimmer (grid, root)\n[Continue] [New]\nNew alone with nothing open"]
  home -- "Continue: the open conversation" --> call["Live Mode call (voice control template, modal)\nstate picture + title: Connecting… / Listening / Speaking / Working on it… / Muted\n[Mute] [End]"]
  home -- "New: ends the open one, starts another" --> call
  home -- "Continue, nothing open: falling notes, no call" --> home
  call -- End --> home
  call -- "gear: ends the call" --> panel["Voice settings (list, pushed)\n[Back to the call] [Reset to defaults]\n[Reply length cap] [Turn detection] …"]
  panel -- "Back to the call, or CarPlay's Back: calls again" --> call
  panel -- a row --> choices["The row's choices (the same list, redrawn)"]
  choices -- a choice, or Back to settings --> panel
  call -- cannot connect in 15 s, or drops --> retry["tile: Live Mode unavailable, retrying…\nfalling notes once\n(2 s, 5 s, 15 s, no more than 30 s)"]
  retry -- a retry connects --> call
  retry -- retries spent --> tap["tiles: Live Mode unavailable. Tap to retry, and New\nfalling notes"]
  tap -- Retry or New --> call
```

| Screen | Template | Why this template |
| --- | --- | --- |
| Zimmer | Grid, one or two tiles | A grid's buttons are the largest targets CarPlay draws |
| The call | Voice control template, presented | The only screen allowed while recording |
| Voice settings | List, pushed | Text and a value, large rows, and CarPlay's own limits on them. No slider exists, so every value is a few discrete choices |

The call screen is the only modal. It is built once per call, presented when the call starts and
dismissed when it ends, through `CarPlayNavigator`, one change at a time. It is never rebuilt. The
voice settings are the only thing pushed, also through the navigator. A row's choices are the same
list with its sections replaced, so opening one is no template change, and nothing is deeper than
that one push.

Reachable only from the call screen, in any of its states: the home screen has no gear, so while a
tile says it is retrying there is no way to the settings. The settings are all on the phone's Live settings
screen too.

### The call screen

- **The call's state**, as the picture and the title: Connecting…, Listening, Speaking, Working on
  it… (thinking included), or **Muted** while the microphone is off. Five states, because CarPlay
  keeps the first five a voice control template is given (`LiveCallScreen`). A state change, Mute
  included, is one `activateVoiceControlState`; the template is never rebuilt.
- **Mute** and **End**, the two action buttons.
- **The gear**, the leading bar button. It is set on the template when it is built, so it takes no
  state and costs no rebuild.

The first version of this screen also had a status line (a trailing bar button: *Muted*, what the
call was doing, or an error). It never rendered in the Simulator's CarPlay window, so it is gone;
an error that ends the call shows on the home's tile instead.

The call is the phone's `LiveCall`, so a call started at the desk carries on in the car and the
other way round; ending it in the car ends it everywhere. A call already running when the car
connects is shown at once.

## Crash-proofing

What made the first TestFlight builds crash, or misbehave, in the car, and what holds each fix:

| Cause | Fix | Held by |
| --- | --- | --- |
| Template changes made with `completion: nil`. CarPlay throws an exception when it refuses one and has no completion to report to, and it refuses a present over another modal or a change mid-animation | Every modal change goes through `CarPlayNavigator`, one at a time; `CarPlayInterface.swift` calls the interface controller only through its async forms, which always give CarPlay a completion | `CarPlayTests` (the navigator against a strict fake; a source guard on every interface-controller call); the CarPlay drill |
| CarPlay's `presentedTemplate` is a stand-in, not the object presented, so a dismissal that compared by identity never happened and the call screen stayed up, "Connecting…", over a car that had given up | The navigator tracks the modal it put up itself and asks CarPlay only whether anything is up | `CarPlayTests.testTheCallScreenComesDownWhenCarPlayHandsBackAStandInForIt`; the drill's no-call-screen check |
| A voice control template built with ten states; CarPlay keeps five | Five states, Muted one of them | `LiveCallScreenTests`, and a source guard on how `CarPlayLive` builds them |
| `@Published` publishes in `willSet`, so the screen read the state the call was leaving | Every sink on the call is received on the main queue's next turn | A source guard |
| The Live call's `AVAudioEngine` restarted on the route-change notification's thread while a hang-up stopped it on the main one; the car connecting or disconnecting is a route change | `LiveAudioEngine` decides everything on the main actor; its observers run on the main queue; an engine is reconfigured on one serial queue and belongs to it until it comes back; a media-services reset ends the call | A source guard for the blocking calls; review for the rest: no test can drive AVAudioEngine on Linux, and the Simulator has no car audio route |
| The audio engine's start blocked the main thread for 770 s with the call on Connecting…, so nothing could time it out or end it | Every call that can block runs on `LiveAudioEngine.queue`; `LiveCallHealth` gives up at 15 s | `CarPlayTests.testTheCallsThatCanBlockNeverRunOnTheMainActor`; `LiveCallHealthTests` |
| A microphone tap installed with a format read before the route settled | The tap takes the node's own format (`format: nil`) and reads each buffer's rate | Review |
| The system voice and its `.playback` audio session, switched on and off around a running call's `.playAndRecord` one | No system voice | A source guard |
| Tab bar, lists, cards, alerts, action sheet, a rebuilt call screen: many templates and transitions | Three templates; the call screen only goes up and down; one pushed list, whose pages are redraws | `CarPlayTests.testTheCarIsOneButtonOneCallScreenAndOnePanel` |
| A list pushed under a modal, or a pop with nothing pushed after the driver's own Back | The navigator takes the modal down first and pops only what it pushed, asking CarPlay how much is pushed rather than comparing templates | `CarPlayTests` (the strict fake models the stack); the drill for the push and the pop, not for the driver's own Back |
| The microphone open with no voice control template on screen | The gear hangs up before anything else | `CarPlayTests.testTheGearEndsTheCallBeforeThePanelGoesUp` |
| The gear is reported to have ended the app in a car (iOS 27.0.1, TestFlight 92.1), with no crash report to read. A process died mid-call and left it `abandoned`, not `hang_up`, so it very likely died before or during the gear's hang-up, ahead of the push and the panel. A closure written in a `@MainActor` type and handed to an Objective-C API opens with a compiler-inserted executor check, so it traps on its first instruction if CarPlay calls it off the main thread. **Inferred, not reproduced on a head unit, and not the only candidate**: a fault in the hang-up's farewell cue on a car route, which End shares, fits the log too | Every control on the call screen and the panel, and `templateDidAppear`, hands CarPlay a closure that belongs to no actor and hops to the main actor (`CarPlayTap`). Each arrival writes a durable mark, which an `abandoned` line reports as `last_mark`, and a call off the main thread logs `carplay.off_main` | `CarPlayTests.testATapFromAnyThreadRunsOnTheMainActorAndSaysItWasOff` and a source guard; the drill runs the gear's closure off the main thread |

## The CarPlay drill

`App/ZimmerUITests/CarPlayDrillUITests.swift`, run by `ios/bin/ui-test --carplay` in CI's
`ios_carplay` job on every iOS pull request (and the `carplay` shard after merge). The script builds
the app signed ad hoc with the CarPlay entitlement — the Simulator's CarPlay window lists no app
without one — and opens that window from the Simulator's I/O menu through System Events. XCUITest
then drives the real templates, which the system's `CarPlayTemplateUIHost` draws:

- the car opens on Continue and New and nothing else, and Continue is one tap to the call screen;
- the gear on the call screen, seen but not pressed, on a call the fixture holds on Connecting…
  (`-ZimmerFixtureVoiceTurnedUp`, with the settings a voice call left);
- the car unplugged with that call up, by the Simulator's own I/O menu, so the scene truly
  disconnects (`ios/bin/ui-test` clicks it, because a test on the phone cannot reach the Mac): the
  phone lands on the call's thread; and plugged back in, the call goes up on the car again;
- the panel, opened by the fixture running the gear's Swift closure off the main thread on the
  reconnected scene: the call screen is gone, it shows the
  cap of 180 and no threshold row, Silence brings the threshold back with its 0.92, Reset to defaults
  clears the cap, and Back to the call calls again, all by ordinary taps;
- a call that cannot connect (the fixture's Realtime secret points at `realtime.invalid`): it
  fails, retries, gives up with Retry and New on the home, and leaves no call screen;
- New from there, one tap to a call that retries and gives up the same way;
- the conversation ended on the phone's own Live screen, by ordinary taps in the same process, then
  Retry: no call, one tile, New, and a tap on it tries a call. The car's calls leave the system's
  microphone prompt over the phone, so the drill answers it first, with Don't Allow.

The tiles come back to rest only when a call ends, and no call in the drill connects or can be ended,
so the order is what reaches each state: Continue gets one tap at rest, and nothing to continue comes
last. Which conversation each tile called is `CarPlayTests`', because the drill can see only the
screen.

It does not press Mute or End. XCUITest finds the voice control template's two action buttons
(labelled by their symbols, "microphone off" and "hang up") but computes no hit point for them,
and neither an element tap nor a coordinate tap reaches them. The five states they switch between
are `LiveCallScreenTests`'; pressing them is confirmed only by driving. The gear is the same: its
hit point is {-1, -1}, and a click from the Mac at its place in the CarPlay window, tried from
System Events, did not open the panel. So the fixture runs the gear's closure from a background
thread 15 seconds after the call screen goes up. The drill proves the gear is on the screen, that its
closure survives being called off the main thread, and that the panel behind it works. Pressing the
gear is unconfirmed until someone does it in a car, and only that press can say which thread CarPlay
calls from: `carplay.off_main` in the log if it was off the main one, and `last_mark` on an `abandoned`
call if the app died after the tap arrived. List rows take ordinary
taps, so the panel is driven for real. CarPlay's own Back on the panel is not driven: the fixture
presses the gear once, and the one visit leaves by Back to the call.

It is one ordered test in one Zimmer process. In the Simulator, CarPlay connects Zimmer's scene to
the first process and never to one XCUITest relaunches: the window stays blank and `didConnect`
never fires, even after going home and tapping the icon again. Whether a head unit does the same
when iOS relaunches Zimmer (after a crash, say) is unknown; see *What is proven*. Zimmer must be
running after every step, and any crash report fails the job.

## Driver-distraction checklist

| Guideline | How the app follows it |
| --- | --- |
| Voice is the primary modality at launch | Each tile is the voice conversation; nothing is heard until one is tapped |
| Audio session only while voice is in use | `LiveCall` holds the only audio session, and only for the call |
| Record only with the voice control template | The microphone is opened only by `LiveCall`, whose screen in the car is the voice control template. A present CarPlay refuses does not stop the call, so until the next state change presents again the microphone can be open with no screen; the comeback takes that path like any call |
| No text or imagery in answer to queries | Answers are spoken by the model; the call screen shows a state word |
| Depth of 3 | One root; one pushed list; the call screen is modal |
| Few, large targets | Two grid tiles at most; two call buttons and the gear; list rows, each a name and a value, with at most five choices |
| Destructive actions confirmed | The car has no destructive button; Live Mode confirms a merge or an archive out loud. Reset to defaults does not ask: see *Break glass* |
| Nothing a driver cannot act on | A call that will not connect gives up in 15 seconds, says so on the tile with the falling notes, and retries |

## What is proven, and what is not

- `LiveActivity`, `LiveCallScreen`, `LiveRetry`, `CarLiveChoice`, `LiveCallHealth`, `CarPlayNavigator`,
  `LiveReferencedSessions` and the conductor are in ZimmerKit and tested on Linux and macOS on every iOS pull request.
- `CarPlayTests` also reads the scene's source: no interface-controller call outside
  `CarPlayInterface.swift` or without a completion, no system speech anywhere in the app, no direct
  session action, no template but the grid, the call screen and the one list, nothing pushed but
  the panel, the call ended before the panel goes up, every sink on the call deferred, and the call
  screen built from `LiveCallScreen.identifiers`.
- `CarVoiceSettingsTests` hold the panel's reads, writes and reset against the fake's row, and when
  a comeback exists and ends (`CarCallComeback`); a Rails
  test holds that a cap and a Listening set by voice are read and cleared over the same API, and that
  the next minted call has no cap.
- `LiveHandoverTests` hold when the phone goes to a call the car left on it, in every order of
  disconnect, reconnect, call ending, foreground and sheet; `LiveHandoverUITests` hold the screens,
  on the same calls the scene makes, with the fixture playing the car's moves.
- The CarPlay drill drives the real CarPlay templates in the Simulator's CarPlay window on every iOS
  pull request, one true disconnect and reconnect among them.
- **Not confirmed anywhere, until someone drives it:** a press of the gear (the fixture runs its
  action), CarPlay's own Back on the panel, a muted call coming back muted, which of the two
  tile titles a real head unit picks at its width, and how long a real cable or wireless blip lasts
  against the three-second settle. The drill's flap is one disconnect
  and one reconnect, seconds apart; a flap inside the settle is the fixture's.
- **Not driven anywhere:** the cold path, CarPlay running the app with no phone scene and the phone
  scene opening afterwards. XCUITest always launches with a window. It shares every line of the warm
  path after the route is armed, and the route lives outside the scene so that it can.
- **Not driven anywhere but a car:** the audio route moving to the car (the Simulator has none), and
  a call that connects (CI has no microphone and no OpenAI key), so Listening, Speaking and Working
  are confirmed only by driving, as are a real interruption, a socket going quiet and whether OpenAI
  answers pings (`socket.ping` in the log will say). Nor is a relaunch: in the Simulator a
  relaunched Zimmer never gets its CarPlay scene back (the window stays blank), and whether a car
  behaves the same after Zimmer crashes or is killed is untested. Nor is the call coming back from
  the panel to a voice: CI has no call that connects, so the drill proves it is called again and the
  rest is driving.

## Follow-ups

- **Continuing an ended conversation.** Continue offers only what is open. When a conversation can
  be reopened, `LiveAPI.conversation(for:)` is where Continue would reach for it, and the home's
  read is where a reopenable conversation would keep the Continue tile up.
- **iOS 27 overlay.** The voice control template as an overlay. Needs Xcode 27 in CI.
- **Siri App Intents.** "Tell Zimmer to …" without opening the app; works in CarPlay without the
  entitlement. A phone-app change.
- **A nudge on the Lock Screen.** A Live Activity for a call handed to a locked phone, with no sound.
  A new surface, so it needs a product decision first.
- **Crash reports.** The app ships no crash reporter; a crash in the car is visible only in
  TestFlight's crash feedback in App Store Connect. MetricKit (`MXCrashDiagnostic`) posted to Zimmer,
  or the Sentry SDK against GlitchTip, would bring them where an agent can read them.
- **The prompt.** When the client surface is `carplay`, Live Mode could open a resumed conversation
  with what needs the driver. That belongs to the `live-mode` root in `tadasant/tadasant-internal`.
