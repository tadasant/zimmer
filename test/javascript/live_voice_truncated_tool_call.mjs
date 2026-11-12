// Drives the real live_voice_controller.js through the event sequences of a voice
// call, with the browser taken away: the Stimulus base class, the data channel and
// the HTTP relay are stand-ins, and everything between them is the shipped file.
// Run by live_voice_truncated_tool_call_test.rb; each scenario prints one JSON line.
import { readFileSync } from "node:fs"

const source = readFileSync(process.argv[2], "utf8")
  .replace(/^import .*$/gm, "")
  .replace("export default class extends Controller", "return class extends Controller")
const LiveCueDirector = class { constructor() { return new Proxy(this, { get: () => () => {} }) } }
const LiveCuePlayer = class { perform() {} unlock() {} }
const LiveVoice = new Function("Controller", "csrfHeaders", "LiveCueDirector", "LiveCuePlayer", source)(class {}, () => ({}), LiveCueDirector, LiveCuePlayer)

function call(answers = {}) {
  const dock = new LiveVoice()
  dock.initialize()
  dock.generation = 1
  dock.state = "thinking"
  dock.call = { toolCallsUrl: "/tool_calls", conversationId: 1 }
  dock.sent = []
  dock.states = []
  dock.relayed = []
  dock.send = (event) => dock.sent.push(event)
  dock.setState = (state) => { dock.state = state; dock.states.push(state) }
  dock.bodies = []
  dock.post = async (_url, body) => {
    dock.bodies.push(body)
    dock.relayed.push(body.call_id)
    const answer = answers[body.call_id] ?? { output: "done" }
    return { ok: true, status: 200, json: async () => answer }
  }
  return dock
}

const drain = () => new Promise((resolve) => setTimeout(resolve, 0))
const report = (name, dock) => console.log(JSON.stringify({
  name, state: dock.state, relayed: dock.relayed,
  sent: dock.sent.map((event) => event.type === "session.update" ? `session.update:${event.session.max_output_tokens}` : event.type)
}))

const truncated = { type: "function_call", call_id: "z1", name: "zimmer", arguments: "{\"tool\":\"start_ses", status: "incomplete" }
const cutOff = (output) => ({ status: "incomplete", status_details: { type: "incomplete", reason: "max_output_tokens" }, output })

// The call as it failed: relayed on arguments.done, then the response ends incomplete.
{
  const dock = call({ z1: { output: "Nothing ran: cut off." } })
  dock.handleEvent({ type: "response.created" }, 1)
  dock.handleEvent({ type: "response.function_call_arguments.done", call_id: "z1", name: "zimmer", arguments: truncated.arguments }, 1)
  dock.handleEvent({ type: "response.done", response: cutOff([truncated]) }, 1)
  await drain()
  report("relayed_then_incomplete", dock)
}

// A call first seen in the response.done of a response that ended incomplete.
{
  const dock = call({ z1: { output: "Nothing ran: cut off." } })
  dock.handleEvent({ type: "response.created" }, 1)
  dock.handleEvent({ type: "response.done", response: cutOff([truncated]) }, 1)
  await drain()
  report("first_seen_in_incomplete_done", dock)
}

// A spoken reply cut off, nothing asked for: the call goes back to listening.
{
  const dock = call()
  dock.handleEvent({ type: "response.created" }, 1)
  dock.handleEvent({ type: "response.output_audio_transcript.delta" }, 1)
  dock.handleEvent({ type: "response.done", response: cutOff([{ type: "message" }]) }, 1)
  await drain()
  report("speech_only_incomplete", dock)
}

// The result comes back before the response ends.
{
  const dock = call({ z1: { output: "Nothing ran: cut off." } })
  dock.handleEvent({ type: "response.created" }, 1)
  dock.handleEvent({ type: "response.function_call_arguments.done", call_id: "z1", name: "zimmer", arguments: truncated.arguments }, 1)
  await drain()
  dock.handleEvent({ type: "response.done", response: cutOff([truncated]) }, 1)
  await drain()
  report("result_before_incomplete", dock)
}

// The cap ran out in the model's reasoning: nothing said, nothing called.
{
  const dock = call()
  dock.handleEvent({ type: "response.created" }, 1)
  dock.handleEvent({ type: "response.done", response: cutOff([]) }, 1)
  await drain()
  report("cut_before_a_word", dock)
}

// A settings change later in the call sends Zimmer's session, with the stored cap in it.
{
  const dock = call()
  dock.handleEvent({ type: "response.created" }, 1)
  dock.handleEvent({ type: "response.done", response: cutOff([truncated]) }, 1)
  await drain()
  dock.sendSession({ type: "realtime", max_output_tokens: 1024 })
  report("later_session_update", dock)
}

