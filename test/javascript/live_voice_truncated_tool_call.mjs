// Drives the real live_voice_controller.js through the event sequences of a voice
// call, with the browser taken away: the Stimulus base class, the data channel and
// the HTTP relay are stand-ins, and everything between them is the shipped file.
// Run by live_voice_truncated_tool_call_test.rb; each scenario prints one JSON line.
import { readFileSync } from "node:fs"

const source = readFileSync(process.argv[2], "utf8")
  .replace(/^import .*$/gm, "")
  .replace("export default class extends Controller", "return class extends Controller")
const LiveVoice = new Function("Controller", "csrfHeaders", source)(class {}, () => ({}))

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
  dock.post = async (_url, body) => {
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
  dock.handleEvent({ type: "response.done", response: cutOff([{ type: "message" }]) }, 1)
  await drain()
  report("speech_only_incomplete", dock)
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
