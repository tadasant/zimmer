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
   above 430 Hz, clear of the low band where a car's noise is loudest.
2. **Easy on the ears.** A driver hears the thinking pulse through every slow answer, for hours.
   A cue that is loud *and* bright, or that snaps on, turns from information into irritation.
   Tadas asked for the CarPlay sounds to be "softer and less shrill", and then, after the first
   pass, said the thinking and processing sounds were still shrill and high-pitched.

Softness comes from the shape and the timbre, not from the level. Turning a cue down would undo
#1485. Instead every cue has a rounded 30 ms attack, no fundamental above G5 (784 Hz), little
energy above 1.5 kHz, and no odd harmonics. The two loops, the sounds heard most, are pure sine
pulses around C5 (440–523 Hz), with nothing above their own pitch.

## The numbers

Each one is held by a test in `Tests/ZimmerKitTests/LiveDiagnosticsTests.swift`, unless marked
*(guideline)*.

| Property | Target | Why | Test |
| --- | --- | --- | --- |
| Peak | 0.25 – 0.5 of full scale (−12 to −6 dBFS) | Near speech level, never an alarm | `testEveryCueIsLoudEnoughForACarAndStillBrief` |
| Loudness | RMS ≥ −23 dBFS over the whole cue | Loud for its length, not one spike | same |
| Length | Under 0.45 s; the thinking pulse under 100 ms | Information, not music | same, `testTheCuesAreShortAndTellOnFromOff` |
| Loudness held | Each cue's RMS within 1 dB of its road level (the #1486 set, below) | Softer is shape and pitch, never level; quieter was "too subtle" on the road | `testSofterCuesKeepTheirLoudness` |
| Loop duty | Under 10% of the period | The microphone is closed while a cue sounds | `testEveryCueIsLoudEnoughForACarAndStillBrief` |
| Fundamental, *on / heard / busy* cues | 430 – 800 Hz (about A4 to G5), each note checked on its own | Above the band where a car's noise is loudest, below shrill | `testTheCuesSitAboveTheRoadNoise`, `testTheCuesAreSoftEdgedAndNotShrill` |
| The loops (*thinking*, *working*) | Every note 400 – 660 Hz; a pure sine (energy above 1.5 kHz under −35 dB); half level no sooner than 15 ms in; thinking slower than once a second | The sounds heard most: a soft pulse, not a tick | `testTheLoopsAreMellowPulses` |
| Fundamental, *failed / ended* | Below 0.7× the happy cues (about 290–350 Hz) | Low means *not good* | `testWorkingCannotPassForThinkingNorFailedForAnythingHappy` |
| Energy above 1.5 kHz | Below −23 dB of the cue's total, through a 4th-order high-pass at 1.5 kHz | This is where a tone gets piercing. For these cues most of what passes is the fundamental's skirt, so it is a second ceiling on pitch as much as a harmonics budget: a pure A5 scores −19.8 dB, a pure C5 −37 dB | `testTheCuesAreSoftEdgedAndNotShrill` |
| Attack | In the first 5 ms, under 15% of the peak; a note reaches full level in about 30 ms | A snap on is what makes a tone sound harsh | same |
| Release | Fades to zero by the last sample, over about 30 ms | No click at the end | same |
| Harmonics | Fundamental plus a trace of its octave (0.06) on high notes; up to 0.45 octave on low notes; none at all on the loops; **no odd harmonics** | The octave is warm and carries a low note into the 600–700 Hz band; a twelfth (3rd harmonic) buzzes | *(guideline)* |
| Shape | Rising = *on*, falling = *off*, level = *on its way*; no two cues alike | Read without looking | `testTheCuesAreShortAndTellOnFromOff`, `testPressedIsItsOwnSoundAndNotConnected` |
| Format | Mono Float32, 24 kHz (`RealtimeAudio.sampleRate`), synthesized in code | Same format as the reply, so it plays through the same voice-processing engine and the echo canceller has it as reference | *(guideline)* |
| Loop seam | A loop is the sound followed by silence to the end of its period (`LiveCue.loop()`), so it repeats with no seam to hear | Sample-exact period | `testTheCuesAreShortAndTellOnFromOff` |

## The set

| Cue | Sound | Peak | RMS | Plays |
| --- | --- | --- | --- | --- |
| pressed | F5, F5 (698 Hz), quick and level | 0.27 | −19.4 dBFS | The Talk tap, before any request |
| connected | D5 → G5 (587 → 784 Hz), rising a fourth | 0.34 | −17.8 | The call is up |
| heard | D5, one short note | 0.33 | −17.7 | 0.35 s after the driver stops |
| thinking | a C5 (523 Hz) sine pulse, 90 ms, every 1.2 s | 0.35 | −16.5 | The model is working, no tool running |
| working | A4, C5 (440, 523 Hz), a pair of pulses every 2.5 s | 0.35 | −16.5 | A tool is running |
| failed | F4 → D4, falling a minor third, with a strong octave | 0.36 | −18.7 | Something did not happen |
| ended | E4, one low note with its octave | 0.29 | −20.4 | The driver hung up |
| disconnected | G5 → D5, the connected notes falling | 0.35 | −17.7 | The call dropped |

Against the two sets before it, #1485 (louder, snapping on) → #1486 (rounded, nothing above A5) →
this set, measured from the synthesized samples:

