import { Controller } from "@hotwired/stimulus"
import { csrfHeaders } from "lib/csrf"
import { LiveCueDirector, LiveCuePlayer } from "lib/live_cues"
import { GptLiveCall } from "lib/gpt_live_call"
import { LiveUsageReporter, realtimeUsage } from "lib/live_usage_reporter"

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
//   switching       a tool call that moved Live Mode answers switched_to; the dock
//                   also polls /live/current.json while a call is up, for a move
//                   made elsewhere. Either way the call reconnects onto the new
//                   conversation: a Realtime session cannot forget what it heard,
//                   and a fresh one starts from that conversation's own recap. A
//                   conversation someone is typing in ends the call instead.
//   hanging up      a tool call the person asked to hang up with ("hang up", "stop
//                   listening") answers hang_up: its output goes back, no reply is
//                   asked for after it, and the call ends the way End does once the
//                   response that asked is done and its goodbye has stopped sounding
//                   (output_audio_buffer.stopped) — or HANG_UP_GRACE_MS after Zimmer
//                   answered, whatever is still sounding. Talking over the goodbye
//                   ends it sooner (output_audio_buffer.cleared). A move to another
//                   conversation is not followed meanwhile. The conversation stays
//                   open; tool calls already relayed run to the end on Zimmer's side.
//   engines          the dock tells client_secret it can run `gpt_live_claude`.
//                    When the Live settings pick that engine and it can run,
//                    the answer carries no secret and the call is a GptLiveCall
//                    (lib/gpt_live_call) instead; otherwise it is the Realtime
//                    call above, and a fallback's reason is shown on the dock.
//   cost             a Realtime call reports each response's tokens, each
//                    transcription's tokens and each turn's time to first
//                    audio to the voice-engine ledger (lib/live_usage_reporter).

