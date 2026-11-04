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
| Templates: action sheet, alert, grid, list, tab bar, information, voice control (26.4+) | Zimmer uses three: a grid (the Talk button), the voice control template (the call) and a list (the voice settings, behind the call screen's gear) |
| "Primary modality of voice upon launch" | The one button is the voice conversation; the car stays silent until the driver taps it (see Decisions) |
| "Only hold an audio session open when voice features are actively being used" | The audio session is held only while a call runs, never idle |
| Recording "only in conjunction with the voice control template" | The microphone is open only while the voice control template is on screen: the call. The gear ends the call before its screen comes down, so the panel never records |
| "Don't show text or imagery in response to queries" | Answers are spoken; the call screen shows a state word, never a transcript |
| Voice control template: up to 2 action buttons, leading and trailing bar buttons (26.4+) | Mute and End; the gear to the voice settings is the leading bar button. A trailing bar button as a status line did not render in the Simulator's CarPlay window, so there is none |
| Voice control template: up to 5 states (`init(voiceControlStates:)`) | Exactly five, one per call state (`LiveCallScreen`) |
| Notifications: communication, EV charging, parking, public safety and driving task apps only | **This category cannot show notifications in CarPlay**, and Zimmer does not try to be proactive in the car |

## Decisions

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
- A gated Listening drops every line once a call moves from the car to the phone, which is what
  "it can't hear me" looked like: speech transcribed, then `respond=false`. The car itself is always
  Always, so the row says it is the phone's.
- Under Semantic turn detection `RealtimeSession` sends eagerness and nothing else, so threshold,
  pause and prefix padding go nowhere. A threshold of 0.92 was inert.

So the panel is built from what the call acts on (`CarVoiceSettings`). **It shows only what the
current turn detection sends to OpenAI:** under Semantic there is no threshold or pause row, and
Turn detection says they need Silence; under Silence there is no eagerness row. Prefix padding has
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
the panel is up, and that call is minted from the row, so a model or anything else OpenAI fixes for
a call's life would apply too. Closing waits for the driver's last write, showing *Saving…*, so the
call cannot read the row ahead of it. A write that failed keeps the panel up to say *Not saved*, and
the next Back closes it on what the row holds. With CarPlay's Back there is no panel left to say it
on, so the call comes back on the old value and the log records `settings_write_lost`. A call that starts on the phone meanwhile is the conversation: the panel goes, and the
call the gear ended stays ended. So does one whose car disconnects with the panel up.

**Radically simple: open, talk, mute, end.** After the first CarPlay builds crashed in a car
(#1410), Tadas cut the app to the flow a driver actually uses: *"open the app, start talking to
zimmer, mute, end conversation, maybe show some details while talking but keep em minimal, no
multi-page nav."* The car has two screens: one button, and the call, and the voice settings behind
it are the one exception (*Break glass*). Gone, deliberately: the tab
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

**Every call leaves a trace.** The car cannot be tested from CI, so each call logs every step to
Zimmer's shipped logs (`LiveTelemetry` → `POST /api/v1/live/telemetry` → `ios.live` records in
VictoriaLogs). The Live setting *Call telemetry* turns it down or off without a build. See
[docs: observability](https://docs.zimmer.tadasant.com/operate/observability/#the-ios-apps-call-log).

**One thread.** Everything the driver says goes to the one Live Mode conversation: Talk to Zimmer
resumes the open conversation with voice on, or starts one. Live Mode acts on sessions itself, with
its own guardrails (it confirms before a merge or anything that cannot be undone). The car has no
way to act on a session directly, and a source guard keeps it that way.

**Silent until asked.** Opening the app says nothing. The call starts only when the driver taps the
button. The category's "primary modality of voice upon launch" is read as *the default action is
voice*, not *the app speaks first*.

**Live Mode unavailable is shown, never spoken.** When the call cannot connect, or drops, the button
says *Live Mode unavailable, retrying…* and the car tries again after 2, 5 and 15 seconds, silently
(`LiveRetry`). Once those are spent it says *Live Mode unavailable. Tap to retry*; a tap is a fresh
budget, a call that comes up earns it back, and ending the call stops the retries.

## Screens

```mermaid
flowchart TD
  connect([Car connects, silently]) --> home["Zimmer (grid, root)\n[Talk to Zimmer]"]
  home -- Talk to Zimmer --> call["Live Mode call (voice control template, modal)\nstate picture + title: Connecting… / Listening / Speaking / Working on it… / Muted\n[Mute] [End]"]
  call -- End --> home
  call -- "gear: ends the call" --> panel["Voice settings (list, pushed)\n[Back to the call] [Reset to defaults]\n[Reply length cap] [Turn detection] …"]
  panel -- "Back to the call, or CarPlay's Back: calls again" --> call
  panel -- a row --> choices["The row's choices (the same list, redrawn)"]
  choices -- a choice, or Back to settings --> panel
  call -- cannot connect, or drops --> retry["button: Live Mode unavailable, retrying…\n(2 s, 5 s, 15 s, silently)"]
  retry -- a retry connects --> call
  retry -- retries spent --> tap["button: Live Mode unavailable. Tap to retry"]
  tap -- tap --> call
```

| Screen | Template | Why this template |
| --- | --- | --- |
| Zimmer | Grid, one button | A grid's buttons are the largest targets CarPlay draws |
| The call | Voice control template, presented | The only screen allowed while recording |
| Voice settings | List, pushed | Text and a value, large rows, and CarPlay's own limits on them. No slider exists, so every value is a few discrete choices |

The call screen is the only modal. It is built once per call, presented when the call starts and
dismissed when it ends, through `CarPlayNavigator`, one change at a time. It is never rebuilt. The
voice settings are the only thing pushed, also through the navigator. A row's choices are the same
list with its sections replaced, so opening one is no template change, and nothing is deeper than
that one push.

Reachable only from the call screen, in any of its states: the home screen stays one button, so
while the Talk button is retrying there is no gear. The settings are all on the phone's Live settings
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
an error that ends the call shows on the Talk button instead.

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
| The Live call's `AVAudioEngine` restarted on the route-change notification's thread while a hang-up stopped it on the main one; the car connecting or disconnecting is a route change | `LiveAudioEngine` is main-actor only; its observers run on the main queue; a media-services reset ends the call | Review; no test can drive AVAudioEngine on Linux, and the Simulator has no car audio route |
| A microphone tap installed with a format read before the route settled | The tap takes the node's own format (`format: nil`) and reads each buffer's rate | Review |
| The system voice and its `.playback` audio session, switched on and off around a running call's `.playAndRecord` one | No system voice | A source guard |
| Tab bar, lists, cards, alerts, action sheet, a rebuilt call screen: many templates and transitions | Three templates; the call screen only goes up and down; one pushed list, whose pages are redraws | `CarPlayTests.testTheCarIsOneButtonOneCallScreenAndOnePanel` |
| A list pushed under a modal, or a pop with nothing pushed after the driver's own Back | The navigator takes the modal down first and pops only what it pushed, asking CarPlay how much is pushed rather than comparing templates | `CarPlayTests` (the strict fake models the stack); the drill |
| The microphone open with no voice control template on screen | The gear hangs up before anything else | `CarPlayTests.testTheGearEndsTheCallBeforeThePanelGoesUp` |

## The CarPlay drill

`App/ZimmerUITests/CarPlayDrillUITests.swift`, run by `ios/bin/ui-test --carplay` in CI's
`ios_carplay` job on every iOS pull request (and the `carplay` shard after merge). The script builds
the app signed ad hoc with the CarPlay entitlement — the Simulator's CarPlay window lists no app
without one — and opens that window from the Simulator's I/O menu through System Events. XCUITest
then drives the real templates, which the system's `CarPlayTemplateUIHost` draws:

- the car opens on one button and nothing else;
- the gear on the call screen, on a call the fixture holds on Connecting… (`-ZimmerFixtureVoiceTurnedUp`,
  with the settings a voice call left): the panel opens with the call screen gone, shows the cap of
  180 and no threshold row, Silence brings the threshold back with its 0.92, Reset to defaults
  clears the cap, and Back to the call calls again;
- Talk to Zimmer with a call that cannot connect (the fixture's Realtime secret points at
  `realtime.invalid`): it fails, retries, gives up on the button, leaves no call screen, and a tap
  tries again.

It does not press Mute or End. XCUITest finds the voice control template's two action buttons
(labelled by their symbols, "microphone off" and "hang up") but computes no hit point for them,
and neither an element tap nor a coordinate tap reaches them. The five states they switch between
are `LiveCallScreenTests`'; pressing them is confirmed only by driving. The gear has the same
{-1, -1} hit point, so `ios/bin/ui-test` tries a click from the Mac at the gear's place in the
CarPlay window, and in case that does not land the fixture presses the gear's action itself after 15
seconds. The run's log says which it was (`carplay drill: the gear was …`).

It is one ordered test in one Zimmer process. In the Simulator, CarPlay connects Zimmer's scene to
the first process and never to one XCUITest relaunches: the window stays blank and `didConnect`
never fires, even after going home and tapping the icon again. Whether a head unit does the same
when iOS relaunches Zimmer (after a crash, say) is unknown; see *What is proven*. Zimmer must be
running after every step, and any crash report fails the job.

## Driver-distraction checklist

| Guideline | How the app follows it |
| --- | --- |
| Voice is the primary modality at launch | The one button is the voice conversation; nothing is heard until it is tapped |
| Audio session only while voice is in use | `LiveCall` holds the only audio session, and only for the call |
| Record only with the voice control template | The microphone is opened only by `LiveCall`, whose screen in the car is the voice control template. A present CarPlay refuses does not stop the call, so until the next state change presents again the microphone can be open with no screen; the comeback takes that path like any call |
| No text or imagery in answer to queries | Answers are spoken by the model; the call screen shows a state word |
| Depth of 3 | One root; one pushed list; the call screen is modal |
| Few, large targets | One grid button; two call buttons and the gear; list rows, each a name and a value, with at most five choices |
| Destructive actions confirmed | The car has no destructive button; Live Mode confirms a merge or an archive out loud. Reset to defaults does not ask: see *Break glass* |
| Nothing a driver cannot act on | A call that will not connect says so on the button and retries |

## What is proven, and what is not

- `LiveActivity`, `LiveCallScreen`, `LiveRetry`, `CarPlayNavigator`, `LiveReferencedSessions` and
  the conductor are in ZimmerKit and tested on Linux and macOS on every iOS pull request.
- `CarPlayTests` also reads the scene's source: no interface-controller call outside
  `CarPlayInterface.swift` or without a completion, no system speech anywhere in the app, no direct
  session action, no template but the grid, the call screen and the one list, nothing pushed but
  the panel, the call ended before the panel goes up, every sink on the call deferred, and the call
  screen built from `LiveCallScreen.identifiers`.
- `CarVoiceSettingsTests` hold the panel's reads, writes and reset against the fake's row, and when
  a comeback exists and ends (`CarCallComeback`); a Rails
  test holds that a cap and a Listening set by voice are read and cleared over the same API, and that
  the next minted call has no cap.
- The CarPlay drill drives the real CarPlay templates in the Simulator's CarPlay window on every iOS
  pull request.
- **Not driven anywhere but a car:** the audio route moving to the car (the Simulator has none), and
  a call that connects (CI has no microphone and no OpenAI key), so Listening, Speaking and Working
  are confirmed only by driving. Nor is a relaunch: in the Simulator a
  relaunched Zimmer never gets its CarPlay scene back (the window stays blank), and whether a car
  behaves the same after Zimmer crashes or is killed is untested. Nor is the call coming back from
  the panel to a voice: CI has no call that connects, so the drill proves it is called again and the
  rest is driving.

## Follow-ups

- **iOS 27 overlay.** The voice control template as an overlay. Needs Xcode 27 in CI.
- **Siri App Intents.** "Tell Zimmer to …" without opening the app; works in CarPlay without the
  entitlement. A phone-app change.
- **Crash reports.** The app ships no crash reporter; a crash in the car is visible only in
  TestFlight's crash feedback in App Store Connect. MetricKit (`MXCrashDiagnostic`) posted to Zimmer,
  or the Sentry SDK against GlitchTip, would bring them where an agent can read them.
- **The prompt.** When the client surface is `carplay`, Live Mode could open a resumed conversation
  with what needs the driver. That belongs to the `live-mode` root in `tadasant/tadasant-internal`.
