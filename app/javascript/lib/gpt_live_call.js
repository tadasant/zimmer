import { csrfHeaders } from "lib/csrf"
import { LiveUsageReporter } from "lib/live_usage_reporter"

// A Live voice call on the `gpt_live_claude` engine: OpenAI's GPT-Live
// (`gpt-live-1`) as the full-duplex voice, with Claude doing the work.
//
// GPT-Live has no tools. When the person asks for something that needs Zimmer
// (or real thought), it emits `session.delegation.created`; this posts the
// delegation to Zimmer, where Claude runs Zimmer's tools and answers, and
// appends the answer as `session.commentary.append` for GPT-Live to say.
//
//   start        WebRTC offer (mic track + `oai-events` data channel) → POST
//                gpt_live_session → Zimmer starts the session with OpenAI and
//                returns its SDP answer. The key never reaches the browser.
//   transcripts  `session.input_transcript.delta` / `output_transcript.delta`
//                arrive as fragments with no turn boundary; a run of one
//                speaker's fragments is one turn, written when the other side
//                starts (or the call ends) → POST turns
//   delegation   `session.delegation.created` → POST delegations → each chunk
//                as `session.commentary.append`; a cap warning as quiet
//                `session.thinking.append`; `end_call` hangs up once the
//                goodbye has been said
//   hang-up      GPT-Live can say goodbye without delegating, and a goodbye
//                ends nothing. So when the person's last line asked to hang
//                up and GPT-Live's answer to it is a goodbye, with no
//                delegation running, the call ends once it has been said
//                (endsTheCall), as if the backend had asked
//   cues         the same signals a Realtime call gives lib/live_cues, read
//                off GPT-Live's events, which have no speech boundaries: the
//                person's transcript starting is personTalking, its going quiet
//                for HEARD_IDLE_MS with no answer begun is heardPerson (and
//                thinking), each delegation in flight is a running tool (the
//                working loop, through any filler GPT-Live says over it), and a
//                delegation Zimmer could not answer is actionFailed → onCue
//   cost         the session's seconds, each turn's time to first audio, and
//                the call's length → POST usage (lib/live_usage_reporter)
//   end          `session.close`, then wait for `session.closed` (its usage)
//                before closing the peer connection
//
// Audio goes browser ⇄ OpenAI, as on the default engine; only text and timings
// reach Zimmer.
const ENGINE = "gpt_live_claude"
// The longest a hang-up waits for the goodbye, and for `session.closed`.
const GOODBYE_GRACE_MS = 8000
const CLOSE_GRACE_MS = 3000
// Output fragments this far apart are one finished answer.
const SPOKEN_IDLE_MS = 1200
// The person's transcript quiet this long, with no answer begun: their line was
// heard.
const HEARD_IDLE_MS = 600
// Thinking (after heard, or after Claude answered) with nothing said this long:
// GPT-Live is not answering, so the call goes back to listening, quietly.
const ANSWER_GRACE_MS = 8000
// A long call's seconds are reported as it goes, so a tab that dies takes at
// most this much unreported time with it.
const SESSION_REPORT_MS = 60000
// The person asking to hang up, and the voice saying goodbye. Kept in step
// with GptLiveConductor.endsTheCall in ios/Sources/ZimmerKit/Live.
const ASKED_TO_HANG_UP = /\b(hang (it )?up|end (the|this) call|stop listening|good ?bye|bye)\b/
const NOT_ASKING = /\b(don'?t|do not|not yet|never|how)\b/
const SAID_GOODBYE = /\b(hanging up|ending (the|this) call|good ?bye|bye)\b/

// The person's line asked to hang up and the answer to it said goodbye: the
// call is over, whether or not GPT-Live delegated the hang-up.
export function endsTheCall(asked, said) {
  const plain = (text) => (text || "").toLowerCase().replace(/[\u2018\u2019]/g, "'")
  const line = plain(asked)
  return ASKED_TO_HANG_UP.test(line) && !NOT_ASKING.test(line) && SAID_GOODBYE.test(plain(said))
}

export class GptLiveCall {
  // `call`: the dock's URLs for the conversation. `mic`: the open microphone
  // stream. `audio`: the element the answer plays through. Callbacks:
  // onState(state), onError(message), onEnded({ dropped }), and onCue(signal,
  // arg) with a LiveCueDirector method's name and its argument.
  constructor({ call, mic, audio, onState, onError, onEnded, onCue = () => {} }) {
    this.call = call
    this.mic = mic
    this.audio = audio
    this.onState = onState
    this.onError = onError
    this.onEnded = onEnded
    // No cue once the call is closing: the farewell is the dock's.
    this.onCue = (signal, arg) => { if (!this.ended && !this.closing) onCue(signal, arg) }
    this.delegations = new Set()
    const base = `/live_conversations/${call.conversationId}`
    this.urls = { session: `${base}/gpt_live_session`, delegations: `${base}/delegations`, turns: call.turnsUrl || `${base}/turns` }
    this.usage = new LiveUsageReporter(`${base}/usage`, ENGINE)
    this.userText = ""
    this.assistantText = ""
    this.ended = false
  }

  async start() {
    const pc = new RTCPeerConnection()
    this.pc = pc
    pc.ontrack = (event) => { this.audio.srcObject = event.streams[0] }
    this.mic.getTracks().forEach((track) => pc.addTrack(track, this.mic))
    pc.onconnectionstatechange = () => {
      if (["failed", "closed"].includes(pc.connectionState) && !this.ended) this.finish({ dropped: true })
    }
    const channel = pc.createDataChannel("oai-events")
    this.channel = channel
    channel.onmessage = (message) => this.handle(JSON.parse(message.data))

    const offer = await pc.createOffer()
    await pc.setLocalDescription(offer)
    const response = await this.post(this.urls.session, { sdp: offer.sdp })
    const body = await response.json().catch(() => ({}))
    if (!response.ok) throw new Error(body.error || `Zimmer could not start the GPT-Live call (${response.status}).`)
    this.sessionId = body.session_id
    // Hung up while Zimmer was starting it: never connect a session nobody wants.
    if (this.ended || this.closing) {
      this.finish({ dropped: false })
      return
    }
    await pc.setRemoteDescription({ type: "answer", sdp: body.sdp })
  }

  handle(event) {
    if (this.ended) return
    switch (event.type) {
      case "session.started":
        this.startedAt = performance.now()
        this.callMark = this.startedAt
        this.reportedSeconds = 0
        this.sessionTimer = setInterval(() => this.reportSession({ partial: true }), SESSION_REPORT_MS)
        this.onState("listening")
        break
      case "session.input_transcript.delta":
        this.flushAssistant()
        this.userText += event.delta || ""
        this.userSpokeAt = performance.now()
        this.awaitingAnswer = true
        clearTimeout(this.thinkingTimer)
        if (!this.personTalking) {
          this.personTalking = true
          this.onCue("personTalking")
        }
        clearTimeout(this.heardTimer)
        this.heardTimer = setTimeout(() => this.heard(), HEARD_IDLE_MS)
        this.onState("listening")
        break
      case "session.output_transcript.delta":
        this.flushUser()
        if (this.awaitingAnswer && this.userSpokeAt) {
          this.usage.latency(performance.now() - this.userSpokeAt, { details: { delegated: Boolean(this.delegatedThisTurn) } })
        }
        this.awaitingAnswer = false
        this.delegatedThisTurn = false
        // The goodbye has started: once it stops, the call ends.
        if (this.goodbyePending) {
          this.goodbyePending = false
          this.hangingUp = true
        }
        this.assistantText += event.delta || ""
        this.saying = true
        clearTimeout(this.thinkingTimer)
        this.onState("speaking")
        // The answer has begun: the person's line needs no heard.
        this.personDone()
        clearTimeout(this.spokenTimer)
        this.spokenTimer = setTimeout(() => this.spokeOut(), SPOKEN_IDLE_MS)
        break
      case "session.delegation.created":
        if (event.delegation?.target === "client") this.delegate(event.delegation.id)
        break
      case "session.closed":
        this.closedUsage = event.usage
        this.finish({ dropped: false })
        break
      case "error":
        this.onError(event.error?.message || "GPT-Live reported an error.")
        // As on Realtime: with nothing running or sounding, no answer is coming,
        // so back to listening. A stray error while Claude works or GPT-Live
        // talks means nothing yet.
        if (this.delegations.size === 0 && !this.saying) {
          clearTimeout(this.thinkingTimer)
          this.onCue("noAnswerComing")
          this.onState("listening")
        }
        break
    }
  }

  async delegate(delegationId) {
    const pending = this.userText
    this.flushUser()
    this.personDone()
    this.delegatedThisTurn = true
    clearTimeout(this.thinkingTimer)
    this.delegations.add(delegationId)
    // Running first, so the call goes straight to the working loop, not through thinking.
    this.onCue("toolsRunning", this.delegations.size)
    this.onState("working")
    try {
      const response = await this.post(this.urls.delegations, { delegation_id: delegationId, pending_user_text: pending })
      const body = await response.json().catch(() => ({}))
      if (this.ended) return
      if (!response.ok) {
        this.delegationDone(delegationId, { failed: true, saying: true })
        this.commentary(delegationId, `I couldn't do that: ${body.error || `Zimmer answered ${response.status}`}.`)
        return
      }
      this.delegationDone(delegationId, { failed: false, saying: (body.chunks || []).some(Boolean) })
      if (body.warning && !this.warned) {
        this.warned = true
        this.send({ type: "session.thinking.append", event_id: this.eventId(), delegation_id: null, content: `Budget note from Zimmer: ${body.warning}` })
      }
      ;(body.chunks || []).forEach((chunk) => this.commentary(delegationId, chunk))
      if (body.end_call) this.hangUpAfterGoodbye()
    } catch (_error) {
      if (this.ended) return
      // Already counted done if the answer came and something after it threw.
      this.delegationDone(delegationId, { failed: true, saying: true })
      this.commentary(delegationId, "I couldn't reach Zimmer just now. Try again in a moment.")
    }
  }

  // A delegation came back: one fewer running tool. The last one back with
  // GPT-Live quiet: thinking until it says what came back (the answer, or that
  // it failed), or ANSWER_GRACE_MS passes. Nothing to say: listening.
  delegationDone(delegationId, { failed, saying }) {
    if (this.ended || this.closing || !this.delegations.delete(delegationId)) return
    this.onCue("toolsRunning", this.delegations.size)
    if (this.delegations.size === 0 && !this.saying) {
      if (saying) this.thinkUntilAnswered()
      else this.onState("listening")
    }
    if (failed) this.onCue("actionFailed")
  }

  thinkUntilAnswered() {
    this.onState("thinking")
    clearTimeout(this.thinkingTimer)
    this.thinkingTimer = setTimeout(() => {
      if (!this.ended && !this.closing && this.delegations.size === 0) this.onState("listening")
    }, ANSWER_GRACE_MS)
  }

  // The person's transcript went quiet with no answer begun: their line was
  // heard, and the call is thinking about it.
  heard() {
    this.heardTimer = null
    if (this.ended || this.closing) return
    const answered = !this.awaitingAnswer
    this.personDone()
    if (answered) return
    this.thinkUntilAnswered()
    this.onCue("heardPerson")
  }

  // The person's run of transcript is over: they stopped talking.
  personDone() {
    clearTimeout(this.heardTimer)
    this.heardTimer = null
    if (!this.personTalking) return
    this.personTalking = false
    this.onCue("personStopped")
  }

  commentary(delegationId, content) {
    if (content) this.send({ type: "session.commentary.append", event_id: this.eventId(), delegation_id: delegationId, content })
  }

  // The backend asked to end the call (a hang-up, or a spend cap): let the
  // goodbye be said, then close — or after GOODBYE_GRACE_MS, whatever is still
  // sounding. The call ends when the speech that starts after this stops, not
  // when an earlier filler line ("one moment…") does.
  hangUpAfterGoodbye() {
    this.goodbyePending = true
    clearTimeout(this.goodbyeTimer)
    this.goodbyeTimer = setTimeout(() => this.end(), GOODBYE_GRACE_MS)
  }

  spokeOut() {
    this.saying = false
    const said = this.assistantText
    this.flushAssistant()
    if (this.hangingUp || (this.delegations.size === 0 && endsTheCall(this.lastUserLine, said))) this.end()
    else if (!this.ended) this.onState("listening")
  }

  flushUser() {
    const text = this.userText.trim()
    this.userText = ""
    if (!text) return
    this.lastUserLine = text
    this.recordTurn("user", text)
  }

  flushAssistant() {
    const text = this.assistantText.trim()
    this.assistantText = ""
    if (text) this.recordTurn("assistant", text)
  }

  recordTurn(role, content) {
    this.post(this.urls.turns, { role, content }).catch(() => {})
  }

  // Close the session and wait (briefly) for `session.closed`, which carries
  // the final usage; then let go of the connection.
  async end() {
    if (this.ended || this.closing) return
    this.closing = true
    // The call ends now for the person; the wait for `session.closed` below
    // is not part of its length.
    this.endedAt = performance.now()
    this.send({ type: "session.close", event_id: this.eventId() })
    await new Promise((resolve) => {
      this.closeResolve = resolve
      this.closeTimer = setTimeout(resolve, CLOSE_GRACE_MS)
    })
    this.finish({ dropped: false })
  }

  finish({ dropped }) {
    if (this.ended) return
    this.ended = true
    clearTimeout(this.spokenTimer)
    clearTimeout(this.heardTimer)
    clearTimeout(this.thinkingTimer)
    clearTimeout(this.goodbyeTimer)
    clearTimeout(this.closeTimer)
    clearInterval(this.sessionTimer)
    this.closeResolve?.()
    this.flushUser()
    this.flushAssistant()
    this.reportCall()
    this.reportSession()
    this.channel?.close()
    this.pc?.close()
    this.channel = null
    this.pc = null
    this.onEnded({ dropped })
  }

  // GPT-Live bills the session's seconds: reported every SESSION_REPORT_MS while
  // the call runs, and the rest at the end. The total is `session.closed`'s
  // final usage when it came, else the seconds this browser saw.
  reportSession({ partial = false } = {}) {
    if (this.sessionReported || !this.startedAt) return
    let total = (performance.now() - this.startedAt) / 1000
    let fromUsage = false
    if (!partial) {
      this.sessionReported = true
      const usage = this.closedUsage || {}
      const reported = usage.duration_seconds ?? usage.session_seconds ?? (usage.duration_ms != null ? usage.duration_ms / 1000 : null)
      if (reported != null) { total = reported; fromUsage = true }
    }
    const seconds = Math.max(total - this.reportedSeconds, 0)
    this.reportedSeconds += seconds
    if (seconds > 0) {
      this.usage.add("voice_session", {
        seconds: Math.round(seconds * 1000) / 1000,
        details: { session_id: this.sessionId || "", from_usage: fromUsage, partial }
      })
    }
    this.usage.flush({ keepalive: true })
  }

  // The call's length since the last report, measured to when the person hung
  // up (not to the end of the close grace), as the Realtime call is.
  reportCall({ partial = false } = {}) {
    if (!this.callMark) return
    const now = this.endedAt ?? performance.now()
    this.usage.add("call", { seconds: Math.round(now - this.callMark) / 1000, details: { partial } })
    this.callMark = partial ? now : null
  }

  // The tab is closing: whatever the call has used so far, sent before it goes.
  pageHidden() {
    this.reportCall({ partial: true })
    this.reportSession({ partial: true })
  }

  send(event) {
    if (this.channel?.readyState === "open") this.channel.send(JSON.stringify(event))
  }

  eventId() {
    this.seq = (this.seq || 0) + 1
    return `zimmer_${this.seq}`
  }

  post(url, body) {
    return fetch(url, { method: "POST", credentials: "same-origin", headers: csrfHeaders({ Accept: "application/json" }), body: JSON.stringify(body) })
  }
}