// How often a call looks for a switch made somewhere else.
const FOLLOW_INTERVAL_MS = 5000
// Put to the model on a call that has just moved, so it speaks first. Not on the
// thread: the person did not say it. The same words as RealtimeConductor's.
const SWITCHED_OPENING = "(We have just switched to this conversation. In one short sentence, say so and where it left off, then stop.)"
// The longest a hang-up the person asked for waits for the goodbye to finish:
// a call must never stay open because an event did not come.
const HANG_UP_GRACE_MS = 8000

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

  // `moved`: this call has followed Live Mode to another conversation, so the
  // model speaks first.
  async start(call, { moved = false, muted = false } = {}) {
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
      if (session.engine === "gpt_live_claude") return await this.startGptLive(call, session, mine, muted)
      const fallback = session.voice_engine?.fallback_reason
      if (fallback) this.showError(`On OpenAI Realtime: ${fallback}.`)
      this.usage = new LiveUsageReporter(`/live_conversations/${call.conversationId}/usage`, "openai_realtime")
      this.gated = ["wake_word", "dynamic"].includes(session.listening)

      this.mic = await navigator.mediaDevices.getUserMedia({ audio: true })
      if (mine !== this.generation) { this.stopMic(); return }
      this.cues.unlock()
      if (muted) this.toggleMute()

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
      channel.onopen = () => {
        if (mine !== this.generation) return
        this.setState("listening")
        this.watchCurrent(mine)
        if (moved) this.speakFirst()
      }
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

  // The `gpt_live_claude` engine: the same dock, mic and audio element, with
  // GptLiveCall speaking GPT-Live's protocol and Claude behind it.
  async startGptLive(call, session, mine, muted) {
    this.mic = await navigator.mediaDevices.getUserMedia({ audio: true })
    if (mine !== this.generation) { this.stopMic(); return }
    this.cues.unlock()
    if (muted) this.toggleMute()
    this.audio = this.audio || document.createElement("audio")
    this.audio.autoplay = true
    if (session.voice_engine?.warning) this.showError(session.voice_engine.warning)
    this.gptLive = new GptLiveCall({
      call,
      mic: this.mic,
      audio: this.audio,
      onState: (state) => { if (mine === this.generation && this.state !== state) this.setState(state) },
      onError: (message) => { if (mine === this.generation) this.showError(message) },
      onEnded: ({ dropped }) => {
        if (mine !== this.generation) return
        this.gptLive = null
        if (dropped) this.showError("The call dropped.")
        this.hangUp({ keepError: dropped || this.errorShown, dropped })
      }
    })
    await this.gptLive.start()
    if (mine === this.generation) this.watchCurrent(mine)
  }

  watchCurrent(generation) {
    clearInterval(this.following)
    this.following = setInterval(() => this.followCurrent(generation), FOLLOW_INTERVAL_MS)
  }

  // Live Mode moved while this call was on the old conversation. A failed look
  // changes nothing: the next one will do.
  async followCurrent(generation) {
    // Hanging up: the call is over in a moment, wherever Live Mode has gone.
    if (this.hangingUp) return
    try {
      const response = await fetch("/live/current.json", { credentials: "same-origin", headers: { Accept: "application/json" } })
      if (!response.ok || generation !== this.generation) return
      const { current_id: current, voice } = await response.json()
      if (generation !== this.generation || !current || String(current) === String(this.call?.conversationId)) return
      if (voice === false) {
        // Somebody chose to type there. A call must not turn voice on over them.
        this.showError("The call ended: Live Mode moved to a typed conversation.")
        this.hangUp({ keepError: true })
        return
      }
      this.reattach(current)
    } catch (_error) {
      // Next time.
    }
  }

  // Reconnect onto `id`: the same dock, the same mute, with no hang-up sound.
  reattach(id) {
    const muted = this.muted
    this.hangUp({ quiet: true })
    const base = `/live_conversations/${id}`
    this.start({
      conversationId: id,
      conversationUrl: base,
      clientSecretUrl: `${base}/client_secret`,
      toolCallsUrl: `${base}/tool_calls`,
      sessionUpdateUrl: `${base}/session_update`,
      turnsUrl: `${base}/turns`
    }, { moved: true, muted })
  }

  speakFirst() {
    this.send({
      type: "conversation.item.create",
      item: { type: "message", role: "user", content: [{ type: "input_text", text: SWITCHED_OPENING }] }
    })
    this.pendingResponse = true
    this.sendPendingResponse()
  }

  // The conversation may still be reading its AGENTS.md (409); give it a moment.
  async mintSecret(url) {
    for (let attempt = 0; attempt < 6; attempt++) {
      const response = await this.post(url, { listening_modes: 1, engines: ["gpt_live_claude"] })
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
        this.stoppedAt = performance.now()
        this.cues.perform(this.director.personStopped())
        if (!this.gated && this.state !== "speaking") {
          this.setState("thinking")
          this.cues.perform(this.director.heardPerson())
        }
        break
      case "response.created":
        this.responseActive = true
        this.requested = false
        this.spoke = false
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
        if (this.stoppedAt) {
          this.usage?.latency(performance.now() - this.stoppedAt)
          this.stoppedAt = null
        }
        this.spoke = true
        if (this.state !== "speaking") this.setState("speaking")
        break
      case "response.function_call_arguments.done":
        this.relayToolCall(event, generation)
        break
      case "response.done": {
        const tokens = realtimeUsage(event.response?.usage)
        if (tokens) this.usage?.add("voice_tokens", { ...tokens, details: { status: event.response?.status || "" } })
        this.responseActive = false
        this.finishResponse(event.response, generation)
        this.hangUpOnceSaid()
        break
      }
      // What the person hears, not what OpenAI has sent: a reply sounds on well
      // after its response.done.
      case "output_audio_buffer.started":
        this.replySounding = true
        break
      case "output_audio_buffer.stopped":
      case "output_audio_buffer.cleared":
        this.replySounding = false
        this.hangUpOnceSaid()
        break
      case "conversation.item.input_audio_transcription.completed":
        if (event.usage?.type === "tokens") {
          this.usage?.add("transcription", { input_tokens: event.usage.input_tokens || 0, output_tokens: event.usage.output_tokens || 0 })
        }
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
    const pending = this.post(this.call.toolCallsUrl, { call_id: callId, name, arguments: args, listening_modes: 1, reattaches: 1, hangs_up: 1 })
      .then(async (response) => {
        const body = await response.json().catch(() => ({}))
        if (generation !== this.generation) return
        // This session is over: nothing more goes down it.
        if (response.ok && body.switched_to) {
          // The person also asked to hang up: that wins, and the call ends here.
          if (this.hangingUp) {
            this.hangUp()
          } else {
            this.reattach(body.switched_to.id)
          }
          return
        }
        const output = response.ok ? body.output : `Zimmer could not run ${name}: ${body.error || response.status}`
        this.send({ type: "conversation.item.create", item: { type: "function_call_output", call_id: callId, output: String(output ?? "") } })
        if (response.ok && body.hang_up) {
          this.toolFinished(false)
          this.hangUpWhenSaid(generation)
          return
        }
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

  // The person asked to hang up: ask for nothing more, and end the call once
  // the goodbye has been said and heard.
  hangUpWhenSaid(generation) {
    this.hangingUp = true
    clearTimeout(this.hangUpTimer)
    this.hangUpTimer = setTimeout(() => {
      if (generation === this.generation && this.hangingUp) this.hangUp()
    }, HANG_UP_GRACE_MS)
    this.hangUpOnceSaid()
  }

  hangUpOnceSaid() {
    if (this.hangingUp && !this.responseActive && !this.replySounding) this.hangUp()
  }

  toolFinished(failed) {
    this.runningTools -= 1
    this.cues.perform(this.director.toolsRunning(this.runningTools))
    if (failed) this.cues.perform(this.director.actionFailed())
  }

  // A response that asked for tools ends before their results exist; once every
  // result is in, ask for the response that uses them — exactly once.
  //
  // Not for a response the user talked over: that one was cancelled, and a
  // function call it was cut off in the middle of is not one to run. A response
  // cut short (incomplete, by the output cap or OpenAI's content filter) is not
  // that: nobody talked over it, so its calls run and get their follow-up, and
  // the model hears what came of them. Zimmer refuses arguments that were cut
  // off, which is what tells the model to try again or say so. Three in a row
  // stops asking and says so, rather than retrying unheard for ever.
  //
  // When the output cap cost a tool call, or a reply nobody heard a word of, the
  // call drops the cap for the rest of its life, so the same cap cannot do it
  // twice. A reply nobody heard is asked for again. A spoken reply the cap cut
  // off just ends: that is the cap.
  //
  // And never on top of a response already running — with server VAD the user
  // speaking mid-tool starts one — so in that case the request waits for it to
  // finish (sendPendingResponse).
  async finishResponse(response, generation) {
    const status = response?.status
    const calls = (response?.output || []).filter((item) => item.type === "function_call")
    const cut = status === "incomplete"
    if (status === "completed") {
      this.cutsInARow = 0
    } else if (cut && calls.length > 0) {
      this.cutsInARow = (this.cutsInARow || 0) + 1
    }
    const lifting = cut && !this.capLifted && response.status_details?.reason === "max_output_tokens" &&
      (calls.length > 0 || !this.spoke)
    if (lifting) {
      this.capLifted = true
      this.sendSession({ type: "realtime" })
    }
    this.sendPendingResponse()
    if (status && status !== "completed" && status !== "cancelled") this.cues.perform(this.director.actionFailed())
    if (status && status !== "completed" && !cut) {
      if (!this.requested && this.state !== "idle") this.setState("listening")
      return
    }
    const callIds = calls.map((item) => item.call_id)
    if (callIds.length === 0) {
      if (lifting) {
        // The cap ran out before a word was said: nothing was heard, so ask
        // again without it.
        this.pendingResponse = true
        this.sendPendingResponse()
      } else if (this.state !== "idle") {
        this.setState("listening")
      }
      return
    }
    callIds.forEach((callId) => {
      if (!this.pendingCalls.has(callId)) {
        const item = response.output.find((entry) => entry.call_id === callId)
        // Zimmer reads blank arguments as none at all, which is a call the model
        // did not finish making. `{` is what it refuses.
        const args = item.arguments || (cut ? "{" : item.arguments)
        this.relayToolCall({ call_id: callId, name: item.name, arguments: args }, generation)
      }
    })
    await Promise.all(callIds.map((callId) => this.pendingCalls.get(callId)))
    callIds.forEach((callId) => this.pendingCalls.delete(callId))
    if (generation !== this.generation) return
    this.pendingResponse = true
    this.sendPendingResponse()
  }

  sendPendingResponse() {
    if (!this.pendingResponse || this.responseActive || this.requested || this.hangingUp) return
    this.pendingResponse = false
    if (this.cutsInARow >= 3) {
      this.cutsInARow = 0
      this.showError("OpenAI kept cutting that reply short.")
      this.setState("listening")
      return
    }
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

  // Zimmer's session names the stored output cap: a call that lifted it keeps
  // it lifted.
  sendSession(session) {
    this.send({ type: "session.update", session: this.capLifted ? { ...session, max_output_tokens: "inf" } : session })
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

  hangUp({ keepError = false, dropped = false, quiet = false } = {}) {
    this.generation = (this.generation || 0) + 1
    this.usage?.flush({ keepalive: true })
    this.usage = null
    this.stoppedAt = null
    // A GPT-Live call closes its own session first, so its final usage is read.
    const gptLive = this.gptLive
    this.gptLive = null
    gptLive?.end()
    clearInterval(this.following)
    if (!quiet) this.cues.perform(dropped ? this.director.dropped() : this.director.hungUp())
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
    this.capLifted = false
    this.cutsInARow = 0
    this.hangingUp = false
    this.replySounding = false
    clearTimeout(this.hangUpTimer)
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
