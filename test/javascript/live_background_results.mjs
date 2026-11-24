// Drives the real lib/live_background_results.js and the real GptLiveCall it
// hands results to. Run by live_background_results_test.rb.
import { readFileSync } from "node:fs"
const strip = (path) => readFileSync(path, "utf8").replace(/^import .*$/gm, "").replace(/^export /gm, "")
const { LiveBackgroundResults } = new Function(`${strip(process.argv[2])}\nreturn { LiveBackgroundResults }`)()
const { GptLiveCall } = new Function("csrfHeaders", "LiveUsageReporter", `${strip(process.argv[3])}\nreturn { GptLiveCall }`)(
  () => ({}), class { add() {} latency() {} flush() {} }
)
const out = (name, value) => console.log(JSON.stringify({ name, value }))

function queue({ answers, ready = () => true, deliver, failReports = 0 }) {
  const claims = []
  const reports = []
  const results = new LiveBackgroundResults({
    conversationId: 7, call: "call-1234", ready, deliver,
    post: async (url, body) => {
      if (body.delivered) {
        reports.push(body.delivered)
        return { ok: reports.length > failReports, json: async () => ({ results: [] }) }
      }
      claims.push([ url, body.claim ])
      const answer = answers.shift()
      if (answer === "lost") throw new Error("offline")
      return { ok: true, json: async () => ({ results: answer || [] }) }
    }
  })
  return { results, claims, reports }
}

const one = [ { id: 1, text: "It finished." } ]
{
  const said = []
  const { results, claims } = queue({ answers: [ "lost", one, one ], deliver: (text) => said.push(text) })
  await results.check(0)
  await results.check(1) // lost
  await results.check(0) // the same claim: Zimmer no longer counts what this call claimed
  await results.check(1) // a new claim, the same result: not again
  out("lost_then_once", { said, claims })
}
{
  const said = []
  let ready = true
  const { results, claims } = queue({ answers: [ one ], ready: () => ready, deliver: (text) => said.push(text) })
  ready = false
  await results.check(1)
  const claimedWhileBusy = claims.length
  ready = true
  await results.check(1)
  out("only_while_idle", { claimedWhileBusy, said })
}
{
  // The channel was not open: kept for the next look, with no second claim.
  const said = []
  let open = false
  const { results, claims } = queue({ answers: [ one ], deliver: (text) => open && said.push(text) })
  await results.check(1)
  open = true
  await results.check(0)
  out("kept_until_sent", { said, claims: claims.length })
}
{
  // Zimmer is told until it has heard.
  const { results, reports } = queue({ answers: [ one ], deliver: () => true, failReports: 1 })
  await results.check(1)
  await results.check(0)
  await results.check(0)
  out("reported_until_heard", reports)
}
{
  const sent = []
  const gpt = new GptLiveCall({ call: { conversationId: 7 }, mic: null, audio: null, onState() {}, onError() {}, onEnded() {} })
  gpt.channel = { readyState: "open", send: (text) => sent.push(JSON.parse(text)), close() {} }
  const states = [ gpt.idle() ]
  gpt.handle({ type: "session.started" })
  states.push(gpt.idle())
  gpt.addContext("It finished.")
  gpt.handle({ type: "session.input_transcript.delta", delta: "Hi" })
  states.push(gpt.idle())
  out("gpt_live", { states, sent })
  gpt.finish({ dropped: false })
}
