import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"
import { csrfHeaders } from "lib/csrf"

// The single-thread page of a live conversation (live_conversations/show).
// Keeps the thread scrolled to its newest turn and makes Enter send while it is
// typed. Enable voice switches the conversation to voice and starts the call;
// Type instead hangs up and switches back. The call itself belongs to the dock
// in the layout (live_voice_controller), which owns it so navigation cannot
// drop it; this page hands it Talk / Hang up.
export default class extends Controller {
  static targets = ["turns", "composer", "input", "talk", "talkLabel"]

  connect() {
    this.scrollToEnd()
    this.observer = new MutationObserver(() => {
      this.turnsTarget.querySelector("[data-live-empty]")?.remove()
      this.keepInOrder()
      this.scrollToEnd()
    })
    if (this.hasTurnsTarget) this.observer.observe(this.turnsTarget, { childList: true })
    this.watchMode()

    this.onVoiceState = (event) => this.renderVoiceState(event.detail)
    window.addEventListener("live-voice:state", this.onVoiceState)
    window.dispatchEvent(new CustomEvent("live-voice:query"))
    this.watchPreparing()
  }

  // Preparing takes a second or two, often less than the cable subscription
  // takes to connect, so the broadcast that flips it to active can arrive
  // before anyone is listening. Re-render until it has flipped.
  // Bounded, and never at the cost of a message being typed: a re-render would
  // empty the composer, so while it holds text this only waits. The page says
  // what is happening either way, and a stuck prepare fails the conversation
  // server-side (LiveConversationPrepareJob), which the next look picks up.
  watchPreparing(attempt = 0) {
    if (attempt >= 20) return
    this.preparingTimer = setTimeout(() => {
      const header = this.element.querySelector("[data-live-conversation-status]")
      if (header?.dataset.liveConversationStatus !== "preparing") return
      if (this.hasInputTarget && this.inputTarget.value.trim() !== "") {
        this.watchPreparing(attempt + 1)
        return
      }
      Turbo.visit(window.location.href, { action: "replace" })
    }, 1500 + attempt * 500)
  }

  // The header is broadcast-replaced when the mode changes, which may have been
  // another device turning voice on or off. The composer or call controls
  // below it are not (a broadcast form would carry a dead CSRF token), so a
  // header in a different mode than the page means re-render — unless a
  // message is being typed, which a re-render would throw away.
  watchMode() {
    const header = this.element.querySelector("[data-live-conversation-mode]")
    if (!header?.parentElement) return
    this.modeObserver = new MutationObserver(() => {
      const mode = this.element.querySelector("[data-live-conversation-mode]")?.dataset.liveConversationMode
      if (!mode || mode === this.element.dataset.liveConversationMode || this.switching) return
      if (this.hasInputTarget && this.inputTarget.value.trim() !== "") return
      Turbo.visit(window.location.href, { action: "replace" })
    })
    this.modeObserver.observe(header.parentElement, { childList: true })
  }

  disconnect() {
    clearTimeout(this.preparingTimer)
    this.observer?.disconnect()
    this.modeObserver?.disconnect()
    window.removeEventListener("live-voice:state", this.onVoiceState)
  }

  // Each turn is broadcast as its own append, and two appends can land in the
  // other order (a tool turn and the answer that follows it are written
  // milliseconds apart). The thread is ordered by turn id, so restore that.
  keepInOrder() {
    const turns = [...this.turnsTarget.querySelectorAll(":scope > [data-live-turn-id]")]
    const ids = turns.map((el) => Number(el.dataset.liveTurnId))
    if (ids.every((id, i) => i === 0 || ids[i - 1] < id)) return
    turns.sort((a, b) => Number(a.dataset.liveTurnId) - Number(b.dataset.liveTurnId))
      .forEach((el) => this.turnsTarget.appendChild(el))
  }

  scrollToEnd() {
    requestAnimationFrame(() => window.scrollTo({ top: document.body.scrollHeight }))
  }

  submitOnEnter(event) {
    if (event.key !== "Enter" || event.shiftKey || event.isComposing) return
    event.preventDefault()
    if (this.inputTarget.value.trim() === "") return
    this.composerTarget.requestSubmit()
  }

  reset(event) {
    if (!event.detail.success) return
    this.composerTarget.reset()
    this.inputTarget.focus()
  }

  talk() {
    if (this.talkTarget.dataset.liveVoiceActive === "true") {
      this.hangUp()
      return
    }
    this.startCall()
  }

  startCall() {
    const data = this.element.dataset
    window.dispatchEvent(new CustomEvent("live-voice:start", {
      detail: {
        conversationId: data.liveConversationId,
        conversationUrl: data.conversationUrl,
        clientSecretUrl: data.clientSecretUrl,
        toolCallsUrl: data.toolCallsUrl,
        sessionUpdateUrl: data.sessionUpdateUrl,
        turnsUrl: data.turnsUrl
      }
    }))
  }

  // One press: the server switches first, because the secret the call is
  // opened with is only minted for a conversation in voice; then the call
  // starts, and the page re-renders with the call controls. The call lives in
  // the dock, so the re-render does not touch it.
  async enableVoice(event) {
    const button = event.currentTarget
    button.disabled = true
    if (!(await this.switchMode("voice"))) {
      button.disabled = false
      return
    }
    this.startCall()
    Turbo.visit(window.location.href, { action: "replace" })
  }

  async disableVoice(event) {
    const button = event.currentTarget
    button.disabled = true
    this.hangUp()
    if (!(await this.switchMode("text"))) {
      button.disabled = false
      return
    }
    Turbo.visit(window.location.href, { action: "replace" })
  }

  async switchMode(mode) {
    this.switching = true
    try {
      const response = await fetch(this.element.dataset.modeUrl, {
        method: "POST",
        credentials: "same-origin",
        headers: csrfHeaders({ Accept: "application/json" }),
        body: JSON.stringify({ mode })
      })
      if (response.ok) return true
      const body = await response.json().catch(() => ({}))
      window.alert(body.error || `Zimmer refused the switch (${response.status}).`)
    } catch (error) {
      window.alert(`Zimmer could not be reached: ${error.message}`)
    } finally {
      this.switching = false
    }
    return false
  }

  // Ending this conversation (or replacing it with a new one) ends its call —
  // and only its call: the dock ignores a hang-up for another conversation.
  hangUp() {
    window.dispatchEvent(new CustomEvent("live-voice:hangup", { detail: { conversationId: this.element.dataset.liveConversationId } }))
  }

  renderVoiceState({ conversationId, state }) {
    if (!this.hasTalkTarget) return
    const mine = String(conversationId) === this.element.dataset.liveConversationId
    const active = mine && state !== "idle"
    this.talkTarget.dataset.liveVoiceActive = active ? "true" : "false"
    if (this.hasTalkLabelTarget) {
      this.talkLabelTarget.textContent = active ? (state === "connecting" ? "Connecting…" : "Hang up") : "Talk"
    }
    this.talkTarget.classList.toggle("bg-red-600", active)
    this.talkTarget.classList.toggle("hover:bg-red-700", active)
    this.talkTarget.classList.toggle("bg-indigo-600", !active)
    this.talkTarget.classList.toggle("hover:bg-indigo-700", !active)
  }
}
