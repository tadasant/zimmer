import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

// The single-thread page of a live conversation (live_conversations/show).
// Keeps the thread scrolled to its newest turn, makes Enter send in Live Mode,
// and in Live Voice hands Talk / End to the call dock in the layout
// (live_voice_controller), which owns the call so navigation cannot drop it.
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

    this.onVoiceState = (event) => this.renderVoiceState(event.detail)
    window.addEventListener("live-voice:state", this.onVoiceState)
    window.dispatchEvent(new CustomEvent("live-voice:query"))
    this.watchPreparing()
  }

  // Preparing takes a second or two, often less than the cable subscription
  // takes to connect, so the broadcast that flips it to active can arrive
  // before anyone is listening. Re-render until it has flipped.
  watchPreparing() {
    this.preparingTimer = setTimeout(() => {
      const header = this.element.querySelector("[data-live-conversation-status]")
      if (header?.dataset.liveConversationStatus === "preparing") {
        Turbo.visit(window.location.href, { action: "replace" })
      }
    }, 1500)
  }

  disconnect() {
    clearTimeout(this.preparingTimer)
    this.observer?.disconnect()
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
    const button = this.talkTarget
    const live = button.dataset.liveVoiceActive === "true"
    if (live) {
      window.dispatchEvent(new CustomEvent("live-voice:hangup"))
      return
    }
    window.dispatchEvent(new CustomEvent("live-voice:start", {
      detail: {
        conversationId: button.dataset.conversationId,
        conversationUrl: button.dataset.conversationUrl,
        clientSecretUrl: button.dataset.clientSecretUrl,
        toolCallsUrl: button.dataset.toolCallsUrl,
        turnsUrl: button.dataset.turnsUrl
      }
    }))
  }

  // Ending the conversation ends its call too.
  hangUp() {
    window.dispatchEvent(new CustomEvent("live-voice:hangup"))
  }

  renderVoiceState({ conversationId, state }) {
    if (!this.hasTalkTarget) return
    const mine = String(conversationId) === this.talkTarget.dataset.conversationId
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
