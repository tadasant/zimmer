# Zimmer in the car

The design for Zimmer's CarPlay app: what a driver can do with Zimmer, and why it is so little.
This is the engineering design doc for `App/Zimmer/CarPlay/` and `Sources/ZimmerKit/Driving/`; the
user-facing prose is [docs: The iOS app → CarPlay](https://docs.zimmer.tadasant.com/extend/ios-app/#carplay).

## The moment it is for

Someone is driving. Their hands are on the wheel and their eyes are on the road. What they want
from Zimmer is a conversation: what needs me, deal with this, start that. Zimmer already has the
thing that does all of it by voice, Live Mode, the OpenAI Realtime call that delegates to Zimmer's
MCP surface. So the car is Live Mode and nothing else.

## What Apple allows

Zimmer's CarPlay scene is a **voice-based conversational app**, the category Apple added in iOS
26.4 (`com.apple.developer.carplay-voice-based-conversation`). Apple's CarPlay App Programming
Guide (the 2026-10-13 edition) fixes what such an app can be:

| Rule | What it means here |
| --- | --- |
| Templates: action sheet, alert, grid, list, tab bar, information, voice control (26.4+) | Zimmer uses two: a grid (the Talk button) and the voice control template (the call) |
| "Primary modality of voice upon launch" | The one button is the voice conversation; the car stays silent until the driver taps it (see Decisions) |
| "Only hold an audio session open when voice features are actively being used" | The audio session is held only while a call runs, never idle |
| Recording "only in conjunction with the voice control template" | The microphone is open only while the voice control template is on screen: the call |
| "Don't show text or imagery in response to queries" | Answers are spoken; the call screen shows a state word, never a transcript |
| Voice control template: up to 2 action buttons, leading and trailing bar buttons (26.4+) | Mute and End. A trailing bar button as a status line did not render in the Simulator's CarPlay window, so there is none |
| Voice control template: up to 5 states (`init(voiceControlStates:)`) | Exactly five, one per call state (`LiveCallScreen`) |
| Notifications: communication, EV charging, parking, public safety and driving task apps only | **This category cannot show notifications in CarPlay**, and Zimmer does not try to be proactive in the car |

## Decisions

**Radically simple: open, talk, mute, end.** After the first CarPlay builds crashed in a car
(#1410), Tadas cut the app to the flow a driver actually uses: *"open the app, start talking to
zimmer, mute, end conversation, maybe show some details while talking but keep em minimal, no
multi-page nav."* The car has two screens: one button, and the call. Gone, deliberately: the tab
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
listening or working. The call has three short synthesized cues, which are tones, not a voice
(`LiveCue`): two soft rising notes when the call is up, a quiet low tick about once a second from
the end of speech until Zimmer's voice starts, and the notes falling when a call drops. Rising is
*on*, falling is *off*, and the tick shares neither pitch nor shape with the notes. The tick waits
a third of a second, so an answer that starts sooner gets none, stops the instant the reply's audio
starts, and gives up after 45 seconds with no answer. The cues play through the call's voice-processing engine, so the echo canceller has them as
reference, and while one sounds the microphone is sent as silence (`LiveCueGate`), so turn
detection never takes a cue for speech.

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
  call -- cannot connect, or drops --> retry["button: Live Mode unavailable, retrying…\n(2 s, 5 s, 15 s, silently)"]
  retry -- a retry connects --> call
  retry -- retries spent --> tap["button: Live Mode unavailable. Tap to retry"]
  tap -- tap --> call
```

| Screen | Template | Why this template |
| --- | --- | --- |
| Zimmer | Grid, one button | A grid's buttons are the largest targets CarPlay draws |
| The call | Voice control template, presented | The only screen allowed while recording |

Nothing is pushed. The call screen is the only modal. It is built once per call, presented when the
call starts and dismissed when it ends, through `CarPlayNavigator`, one change at a time. It is never
rebuilt.

### The call screen

- **The call's state**, as the picture and the title: Connecting…, Listening, Speaking, Working on
  it… (thinking included), or **Muted** while the microphone is off. Five states, because CarPlay
  keeps the first five a voice control template is given (`LiveCallScreen`). A state change, Mute
  included, is one `activateVoiceControlState`; the template is never rebuilt.
- **Mute** and **End**, the two action buttons.

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
| Tab bar, lists, cards, alerts, action sheet, a rebuilt call screen: many templates and transitions | Two templates; the call screen only goes up and down | `CarPlayTests.testTheCarIsOneButtonAndOneCallScreen` |

## The CarPlay drill

`App/ZimmerUITests/CarPlayDrillUITests.swift`, run by `ios/bin/ui-test --carplay` in CI's
`ios_carplay` job on every iOS pull request (and the `carplay` shard after merge). The script builds
the app signed ad hoc with the CarPlay entitlement — the Simulator's CarPlay window lists no app
without one — and opens that window from the Simulator's I/O menu through System Events. XCUITest
then drives the real templates, which the system's `CarPlayTemplateUIHost` draws:

- the car opens on one button and nothing else;
- Talk to Zimmer with a call that cannot connect (the fixture's Realtime secret points at
  `realtime.invalid`): it fails, retries, gives up on the button, leaves no call screen, and a tap
  tries again.

It does not press Mute or End. XCUITest finds the voice control template's two action buttons
(labelled by their symbols, "microphone off" and "hang up") but computes no hit point for them,
and neither an element tap nor a coordinate tap reaches them. The five states they switch between
are `LiveCallScreenTests`'; pressing them is confirmed only by driving.

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
| Record only with the voice control template | The microphone is opened only by `LiveCall`, whose screen in the car is the voice control template |
| No text or imagery in answer to queries | Answers are spoken by the model; the call screen shows a state word |
| Depth of 3 | One root; nothing is pushed; the call screen is modal |
| Few, large targets | One grid button; two call buttons |
| Destructive actions confirmed | The car has no destructive button; Live Mode confirms a merge or an archive out loud |
| Nothing a driver cannot act on | A call that will not connect says so on the button and retries |

## What is proven, and what is not

- `LiveActivity`, `LiveCallScreen`, `LiveRetry`, `CarPlayNavigator`, `LiveReferencedSessions` and
  the conductor are in ZimmerKit and tested on Linux and macOS on every iOS pull request.
- `CarPlayTests` also reads the scene's source: no interface-controller call outside
  `CarPlayInterface.swift` or without a completion, no system speech anywhere in the app, no direct
  session action, no template but the grid and the call screen, every sink on the call deferred,
  and the call screen built from `LiveCallScreen.identifiers`.
- The CarPlay drill drives the real CarPlay templates in the Simulator's CarPlay window on every iOS
  pull request.
- **Not driven anywhere but a car:** the audio route moving to the car (the Simulator has none), and
  a call that connects (CI has no microphone and no OpenAI key), so Listening, Speaking and Working
  are confirmed only by driving. Nor is a relaunch: in the Simulator a
  relaunched Zimmer never gets its CarPlay scene back (the window stays blank), and whether a car
  behaves the same after Zimmer crashes or is killed is untested.

## Follow-ups

- **iOS 27 overlay.** The voice control template as an overlay. Needs Xcode 27 in CI.
- **Siri App Intents.** "Tell Zimmer to …" without opening the app; works in CarPlay without the
  entitlement. A phone-app change.
- **Crash reports.** The app ships no crash reporter; a crash in the car is visible only in
  TestFlight's crash feedback in App Store Connect. MetricKit (`MXCrashDiagnostic`) posted to Zimmer,
  or the Sentry SDK against GlitchTip, would bring them where an agent can read them.
- **The prompt.** When the client surface is `carplay`, Live Mode could open a resumed conversation
  with what needs the driver. That belongs to the `live-mode` root in `tadasant/tadasant-internal`.
