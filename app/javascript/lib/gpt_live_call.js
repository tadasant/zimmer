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
// A long call's seconds are reported as it goes, so a tab that dies takes at
// most this much unreported time with it.
const SESSION_REPORT_MS = 60000

export class GptLiveCall {
  // `call`: the dock's URLs for the conversation. `mic`: the open microphone
  // stream. `audio`: the element the answer plays through. Callbacks:
  // onState(state), onError(message), onEnded({ dropped }).
  constructor({ call, mic, audio, onState, onError, onEnded }) {
    this.call = call
    this.mic = mic
    this.audio = audio
    this.onState = onState
    this.onError = onError
    this.onEnded = onEnded
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
        this.reportedSeconds = 0
        this.sessionTimer = setInterval(() => this.reportSession({ partial: true }), SESSION_REPORT_MS)
        this.onState("listening")
        break
      case "session.input_transcript.delta":
        this.flushAssistant()
        this.userText += event.delta || ""
        this.userSpokeAt = performance.now()
        this.awaitingAnswer = true
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
        this.onState("speaking")
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
        break
    }
  }

  async delegate(delegationId) {
    const pending = this.userText
    this.flushUser()
    this.delegatedThisTurn = true
    this.onState("working")
    try {
      const response = await this.post(this.urls.delegations, { delegation_id: delegationId, pending_user_text: pending })
      const body = await response.json().catch(() => ({}))
      if (this.ended) return
      if (!response.ok) {
        this.commentary(delegationId, `I couldn't do that: ${body.error || `Zimmer answered ${response.status}`}.`)
        return
      }
      if (body.warning && !this.warned) {
        this.warned = true
        this.send({ type: "session.thinking.append", event_id: this.eventId(), delegation_id: null, content: `Budget note from Zimmer: ${body.warning}` })
      }
      ;(body.chunks || []).forEach((chunk) => this.commentary(delegationId, chunk))
      if (body.end_call) this.hangUpAfterGoodbye()
    } catch (_error) {
      if (!this.ended) this.commentary(delegationId, "I couldn't reach Zimmer just now. Try again in a moment.")
    }
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
    this.flushAssistant()
    if (this.hangingUp) this.end()
    else if (!this.ended) this.onState("listening")
  }

  flushUser() {
    const text = this.userText.trim()
    this.userText = ""
    if (text) this.recordTurn("user", text)
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
    clearTimeout(this.goodbyeTimer)
    clearTimeout(this.closeTimer)
    clearInterval(this.sessionTimer)
    this.closeResolve?.()
    this.flushUser()
    this.flushAssistant()
    if (this.startedAt) this.usage.add("call", { seconds: Math.round(performance.now() - this.startedAt) / 1000 })
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

  // The tab is closing: whatever the call has used so far, sent before it goes.
  pageHidden() {
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
