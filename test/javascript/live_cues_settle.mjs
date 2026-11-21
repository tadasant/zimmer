// Drives the real LiveCueDirector and LiveCuePlayer from lib/live_cues.js through
// a call's end-of-turn signals, in the order live_voice_controller.js and
// gpt_live_call.js give them, on a fake clock and a fake AudioContext, and
// records what actually sounds: a cue whose source was stopped before its start
// time never made a sound. Run by live_cues_settle_test.rb; each scenario prints
// one JSON line.
import { readFileSync } from "node:fs"

const strip = (path) => readFileSync(path, "utf8").replace(/^import .*$/gm, "").replace(/^export /gm, "")

let now = 0
let timers = []
let nextTimer = 1
const fakeSetTimeout = (fn, ms = 0) => { const id = nextTimer++; timers.push({ id, at: now + ms, fn }); return id }
const fakeClearTimeout = (id) => { timers = timers.filter((timer) => timer.id !== id) }
const advance = (seconds) => {
  const until = now + seconds * 1000
  for (;;) {
    timers.sort((a, b) => a.at - b.at)
    const due = timers[0]
    if (!due || due.at > until) break
    timers.shift()
    now = due.at
    due.fn()
  }
  now = until
}

const sources = []
class FakeAudioContext {
  constructor() { this.state = "running"; this.outputLatency = 0 }
  get currentTime() { return now / 1000 }
  resume() { return Promise.resolve() }
  createBuffer(_channels, length, rate) { return { duration: length / rate, copyToChannel() {} } }
  createBufferSource() {
    const source = { connect() {}, start(at) { this.at = at }, stop() { if (this.stoppedAt === undefined) this.stoppedAt = now / 1000 } }
    sources.push(source)
    return source
  }
  get destination() { return {} }
}

const { LiveCueDirector, LiveCuePlayer, SETTLE } = new Function(
  "setTimeout", "clearTimeout", "AudioContext",
  `${strip(process.argv[2])}\nreturn { LiveCueDirector, LiveCuePlayer, SETTLE }`
)(fakeSetTimeout, fakeClearTimeout, FakeAudioContext)

function call() {
  now = 0
  timers = []
  sources.length = 0
  const director = new LiveCueDirector()
  let micClosings = 0
  const player = new LiveCuePlayer({ onMicGate: (closed) => { if (closed) micClosings += 1 }, onLoopTimeout: () => {} })
  player.unlock()
  const cueOf = (buffer) => [...player.buffers].find(([, value]) => value === buffer)?.[0]
  const run = {
    director,
    perform: (actions) => player.perform(actions),
    // The realtime engine at speech_stopped (live_voice_controller.js), and
    // GPT-Live once the person's transcript goes quiet (gpt_live_call.js).
    stopped: () => {
      player.perform(director.personStopped())
      player.perform(director.transition("thinking"))
      player.perform(director.heardPerson())
    },
    talking: () => {
      player.perform(director.personTalking())
      player.perform(director.transition("listening"))
    },
    // What sounded since the call came up: a source stopped before it started made no sound.
    sounded: () => sources
      .filter((source) => source.stoppedAt === undefined ? source.at <= now / 1000 : source.at < source.stoppedAt)
      .map((source) => cueOf(source.buffer))
      .filter((cue) => cue !== "connected"),
    micClosings: () => micClosings
  }
  player.perform(director.transition("listening"))
  advance(1)
  micClosings = 0
  return run
}

const report = (name, run, extra = {}) =>
  console.log(JSON.stringify({ name, sounded: run.sounded(), micClosings: run.micClosings(), ...extra }))

// A half-second pause, then more speech: nothing sounds, and the microphone is never closed on them.
{
  const run = call()
  run.talking()
  advance(2)
  run.stopped()
  advance(0.5)
  run.talking()
  advance(4)
  report("pause_then_more_speech", run)
}

// A pause just short of SETTLE is still a pause.
{
  const run = call()
  run.talking()
  advance(2)
  run.stopped()
  advance(SETTLE - 0.05)
  run.talking()
  advance(4)
  report("pause_just_short_of_settle", run)
}

// Several short pauses in one long thought: silence throughout.
{
  const run = call()
  run.talking()
  for (let i = 0; i < 4; i++) {
    advance(1.5)
    run.stopped()
    advance(0.7)
    run.talking()
  }
  advance(4)
  report("several_pauses", run)
}

// A real end of turn with the answer slow to come: heard, then the thinking pulse.
{
  const run = call()
  run.talking()
  advance(2)
  run.stopped()
  advance(SETTLE - 0.05)
  const beforeSettle = run.sounded()
  advance(0.1)
  const atSettle = run.sounded()
  advance(1.5)
  report("real_end_of_turn", run, { beforeSettle, atSettle })
}

// A real end of turn answered quickly: the reply is the cue, so nothing sounds.
{
  const run = call()
  run.talking()
  advance(2)
  run.stopped()
  advance(0.9)
  run.perform(run.director.transition("speaking"))
  advance(4)
  report("quick_answer", run)
}

// A pause while a tool runs brings the working loop back only after SETTLE.
{
  const run = call()
  run.perform(run.director.toolsRunning(1))
  run.perform(run.director.transition("working"))
  advance(0.5)
  const working = run.sounded()
  run.talking()
  advance(1)
  run.perform(run.director.personStopped())
  advance(0.6)
  run.talking()
  advance(3)
  const afterPause = run.sounded()
  run.perform(run.director.personStopped())
  advance(SETTLE + 0.5)
  report("tool_running", run, { working, afterPause })
}

// A tool the model starts right after the stop is committed work: the working loop does not wait.
{
  const run = call()
  run.talking()
  advance(2)
  run.perform(run.director.personStopped())
  run.perform(run.director.toolsRunning(1))
  run.perform(run.director.transition("working"))
  advance(0.5)
  report("tool_after_stop", run)
}

// A failure while they talk waits out SETTLE after they stop, and a pause they talk on from keeps it quiet.
{
  const run = call()
  run.talking()
  run.perform(run.director.actionFailed())
  advance(1)
  run.perform(run.director.personStopped())
  advance(0.5)
  const duringPause = run.sounded()
  run.talking()
  advance(1)
  report("held_failure", run, { duringPause })
}

// Gated, a stop under a reply is not a turn the call is answering: the next response's loop does not wait for it.
{
  const run = call()
  run.perform(run.director.transition("speaking"))
  run.perform(run.director.personTalking())
  run.perform(run.director.personStopped())
  const actions = run.director.transition("thinking")
  console.log(JSON.stringify({ name: "stop_under_a_reply", actions }))
}

// The same held failure, and the person really done: it sounds once SETTLE has passed.
{
  const run = call()
  run.talking()
  run.perform(run.director.actionFailed())
  advance(1)
  run.perform(run.director.personStopped())
  advance(SETTLE - 0.05)
  const beforeSettle = run.sounded()
  advance(1)
  report("held_failure_real_stop", run, { beforeSettle })
}
