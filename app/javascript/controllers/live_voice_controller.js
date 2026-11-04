import { Controller } from "@hotwired/stimulus"
import { csrfHeaders } from "lib/csrf"
import { LiveCueDirector, LiveCuePlayer } from "lib/live_cues"

// The Live Mode voice call, owned by a dock in the layout (shared/_live_voice_dock,
// data-turbo-permanent) rather than by the conversation page — a Turbo
// navigation replaces the page body, and a peer connection living in it would
// drop the call on every click.
//
// The audio never touches Zimmer. Rails mints a short-lived OpenAI client
// secret with the whole session config (instructions, tools, voice); the
// browser opens WebRTC to OpenAI with it, and then relays over HTTP:
//
//   function call   response.function_call_arguments.done → POST tool_calls
//                   → conversation.item.create(function_call_output), and once
//                   the response is done, one response.create
//   transcripts     conversation.item.input_audio_transcription.completed and
//                   response.output_audio_transcript.done → POST turns
//   tool changes    a tool call that enabled or disabled a server returns the
//                   new tool list → session.update
//   settings        a tool call that changed the Live settings returns a whole
//                   session.update; a save on /live/settings dispatches
//                   live-voice:settings-changed, and the dock fetches one
//                   (POST session_update) → session.update
//   listening       with the Listening setting gated (wake word, dynamic), turn
//                   detection starts no reply itself: each finished user line
//                   goes to POST turns, which answers whether to reply →
//                   response.create, or conversation.item.delete to drop it
//   cues            the call's state and these events → lib/live_cues, the same
//                   sounds as the phone and the car
export default class extends Controller {
  static targets = ["panel", "status", "title", "link", "mute", "error"]

  // Once per element, not per connect: Turbo carries a permanent element to the
  // next page by detaching and re-attaching it, which disconnects and
  // reconnects this controller mid-call. The call's state must survive that.
  initialize() {
    this.state = "idle"
    this.pendingCalls = new Map()
    this.runningTools = 0
    this.director = new LiveCueDirector()
    this.cues = new LiveCuePlayer({
      onMicGate: (closed) => { this.cueSounding = closed; this.applyMic() },
      onLoopTimeout: () => this.cues.perform(this.director.loopTimedOut())
    })
  }

  connect() {
    this.onStart = (event) => this.start(event.detail)
    // A hang-up names its conversation; one for another conversation is not
    // this call's business. The dock's own button calls hangUp() directly.
    this.onHangup = (event) => {
      const target = event.detail?.conversationId
      if (target && this.call && String(target) !== String(this.call.conversationId)) return
      this.hangUp()
    }
    this.onQuery = () => this.broadcast()
    this.onSettingsChanged = () => this.refreshSession()
    window.addEventListener("live-voice:start", this.onStart)
    window.addEventListener("live-voice:settings-changed", this.onSettingsChanged)
    window.addEventListener("live-voice:hangup", this.onHangup)
    window.addEventListener("live-voice:query", this.onQuery)
    // Re-attached after a navigation: the new page asked before we were back.
    if (this.state !== "idle") this.broadcast()
  }

  disconnect() {
    window.removeEventListener("live-voice:start", this.onStart)
    window.removeEventListener("live-voice:hangup", this.onHangup)
    window.removeEventListener("live-voice:query", this.onQuery)
    window.removeEventListener("live-voice:settings-changed", this.onSettingsChanged)
    // Deliberately no hangUp(): see initialize(). Closing the tab ends the
    // call with the page; nothing else should.
  }

