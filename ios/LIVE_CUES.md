# Live call cues: how they should sound

The tones a Live call plays besides Zimmer's voice (`LiveCue` in
`Sources/ZimmerKit/Live/LiveCues.swift`) are heard on the phone and, mostly, in the car. This page
is the brief for anyone changing one: what a cue has to do, the numbers it has to hit, how to
change one, and how to check it, on Linux, in the Simulator and in a real car.
What each cue means and when it plays is in [CARPLAY_DESIGN.md](CARPLAY_DESIGN.md) (*Hear the call,
don't watch it*) and in the docs site's iOS page.

## Two requirements that pull against each other

1. **Heard over a car.** On the 2026-11-04 drive the thinking and working sounds were "too subtle"
   (#1485). Road and engine noise covers quiet tones and anything low. So the cues sit near the
   level of Zimmer's speech, and everything that says *on*, *heard* or *busy* has its fundamental
   above 600 Hz.
2. **Easy on the ears.** A driver hears the thinking tap once a second through every slow answer,
   for hours. A cue that is loud *and* bright, or that snaps on, turns from information into
   irritation. Tadas asked for the CarPlay sounds to be "softer and less shrill".

Softness comes from the shape and the timbre, not from the level. Turning a cue down would undo
#1485. Instead every cue has a rounded attack, no fundamental above A5, little energy above
1.5 kHz, and no odd harmonics.

## The numbers

Each one is held by a test in `Tests/ZimmerKitTests/LiveDiagnosticsTests.swift`, unless marked
*(guideline)*.

| Property | Target | Why | Test |
| --- | --- | --- | --- |
| Peak | 0.25 – 0.5 of full scale (−12 to −6 dBFS) | Near speech level, never an alarm | `testEveryCueIsLoudEnoughForACarAndStillBrief` |
| Loudness | RMS ≥ −23 dBFS over the whole cue | Loud for its length, not one spike | same |
| Length | Under 0.45 s; the thinking tap under 80 ms | Information, not music | same, `testTheCuesAreShortAndTellOnFromOff` |
| Loop duty | Under 10% of the period | The microphone is closed while a cue sounds | `testEveryCueIsLoudEnoughForACarAndStillBrief` |
| Fundamental, *on / heard / busy* cues | 600 – 900 Hz (about E5 to A5), each note checked on its own | Above the car's noise, below shrill | `testTheCuesSitAboveTheRoadNoise`, `testTheCuesAreSoftEdgedAndNotShrill` |
| Fundamental, *failed / ended* | Below 0.7× the happy cues (about 290–350 Hz) | Low means *not good* | `testWorkingCannotPassForThinkingNorFailedForAnythingHappy` |
| Energy above 1.5 kHz | Below −18 dB of the cue's total, through a 4th-order high-pass at 1.5 kHz | This is where a tone gets piercing. For these cues most of what passes is the fundamental's skirt, so it is a second ceiling on pitch as much as a harmonics budget: a pure A5 scores −19.8 dB | `testTheCuesAreSoftEdgedAndNotShrill` |
| Attack | In the first 5 ms, under 30% of the peak; a note reaches full level in about 20 ms | A snap on is what makes a tone sound harsh | same |
| Release | Fades to zero by the last sample, over about 25 ms | No click at the end | same |
| Harmonics | Fundamental plus a trace of its octave (0.12) on high notes; up to 0.45 octave on low notes; **no odd harmonics** | The octave is warm and carries a low note into the 600–700 Hz band; a twelfth (3rd harmonic) buzzes | *(guideline)* |
| Shape | Rising = *on*, falling = *off*, level = *on its way*; no two cues alike | Read without looking | `testTheCuesAreShortAndTellOnFromOff`, `testPressedIsItsOwnSoundAndNotConnected` |
| Format | Mono Float32, 24 kHz (`RealtimeAudio.sampleRate`), synthesized in code | Same format as the reply, so it plays through the same voice-processing engine and the echo canceller has it as reference | *(guideline)* |
| Loop seam | A loop is the sound followed by silence to the end of its period (`LiveCue.loop()`), so it repeats with no seam to hear | Sample-exact period | `testTheCuesAreShortAndTellOnFromOff` |

## The set

| Cue | Sound | Peak | RMS | Plays |
| --- | --- | --- | --- | --- |
| pressed | G5, G5 (784 Hz), quick and level | 0.29 | −19.6 dBFS | The Talk tap, before any request |
| connected | E5 → A5 (659 → 880 Hz), rising a fourth | 0.36 | −18.3 | The call is up |
| heard | E5, one short note | 0.33 | −18.5 | 0.35 s after the driver stops |
| thinking | an A5 (880 Hz) tap, 75 ms, once a second | 0.32 | −17.2 | The model is working, no tool running |
| working | E5, G5, a pair of taps every 2.5 s | 0.32 | −17.2 | A tool is running |
| failed | F4 → D4, falling a minor third, with a strong octave | 0.37 | −19.3 | Something did not happen |
| ended | E4, one low note with its octave | 0.31 | −20.6 | The driver hung up |
| disconnected | A5 → E5, the connected notes falling | 0.37 | −18.1 | The call dropped |

Against the set it replaced (#1485), measured from the synthesized samples:

| Cue | Peak | RMS dBFS | Energy above 1.5 kHz (dB) | Rise to half peak (ms) | Length (ms) |
| --- | --- | --- | --- | --- | --- |
| pressed | 0.40 → 0.29 | −19.1 → −19.6 | −14.5 → −20.6 | 2.5 → 9.2 | 160 → 170 |
| connected | 0.44 → 0.36 | −18.6 → −18.3 | −14.2 → −19.4 | 2.7 → 10.2 | 270 → 290 |
| heard | 0.38 → 0.33 | −19.5 → −18.5 | −20.3 → −25.0 | 2.7 → 9.4 | 120 → 130 |
| thinking | 0.30 → 0.32 | −17.7 → −17.2 | −14.5 → −19.8 | 17.9 → 19.0 | 70 → 75 |
| working | unchanged | −17.2 | −25.5 | 25.4 | 200 |
| failed | 0.42 → 0.37 | −19.2 → −19.3 | −28.0 → −37.9 | 2.5 → 10.8 | 380 → 400 |
| ended | 0.31 → 0.31 | −21.6 → −20.6 | −27.1 → −36.9 | 2.5 → 9.5 | 220 → 230 |
| disconnected | 0.40 → 0.37 | −19.4 → −18.1 | −15.8 → −21.1 | 2.8 → 10.0 | 290 → 310 |

Loudness held within about a decibel, and most cues are slightly louder by RMS. The edge came off:
four times slower to reach half level, 5 to 10 dB less energy above 1.5 kHz, and the buzz is gone
from the low notes. Peaks dropped a little only because a rounded attack and an exponential fade
spread the same energy more evenly.

## Changing a cue, or adding one

Cues are synthesized, not bundled files: there is nothing to sign off as an asset, no file to
keep in step between the phone and the car, and no resampling.

1. Change `LiveCue.samples(sampleRate:)`. Build notes from `LiveCue.note` (rounded attack and
   release, fundamental plus octave) or `LiveCue.tap` (a Hann-windowed sine burst, for the loops).
   Do not hand-roll an envelope: the two helpers are what keep the attack and release rules true.
2. A new cue is a new `LiveCue` case. Add it to the event-to-cue table on `LiveCueDirector`, to the
   table above, to `CARPLAY_DESIGN.md` and to the docs site's iOS page.
3. Run the cue tests (below). If a new cue fails `testTheCuesAreSoftEdgedAndNotShrill`, change the
   sound, not the test.
4. Listen. Dump the samples (`LiveCue.x.samples()` written out as 24 kHz mono Float32, or 16-bit
   PCM in a WAV) and play them back on a phone speaker and on headphones, then in a car (the
   checklist below). The levels in the tables are the synthesized samples; what the driver hears
   also goes through the voice-processing engine and the car's own processing.
5. Keep the web dock (`app/javascript/lib/live_cues.js`) in mind. It has its own, older set (the
   quieter levels, a 5 ms attack, connected reaching B5), and nothing forces it to follow.

## Testing

### Unit tests (Linux or a Mac)

```sh
ZIMMER_SWIFT_SHIM=$(ios/bin/install-swift-toolchain)/swift ios/bin/ci-swift   # Linux
ios/bin/ci-swift                                                                # Mac
# just the cues:
swift test --package-path ios --filter LiveDiagnosticsTests
```

CI runs both (`ios` on macOS, `ios_swift_linux` on Linux).

### Simulator

1. Run the app in the iOS Simulator, start a Live call on a session, and listen through the Mac's
   speakers: *pressed* and *connected*, then *heard* and the *thinking* tap after you speak. Ask
   for something that runs a tool to hear *working*. Hang up to hear *ended*.
2. CarPlay: open I/O → External Displays → CarPlay, tap Talk, and listen for *pressed* at the tap.
   The `ios_carplay` CI drill drives the same path against a fixture whose secret fails, so it
   sounds *pressed* and then the falling notes.

The Simulator proves timing and order. It cannot judge how a cue sounds in a car.

### In a real car

Do this before a cue change ships to the car. Use car audio over CarPlay (wired and wireless if
both are available), at highway speed or the loudest road you usually drive, with the music at
your usual level:

- [ ] *pressed* sounds within about half a second of tapping Talk, and does not sound like the call is up.
- [ ] *connected* is clearly heard over the road and is clearly *rising*.
- [ ] After you stop talking, *heard* is clear, then the *thinking* tap. You can hear the tap at
      speed without straining, and after two minutes of it you are not irritated by it.
- [ ] A request that runs a tool gives the *working* pair. It never passes for the tap.
- [ ] *failed* (ask for something that cannot be done, or drop the network) reads as *not good*
      and carries over the engine.
- [ ] Hang up: *ended*. Drop the call (airplane mode): *disconnected*, falling.
- [ ] No cue sounds sharp, piercing or tinny at your usual volume, and none is lost under road
      noise. Note any one that is.
- [ ] No cue starts a turn on its own: the call does not answer a cue as if you had spoken.
- [ ] Music pauses once at the tap and resumes after a press that leads nowhere.

## After release: what to watch

The cues changed only in their samples. Timing, the gate, the director and the audio engine paths
did not change. In particular the change does not touch `LiveAudioEngine.playAlone`, where #1485's
CarPlay drill once saw a CoreAudio RPC timeout on its first audio setup; the buffers it schedules
are only slightly longer (pressed 170 ms against 160 ms). Regressions therefore come from how the
cues sound, not from crashes. In the call log (VictoriaLogs, `scope.name:="ios.live"`) watch:

- **A cue taken for speech.** After a `cue.played`, a `call.state` move into listening or speaking
  within about half a second with nobody talking means the cue reached turn detection. The low
  notes now carry more energy at 600–700 Hz, inside the speech band. The echo canceller and the
  120 ms gate tail should still cover them.
- **A driver who could not hear the call.** More hang-ups during thinking, and more presses
  repeated within a few seconds of `carplay.talk_tapped`, suggest a cue is lost on the road.
- **Unchanged health signals.** `call.acknowledged` (`since_press_ms`), `call.failed`,
  `call.gave_up`, `audio.engine_failed` and `call.ended` with `reason=abandoned` should be at their #1485
  rates. A change in any of them is not from the sound and needs another look.

The best signal is still the driver. If a cue is too quiet or too sharp on a drive, say which one,
and where.
