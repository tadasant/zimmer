import { Controller } from "@hotwired/stimulus"

// The Live Voice call, owned by a dock in the layout (shared/_live_voice_dock,
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
export default class extends Controller {
  static targets = ["panel", "status", "title", "link", "mute", "error"]

  // Once per element, not per connect: Turbo carries a permanent element to the
  // next page by detaching and re-attaching it, which disconnects and
  // reconnects this controller mid-call. The call's state must survive that.
  initialize() {
    this.state = "idle"
    this.pendingCalls = new Map()
  }

  connect() {
    this.onStart = (event) => this.start(event.detail)
    // A hang-up names its conversation; one for another conversation (ending a
    // Live Mode thread) is not this call's business. The dock's own button
    // calls hangUp() directly.
    this.onHangup = (event) => {
      const target = event.detail?.conversationId
      if (target && this.call && String(target) !== String(this.call.conversationId)) return
      this.hangUp()
    }
    this.onQuery = () => this.broadcast()
    window.addEventListener("live-voice:start", this.onStart)
    window.addEventListener("live-voice:hangup", this.onHangup)
    window.addEventListener("live-voice:query", this.onQuery)
    // Re-attached after a navigation: the new page asked before we were back.
    if (this.state !== "idle") this.broadcast()
  }

  disconnect() {
    window.removeEventListener("live-voice:start", this.onStart)
    window.removeEventListener("live-voice:hangup", this.onHangup)
    window.removeEventListener("live-voice:query", this.onQuery)
    // Deliberately no hangUp(): see initialize(). Closing the tab ends the
    // call with the page; nothing else should.
  }

  async start(call) {
    if (this.state !== "idle") {
      if (this.call && String(this.call.conversationId) === String(call.conversationId)) return
      this.hangUp()
    }
    this.call = call
    this.generation = (this.generation || 0) + 1
    const mine = this.generation
    this.setState("connecting")
    this.showError(null)

    try {
      const session = await this.mintSecret(call.clientSecretUrl)
      if (mine !== this.generation) return

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
          this.hangUp()
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
      const response = await this.post(url, {})
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
        this.setState("listening")
        break
      case "response.created":
        this.responseActive = true
        this.setState("thinking")
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
        this.recordTurn("user", event.transcript)
        break
      case "response.output_audio_transcript.done":
        this.recordTurn("assistant", event.transcript)
        break
      case "error":
        this.showError(event.error?.message || "OpenAI reported an error.")
        break
    }
  }

  // Started as soon as the arguments are complete, so several calls in one
  // response run side by side.
  relayToolCall({ call_id: callId, name, arguments: args }, generation) {
    if (!callId || this.pendingCalls.has(callId)) return
    this.setState("working")
    const pending = this.post(this.call.toolCallsUrl, { call_id: callId, name, arguments: args })
      .then(async (response) => {
        const body = await response.json().catch(() => ({}))
        if (generation !== this.generation) return
        const output = response.ok ? body.output : `Zimmer could not run ${name}: ${body.error || response.status}`
        this.send({ type: "conversation.item.create", item: { type: "function_call_output", call_id: callId, output: String(output ?? "") } })
        if (response.ok && body.tools_changed && Array.isArray(body.tools)) {
          this.send({ type: "session.update", session: { type: "realtime", tools: body.tools } })
        }
      })
      .catch((error) => {
        if (generation !== this.generation) return
        this.send({ type: "conversation.item.create", item: { type: "function_call_output", call_id: callId, output: `Zimmer could not be reached: ${error.message}` } })
      })
    this.pendingCalls.set(callId, pending)
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
    if (response?.status && response.status !== "completed") return
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
    if (!this.pendingResponse || this.responseActive) return
    this.pendingResponse = false
    this.send({ type: "response.create" })
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
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
      },
      body: JSON.stringify(body)
    })
  }

  toggleMute() {
    const track = this.mic?.getAudioTracks()[0]
    if (!track) return
    track.enabled = !track.enabled
    this.muteTarget.textContent = track.enabled ? "Mute" : "Unmute"
    this.muteTarget.setAttribute("aria-pressed", track.enabled ? "false" : "true")
  }

  hangUp({ keepError = false } = {}) {
    this.generation = (this.generation || 0) + 1
    this.channel?.close()
    this.pc?.close()
    this.stopMic()
    if (this.audio) this.audio.srcObject = null
    this.channel = null
    this.pc = null
    this.pendingCalls.clear()
    this.pendingResponse = false
    this.responseActive = false
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