  async start(call) {
    if (this.state !== "idle") {
      if (this.call && String(this.call.conversationId) === String(call.conversationId)) return
      this.hangUp()
    }
    this.cues.unlock()
    this.director = new LiveCueDirector()
    this.call = call
    this.generation = (this.generation || 0) + 1
    const mine = this.generation
    this.setState("connecting")
    this.showError(null)

    try {
      const session = await this.mintSecret(call.clientSecretUrl)
      if (mine !== this.generation) return
      this.gated = ["wake_word", "dynamic"].includes(session.listening)

      this.mic = await navigator.mediaDevices.getUserMedia({ audio: true })
      if (mine !== this.generation) { this.stopMic(); return }

      const pc = new RTCPeerConnection()
      this.pc = pc
      this.audio = this.audio || document.createElement("audio")
      this.audio.autoplay = true
      pc.ontrack = (event) => { this.audio.srcObject = event.streams[0] }
      this.mic.getTracks().forEach((track) => pc.addTrack(track, this.mic))
      pc.onconnectionstatechange = () => {
        if (["failed", "closed"].includes(pc.connectionState) && mine === this.generation) {
          this.showError("The call dropped.")
          this.hangUp({ keepError: true, dropped: true })
        }
      }

      const channel = pc.createDataChannel("oai-events")
      this.channel = channel
      channel.onopen = () => { if (mine === this.generation) this.setState("listening") }
      channel.onmessage = (message) => this.handleEvent(JSON.parse(message.data), mine)

      const offer = await pc.createOffer()
      await pc.setLocalDescription(offer)
      const answer = await fetch(session.calls_url, {
        method: "POST",
        body: offer.sdp,
        headers: { Authorization: `Bearer ${session.client_secret}`, "Content-Type": "application/sdp" }
      })
      if (!answer.ok) throw new Error(`OpenAI refused the call (${answer.status}).`)
      if (mine !== this.generation) return
      await pc.setRemoteDescription({ type: "answer", sdp: await answer.text() })
    } catch (error) {
      if (mine !== this.generation) return
      this.showError(error.message || String(error))
      this.hangUp({ keepError: true })
    }
  }

  // The conversation may still be reading its AGENTS.md (409); give it a moment.
  async mintSecret(url) {
    for (let attempt = 0; attempt < 6; attempt++) {
      const response = await this.post(url, { listening_modes: 1 })
      if (response.ok) return response.json()
      const body = await response.json().catch(() => ({}))
      if (response.status !== 409 || !/still reading/i.test(body.error || "")) {
        throw new Error(body.error || `Zimmer refused the call (${response.status}).`)
      }
      await new Promise((resolve) => setTimeout(resolve, 1500))
    }
    throw new Error("The conversation is taking too long to get ready.")
  }

  handleEvent(event, generation) {
    if (generation !== this.generation) return

    switch (event.type) {
      case "input_audio_buffer.speech_started":
        // Gated, speech does not cut a reply off, so the reply is still what is happening.
        if (!(this.gated && this.state === "speaking")) {
          this.cues.perform(this.director.personTalking())
          this.setState("listening")
        }
        break
      // Gated, the person counts as heard once Zimmer says the line gets an answer.
      case "input_audio_buffer.speech_stopped":
        if (!this.gated && this.state !== "speaking") {
          this.setState("thinking")
          this.cues.perform(this.director.heardPerson())
        }
        break
      case "response.created":
        this.responseActive = true
        this.requested = false
        this.setState("thinking")
        break
      // What OpenAI applied, not what was sent: a refused session.update leaves
      // the call as it was, and so whether it is gated.
      case "session.created":
      case "session.updated":
        this.noteSession(event.session)
        break
      case "response.output_audio.delta":
      case "response.output_audio_transcript.delta":
        if (this.state !== "speaking") this.setState("speaking")
        break
      case "response.function_call_arguments.done":
        this.relayToolCall(event, generation)
        break
      case "response.done":
        this.responseActive = false
        this.finishResponse(event.response, generation)
        break
      case "conversation.item.input_audio_transcription.completed":
        if (this.gated) {
          this.hear(event, generation)
        } else {
          this.recordTurn("user", event.transcript)
        }
        break
      case "conversation.item.input_audio_transcription.failed":
        // Gated, a line nobody could read is not one to answer.
        if (this.gated && event.item_id) this.send({ type: "conversation.item.delete", item_id: event.item_id })
        break
      case "response.output_audio_transcript.done":
        this.recordTurn("assistant", event.transcript)
        break
      case "error":
        // A refused response.create never gets its response.created.
        this.requested = false
        this.showError(event.error?.message || "OpenAI reported an error.")
        // With nothing running or about to, no answer is coming.
        if (!this.responseActive && this.runningTools === 0 && !this.pendingResponse && this.state !== "speaking") {
          this.cues.perform(this.director.noAnswerComing())
          this.setState("listening")
        }
        break
    }
  }

