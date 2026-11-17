// Drives the real lib/gpt_live_call.js through GPT-Live event sequences, with its
// cue signals fed to the real LiveCueDirector from lib/live_cues.js, as the dock
// does. The browser is taken away: timers run on a fake clock, and Zimmer's
// delegation answers are stand-ins. Run by gpt_live_call_cues_test.rb; each
// scenario prints one JSON line of what the person would hear.
import { readFileSync } from "node:fs"

const strip = (path) => readFileSync(path, "utf8").replace(/^import .*$/gm, "").replace(/^export /gm, "")

let now = 0
let timers = []
let nextTimer = 1
const clock = {
  setTimeout: (fn, ms = 0) => { const id = nextTimer++; timers.push({ id, at: now + ms, fn }); return id },
  clearTimeout: (id) => { timers = timers.filter((timer) => timer.id !== id) },
  setInterval: () => 0,
  clearInterval: () => {},
  performance: { now: () => now }
}
// Runs every timer due by `ms` from now, in order.
const advance = (ms) => {
  const until = now + ms
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
const drain = async () => { for (let i = 0; i < 10; i++) await new Promise((resolve) => setImmediate(resolve)) }

const { LiveCueDirector } = new Function(`${strip(process.argv[3])}\nreturn { LiveCueDirector }`)()
const { GptLiveCall } = new Function(
  "csrfHeaders", "LiveUsageReporter", "setTimeout", "clearTimeout", "setInterval", "clearInterval", "performance",
  `${strip(process.argv[2])}\nreturn { GptLiveCall }`
)(() => ({}), class { add() {} latency() {} flush() {} }, clock.setTimeout, clock.clearTimeout, clock.setInterval, clock.clearInterval, clock.performance)

function call(answers = {}) {
  const director = new LiveCueDirector()
  const heard = []
  let state = null
  const hear = (actions) => actions.forEach((action) => heard.push(
    action.play ? `play:${action.play}` : action.startLoop ? `loop:${action.startLoop}` : action.stopLoop ? "stopLoop" : "stopCues"
  ))
  const gpt = new GptLiveCall({
    call: { conversationId: 1 },
    mic: null,
    audio: null,
    onState: (next) => { if (next !== state) { state = next; hear(director.transition(next)) } },
    onError: () => {},
    onEnded: () => {},
    onCue: (signal, arg) => hear(director[signal](arg))
  })
  gpt.send = () => {}
  gpt.post = async (url, body) => {
    if (!url.endsWith("/delegations")) return { ok: true, status: 200, json: async () => ({}) }
    const answer = answers[body.delegation_id] ?? { chunks: ["Done."] }
    if (answer === "unreachable") throw new Error("offline")
    return { ok: answer.status === undefined, status: answer.status ?? 200, json: async () => answer }
  }
  return { gpt, heard }
}

const report = (name, { heard }) => console.log(JSON.stringify({ name, heard }))
const input = (delta) => ({ type: "session.input_transcript.delta", delta })
const output = (delta) => ({ type: "session.output_transcript.delta", delta })
const delegation = (id) => ({ type: "session.delegation.created", delegation: { id, target: "client" } })

// A line goes quiet and no answer has begun: heard, and thinking, until the answer.
{
  const run = call()
  run.gpt.handle({ type: "session.started" })
  run.gpt.handle(input("What's "))
  advance(400)
  run.gpt.handle(input("running?"))
  advance(700)
  run.gpt.handle(output("Two."))
  report("heard_then_answer", run)
}

// An answer that starts before the line has gone quiet long enough: no heard.
{
  const run = call()
  run.gpt.handle({ type: "session.started" })
  run.gpt.handle(input("Hi"))
  advance(300)
  run.gpt.handle(output("Hey."))
  advance(5000)
  report("quick_answer", run)
}

// A delegation: the working loop, again after GPT-Live's filler, thinking once
// Claude has answered, quiet when the answer is said.
{
  let release
  const run = call()
  const post = run.gpt.post
  run.gpt.post = (url, body) => url.endsWith("/delegations")
    ? new Promise((resolve) => { release = () => resolve(post(url, body)) })
    : post(url, body)
  run.gpt.handle({ type: "session.started" })
  run.gpt.handle(input("Start a session"))
  advance(200)
  run.gpt.handle(delegation("d1"))
  run.gpt.handle(output("One moment."))
  advance(1300)
  release()
  await drain()
  run.gpt.handle(output("Started."))
  report("delegation", run)
}

// Zimmer could not be reached: the failed notes.
{
  const run = call({ d1: "unreachable" })
  run.gpt.handle({ type: "session.started" })
  run.gpt.handle(delegation("d1"))
  await drain()
  report("delegation_failed", run)
}

// Zimmer refused the delegation: the failed notes too.
{
  const run = call({ d1: { status: 503, error: "busy" } })
  run.gpt.handle({ type: "session.started" })
  run.gpt.handle(delegation("d1"))
  await drain()
  report("delegation_refused", run)
}

// Two delegations: working until both are back, then thinking.
{
  const releases = {}
  const run = call()
  const post = run.gpt.post
  run.gpt.post = (url, body) => url.endsWith("/delegations")
    ? new Promise((resolve) => { releases[body.delegation_id] = () => resolve(post(url, body)) })
    : post(url, body)
  run.gpt.handle({ type: "session.started" })
  run.gpt.handle(delegation("d1"))
  run.gpt.handle(delegation("d2"))
  releases.d1()
  await drain()
  run.heard.push("|")
  releases.d2()
  await drain()
  report("two_delegations", run)
}

// A stray GPT-Live error while Claude works sounds nothing, so the delegation's
// own failure still does.
{
  let release
  const run = call({ d1: "unreachable" })
  const post = run.gpt.post
  run.gpt.post = (url, body) => url.endsWith("/delegations")
    ? new Promise((resolve) => { release = () => resolve(post(url, body)) })
    : post(url, body)
  run.gpt.handle({ type: "session.started" })
  run.gpt.handle(delegation("d1"))
  run.gpt.handle({ type: "error", error: { message: "bad commentary" } })
  run.heard.push("|")
  release()
  await drain()
  report("error_while_working", run)
}

// Thinking after heard that GPT-Live never answers goes back to listening,
// without failed.
{
  const run = call()
  run.gpt.handle({ type: "session.started" })
  run.gpt.handle(input("Hm"))
  advance(700)
  run.heard.push("|")
  advance(8000)
  report("thinking_gives_up", run)
}

// A call closing after its goodbye makes no more cues.
{
  const run = call()
  run.gpt.handle({ type: "session.started" })
  run.gpt.end()
  run.gpt.handle(input("wait"))
  advance(1000)
  report("closing", run)
}