// A call cut off before its first character.
{
  const dock = call()
  const bodies = []
  const post = dock.post
  dock.post = (url, body) => { bodies.push(body.arguments); return post(url, body) }
  dock.handleEvent({ type: "response.created" }, 1)
  dock.handleEvent({ type: "response.done", response: cutOff([{ ...truncated, arguments: "" }]) }, 1)
  await drain()
  console.log(JSON.stringify({ name: "blank_arguments", arguments: bodies, relayed: dock.relayed, sent: [], state: dock.state }))
}

// OpenAI's filter keeps cutting the call: the cap is not why, and asking stops.
{
  const dock = call()
  const filtered = { status: "incomplete", status_details: { reason: "content_filter" }, output: [truncated] }
  dock.showError = (message) => { dock.error = message }
  for (const id of ["f1", "f2", "f3"]) {
    dock.requested = false
    dock.handleEvent({ type: "response.created" }, 1)
    dock.handleEvent({ type: "response.done", response: { ...filtered, output: [{ ...truncated, call_id: id }] } }, 1)
    await drain()
  }
  report("three_cuts_in_a_row", dock)
  console.log(JSON.stringify({ name: "three_cuts_error", error: dock.error, sent: [], relayed: [], state: dock.state }))
}

// The user talking over a response stays what it was: no follow-up.
{
  const dock = call()
  dock.handleEvent({ type: "response.created" }, 1)
  dock.handleEvent({ type: "response.function_call_arguments.done", call_id: "c1", name: "x", arguments: "{}" }, 1)
  dock.handleEvent({ type: "response.done", response: { status: "cancelled", status_details: { reason: "turn_detected" }, output: [{ type: "function_call", call_id: "c1", name: "x", arguments: "{}" }] } }, 1)
  await drain()
  report("cancelled", dock)
}

// A tool call that moved Live Mode: nothing more down this session, and the dock
// reconnects onto the conversation it names, keeping mute, with no hang-up sound.
{
  const dock = call({ s1: { output: "Switched", switched_to: { id: 8, title: "the poller test" } } })
  const started = []
  dock.director = { hungUp: () => { throw new Error("a move is not a hang-up") }, toolsRunning: () => [], transition: () => [], dropped: () => [] }
  dock.channel = { close() {} }
  dock.muteTarget = { setAttribute() {} }
  dock.showError = () => {}
  dock.muted = true
  dock.start = (next, options) => started.push({ next, options })
  dock.handleEvent({ type: "response.created" }, 1)
  dock.handleEvent({ type: "response.function_call_arguments.done", call_id: "s1", name: "switch_live_conversation", arguments: "{}" }, 1)
  await drain()
  console.log(JSON.stringify({
    name: "switched_mid_call", sent: dock.sent.map((event) => event.type), started,
    bodies: dock.bodies
  }))
}

// A switch made elsewhere: the poll finds another conversation current. One it
// already follows, or an answer that arrives after this call moved on, is nothing.
{
  const followed = []
  const look = async (dock, generation, current, voice = true) => {
    globalThis.fetch = async () => ({ ok: true, json: async () => ({ current_id: current, voice }) })
    dock.reattach = (id) => followed.push(id)
    await dock.followCurrent(generation)
  }
  const dock = call()
  await look(dock, 1, 1)
  await look(dock, 1, null)
  await look(dock, 0, 8)
  await look(dock, 1, 8)
  console.log(JSON.stringify({ name: "follows_current", followed }))
  const hungUp = []
  const typing = call()
  typing.showError = (message) => hungUp.push(message)
  typing.hangUp = (options) => hungUp.push(options)
  await look(typing, 1, 9, false)
  console.log(JSON.stringify({ name: "typed_conversation_ends_the_call", hungUp, followed }))
}

// The first thing a moved call does: speak, unasked and unrecorded.
{
  const dock = call()
  dock.speakFirst()
  console.log(JSON.stringify({ name: "speaks_first", sent: dock.sent.map((event) => event.type), relayed: dock.relayed }))
}