  // Started as soon as the arguments are complete, so several calls in one
  // response run side by side.
  relayToolCall({ call_id: callId, name, arguments: args }, generation) {
    if (!callId || this.pendingCalls.has(callId)) return
    this.runningTools += 1
    this.cues.perform(this.director.toolsRunning(this.runningTools))
    this.setState("working")
    const pending = this.post(this.call.toolCallsUrl, { call_id: callId, name, arguments: args, listening_modes: 1 })
      .then(async (response) => {
        const body = await response.json().catch(() => ({}))
        if (generation !== this.generation) return
        const output = response.ok ? body.output : `Zimmer could not run ${name}: ${body.error || response.status}`
        this.send({ type: "conversation.item.create", item: { type: "function_call_output", call_id: callId, output: String(output ?? "") } })
        if (response.ok && body.session) {
          this.sendSession(body.session)
        } else if (response.ok && body.tools_changed && Array.isArray(body.tools)) {
          this.send({ type: "session.update", session: { type: "realtime", tools: body.tools } })
        }
        this.toolFinished(!response.ok || body.error === true)
      })
      .catch((error) => {
        if (generation !== this.generation) return
        this.send({ type: "conversation.item.create", item: { type: "function_call_output", call_id: callId, output: `Zimmer could not be reached: ${error.message}` } })
        this.toolFinished(true)
      })
    this.pendingCalls.set(callId, pending)
  }

  toolFinished(failed) {
    this.runningTools -= 1
    this.cues.perform(this.director.toolsRunning(this.runningTools))
    if (failed) this.cues.perform(this.director.actionFailed())
  }

  // A response that asked for tools ends before their results exist; once every
  // result is in, ask for the response that uses them — exactly once.
  //
  // Only for a response that completed: one the user talked over was cancelled,
  // and a function call it was cut off in the middle of is not one to run.
  // And never on top of a response already running — with server VAD the user
  // speaking mid-tool starts one — so in that case the request waits for it to
  // finish (sendPendingResponse).
  async finishResponse(response, generation) {
    this.sendPendingResponse()
    if (response?.status && response.status !== "completed") {
      if (!this.requested && this.state !== "idle") this.setState("listening")
      if (response.status !== "cancelled") this.cues.perform(this.director.actionFailed())
      return
    }
    const callIds = (response?.output || []).filter((item) => item.type === "function_call").map((item) => item.call_id)
    if (callIds.length === 0) {
      if (this.state !== "idle") this.setState("listening")
      return
    }
    callIds.forEach((callId) => {
      if (!this.pendingCalls.has(callId)) {
        const item = response.output.find((entry) => entry.call_id === callId)
        this.relayToolCall({ call_id: callId, name: item.name, arguments: item.arguments }, generation)
      }
    })
    await Promise.all(callIds.map((callId) => this.pendingCalls.get(callId)))
    callIds.forEach((callId) => this.pendingCalls.delete(callId))
    if (generation !== this.generation) return
    this.pendingResponse = true
    this.sendPendingResponse()
  }

  sendPendingResponse() {
    if (!this.pendingResponse || this.responseActive || this.requested) return
    this.pendingResponse = false
    this.requested = true
    this.send({ type: "response.create" })
  }

  // The Live settings changed somewhere other than this call's own tool calls:
  // bring the open call up to them. The model and voice stay as they are until
  // the next call; the server leaves them out.
  async refreshSession() {
    if (this.state === "idle" || !this.call?.sessionUpdateUrl) return
    const generation = this.generation
    try {
      const response = await this.post(this.call.sessionUpdateUrl, { listening_modes: 1 })
      const body = await response.json().catch(() => ({}))
      if (generation !== this.generation) return
      if (response.ok && body.session) this.sendSession(body.session)
    } catch (_error) {
      // The next call starts on the new settings anyway.
    }
  }

  sendSession(session) {
    this.send({ type: "session.update", session })
  }