| Cue | Peak | RMS dBFS | Energy above 1.5 kHz (dB) | Rise to half peak (ms) | Length (ms) |
| --- | --- | --- | --- | --- | --- |
| pressed | 0.40 → 0.29 → 0.27 | −19.1 → −19.6 → −19.4 | −14.5 → −20.6 → −26.0 | 2.5 → 9.2 → 13.2 | 160 → 170 → 185 |
| connected | 0.44 → 0.36 → 0.34 | −18.6 → −18.3 → −17.8 | −14.2 → −19.4 → −24.3 | 2.7 → 10.2 → 14.8 | 270 → 290 → 310 |
| heard | 0.38 → 0.33 → 0.33 | −19.5 → −18.5 → −17.7 | −20.3 → −25.0 → −31.3 | 2.7 → 9.4 → 13.2 | 120 → 130 → 140 |
| thinking | 0.30 → 0.32 → 0.35 | −17.7 → −17.2 → −16.5 | −14.5 → −19.8 → −37.1 | 17.9 → 19.0 → 23.3 | 70 → 75 → 90 |
| working | 0.32 → 0.32 → 0.35 | −17.2 → −17.2 → −16.5 | −25.5 → −25.5 → −39.1 | 25.4 → 25.4 → 30.1 | 200 → 200 → 240 |
| failed | 0.42 → 0.37 → 0.36 | −19.2 → −19.3 → −18.7 | −28.0 → −37.9 → −37.9 | 2.5 → 10.8 → 14.8 | 380 → 400 → 400 |
| ended | 0.31 → 0.31 → 0.29 | −21.6 → −20.6 → −20.4 | −27.1 → −36.9 → −36.9 | 2.5 → 9.5 → 14.5 | 220 → 230 → 230 |
| disconnected | 0.40 → 0.37 → 0.35 | −19.4 → −18.1 → −17.7 | −15.8 → −21.1 → −26.2 | 2.8 → 10.0 → 15.0 | 290 → 310 → 330 |

Loudness held within a decibel of #1486's set, and is 1–2 dB above #1485's on most cues. The thinking and working loops are 0.7 dB
louder by RMS on purpose: they moved down (thinking a sixth, A5 to C5; working a fifth, E5–G5 to
A4–C5), where the ear is a little less sensitive and road noise a little stronger, and the extra
level keeps them as easy to hear as before. The edge came off instead: the loops are pure sines
with 13–17 dB less energy above 1.5 kHz, the high one-shots have 5–6 dB less, and every note
takes about half again as long to swell in. Thinking pulses every 1.2 s instead of every second,
so a long answer is less of a metronome.

## Changing a cue, or adding one

Cues are synthesized, not bundled files: there is nothing to sign off as an asset, no file to
keep in step between the phone and the car, and no resampling.

1. Change `LiveCue.samples(sampleRate:)`. Build notes from `LiveCue.note` (rounded attack and
   release, fundamental plus octave) or `LiveCue.tap` (a Hann-windowed pure sine pulse, for the loops).
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
   speakers: *pressed* and *connected*, then *heard* and the *thinking* pulse after you speak. Ask
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
- [ ] After you stop talking, *heard* is clear, then the *thinking* pulse. You can hear the pulse
      at speed without straining, and after two minutes of it you are not irritated by it.
- [ ] A request that runs a tool gives the *working* pair. It never passes for the thinking pulse.
- [ ] *failed* (ask for something that cannot be done, or drop the network) reads as *not good*
      and carries over the engine.
- [ ] Hang up: *ended*. Drop the call (airplane mode): *disconnected*, falling.
- [ ] No cue sounds sharp, piercing or tinny at your usual volume, and none is lost under road
      noise. Note any one that is.
- [ ] No cue starts a turn on its own: the call does not answer a cue as if you had spoken.
- [ ] Music pauses once at the tap and resumes after a press that leads nowhere.

## After release: what to watch

Only the samples and the thinking loop's period (1.0 s to 1.2 s; the gate reads it from
`LiveCue.period`) changed. The gate, the director and the audio engine paths did not. In particular the change does not touch `LiveAudioEngine.playAlone`, where #1485's
CarPlay drill once saw a CoreAudio RPC timeout on its first audio setup; the buffers it schedules
are only slightly longer (pressed 185 ms against #1485's 160 ms). Regressions therefore come from how the
cues sound, not from crashes. In the call log (VictoriaLogs, `scope.name:="ios.live"`) watch:

- **A cue taken for speech.** After a `cue.played`, a `call.state` move into listening or speaking
  within about half a second with nobody talking means the cue reached turn detection. The low
  notes carry energy at 600–700 Hz, and the loops sit at 440–523 Hz, both inside the speech
  band. The echo canceller and the
  120 ms gate tail should still cover them.
- **A driver who could not hear the call.** The loops are lower than before, so this is the risk
  this set takes. More hang-ups during thinking, and more presses
  repeated within a few seconds of `carplay.talk_tapped`, suggest a cue is lost on the road.
- **Unchanged health signals.** `call.acknowledged` (`since_press_ms`), `call.failed`,
  `call.gave_up`, `audio.engine_failed` and `call.ended` with `reason=abandoned` should be at their #1485
  rates. A change in any of them is not from the sound and needs another look.

The best signal is still the driver. If a cue is too quiet or too sharp on a drive, say which one,
and where.