// The whole move through the real hangUp and start, with only the browser's own
// objects and OpenAI stood in for: the secret comes from the new conversation, the
// mic is asked for again, mute survives, and once the channel opens the model is
// asked to speak with nothing posted to the thread.
{
  const requests = []
  const channel = { readyState: "open", sent: [], send(raw) { this.sent.push(JSON.parse(raw).type) }, close() {} }
  Object.defineProperty(globalThis, "navigator", { value: { mediaDevices: { getUserMedia: async () => {
    const track = { enabled: true, stop() {} }
    return { getTracks: () => [track], getAudioTracks: () => [track] }
  } } }, configurable: true })
  globalThis.document = { createElement: () => ({}) }
  globalThis.RTCPeerConnection = class {
    addTrack() {}
    createDataChannel() { return channel }
    async createOffer() { return { sdp: "offer" } }
    async setLocalDescription() {}
    async setRemoteDescription() { channel.onopen() }
    close() {}
  }
  globalThis.fetch = async (url) => { requests.push(url); return { ok: true, status: 200, text: async () => "answer", json: async () => ({}) } }
  const dock = new LiveVoice()
  dock.initialize()
  dock.generation = 1
  dock.state = "listening"
  dock.call = { conversationId: 1 }
  dock.channel = { close() {} }
  dock.muted = true
  const states = []
  dock.setState = (state) => { dock.state = state; states.push(state) }
  dock.showError = () => {}
  dock.muteTarget = { textContent: "", setAttribute() {} }
  dock.watchCurrent = () => {}
  dock.post = async (url, body) => { requests.push(url); return { ok: true, status: 200, json: async () => ({ client_secret: "ek", calls_url: "https://openai.test/calls" }) } }
  dock.reattach(8)
  await drain()
  await drain()
  console.log(JSON.stringify({ name: "reattach_through_start", requests, states, sent: channel.sent, conversation: dock.call.conversationId, muted: dock.muted }))
}

// The person asked to hang up, and the goodbye is still sounding when Zimmer
// answers: the output goes back, no reply is asked for, and the call ends only
// once the response is done and the goodbye has stopped sounding.
{
  const dock = call({ h1: { output: "Hanging up.", error: false, hang_up: true } })
  const ended = []
  dock.hangUp = () => { ended.push(dock.sent.length); dock.generation += 1; dock.hangingUp = false; clearTimeout(dock.hangUpTimer) }
  dock.handleEvent({ type: "response.created" }, 1)
  dock.handleEvent({ type: "output_audio_buffer.started" }, 1)
  dock.handleEvent({ type: "response.function_call_arguments.done", call_id: "h1", name: "hang_up", arguments: "{}" }, 1)
  await drain()
  const beforeDone = ended.length
  dock.handleEvent({ type: "response.done", response: { status: "completed", output: [{ type: "function_call", call_id: "h1", name: "hang_up", arguments: "{}" }] } }, 1)
  await drain()
  const beforeStopped = ended.length
  dock.handleEvent({ type: "output_audio_buffer.stopped" }, 1)
  console.log(JSON.stringify({
    name: "hang_up_after_goodbye", sent: dock.sent.map((event) => event.type), relayed: dock.relayed, state: dock.state,
    beforeDone, beforeStopped, ended: ended.length, hangsUp: dock.bodies[0].hangs_up
  }))
}

// Zimmer answers after a response with nothing left sounding: the call ends at once.
{
  const dock = call({ h1: { output: "Hanging up.", error: false, hang_up: true } })
  let ended = 0
  dock.hangUp = () => { ended += 1; dock.generation += 1; dock.hangingUp = false; clearTimeout(dock.hangUpTimer) }
  dock.handleEvent({ type: "response.created" }, 1)
  dock.handleEvent({ type: "response.done", response: { status: "completed", output: [{ type: "function_call", call_id: "h1", name: "hang_up", arguments: "{}" }] } }, 1)
  await drain()
  await drain()
  console.log(JSON.stringify({ name: "hang_up_nothing_sounding", sent: dock.sent.map((event) => event.type), relayed: dock.relayed, state: dock.state, ended }))
}

// The real hangUp, after a hang-up the person asked for: the call is idle, with
// the hung-up cue, and nothing of the hang-up is left armed for the next call.
{
  const dock = call({ h1: { output: "Hanging up.", error: false, hang_up: true } })
  const cues = []
  dock.director = { hungUp: () => "hung_up", dropped: () => "dropped", toolsRunning: () => [], transition: () => [], actionFailed: () => [] }
  dock.cues = { perform: (cue) => cues.push(cue) }
  dock.channel = { close() {} }
  dock.muteTarget = { setAttribute() {} }
  dock.showError = () => {}
  dock.handleEvent({ type: "response.created" }, 1)
  dock.handleEvent({ type: "response.function_call_arguments.done", call_id: "h1", name: "hang_up", arguments: "{}" }, 1)
  dock.handleEvent({ type: "response.done", response: { status: "completed", output: [{ type: "function_call", call_id: "h1", name: "hang_up", arguments: "{}" }] } }, 1)
  await drain()
  await drain()
  console.log(JSON.stringify({
    name: "hang_up_through_real_hang_up", sent: dock.sent.map((event) => event.type), relayed: [], state: dock.state,
    cues: cues.filter((cue) => typeof cue === "string"), hangingUp: dock.hangingUp, generation: dock.generation
  }))
}