  // The call's session as OpenAI has it. Its turn detection says whether the
  // call is gated: create_response false means we ask for each reply.
  noteSession(session) {
    const detection = session?.audio?.input?.turn_detection
    if (detection && "create_response" in detection) this.gated = detection.create_response === false
  }

  // Gated: Zimmer decides whether this line is answered. A kept line is
  // answered once nothing else is running; a dropped one leaves the call too.
  // Zimmer unreachable answers it — a stray reply beats a call gone quiet.
  async hear(event, generation) {
    const content = event.transcript?.trim()
    if (!this.call) return
    if (!content) {
      if (event.item_id) this.send({ type: "conversation.item.delete", item_id: event.item_id })
      return
    }
    let respond = true
    try {
      const response = await this.post(this.call.turnsUrl, { role: "user", content, listening_modes: 1 })
      const body = await response.json().catch(() => ({}))
      if (response.ok) respond = body.respond !== false
    } catch (_error) {
      // Answer it.
    }
    if (generation !== this.generation) return
    if (respond) {
      this.cues.perform(this.director.heardPerson())
      this.pendingResponse = true
      this.sendPendingResponse()
    } else if (event.item_id) {
      this.send({ type: "conversation.item.delete", item_id: event.item_id })
    }
  }

  recordTurn(role, content) {
    if (!content || !content.trim() || !this.call) return
    this.post(this.call.turnsUrl, { role, content }).catch(() => {})
  }

  send(event) {
    if (this.channel?.readyState === "open") this.channel.send(JSON.stringify(event))
  }

  post(url, body) {
    return fetch(url, {
      method: "POST",
      credentials: "same-origin",
      headers: csrfHeaders({ Accept: "application/json" }),
      body: JSON.stringify(body)
    })
  }

  toggleMute() {
    if (!this.mic?.getAudioTracks()[0]) return
    this.muted = !this.muted
    this.applyMic()
    this.muteTarget.textContent = this.muted ? "Unmute" : "Mute"
    this.muteTarget.setAttribute("aria-pressed", this.muted ? "true" : "false")
  }

  // A disabled track sends silence: when the person muted, and while a cue sounds.
  applyMic() {
    const track = this.mic?.getAudioTracks()[0]
    if (track) track.enabled = !this.muted && !this.cueSounding
  }

  hangUp({ keepError = false, dropped = false } = {}) {
    this.generation = (this.generation || 0) + 1
    this.cues.perform(dropped ? this.director.dropped() : this.director.hungUp())
    this.channel?.close()
    this.pc?.close()
    this.stopMic()
    if (this.audio) this.audio.srcObject = null
    this.channel = null
    this.pc = null
    this.pendingCalls.clear()
    this.runningTools = 0
    this.muted = false
    this.muteTarget.setAttribute("aria-pressed", "false")
    this.pendingResponse = false
    this.responseActive = false
    this.requested = false
    this.gated = false
    if (!keepError) this.showError(null)
    this.setState("idle")
  }

  stopMic() {
    this.mic?.getTracks().forEach((track) => track.stop())
    this.mic = null
  }

  setState(state) {
    this.state = state
    const live = state !== "idle"
    this.panelTarget.classList.toggle("hidden", !live && !this.errorShown)
    this.statusTarget.textContent = {
      idle: "Call ended",
      connecting: "Connecting…",
      listening: "Listening",
      thinking: "Thinking…",
      speaking: "Speaking",
      working: "Working on it…"
    }[state] || state
    if (this.call) this.linkTarget.href = this.call.conversationUrl
    this.muteTarget.classList.toggle("hidden", !live)
    if (!live) this.muteTarget.textContent = "Mute"
    this.cues.perform(this.director.transition(state))
    this.broadcast()
  }

  showError(message) {
    this.errorShown = Boolean(message)
    this.errorTarget.textContent = message || ""
    this.errorTarget.classList.toggle("hidden", !message)
    if (message) this.panelTarget.classList.remove("hidden")
  }

  dismiss() {
    this.showError(null)
    if (this.state === "idle") this.panelTarget.classList.add("hidden")
  }

  broadcast() {
    window.dispatchEvent(new CustomEvent("live-voice:state", {
      detail: { conversationId: this.call?.conversationId, state: this.state }
    }))
  }
}
