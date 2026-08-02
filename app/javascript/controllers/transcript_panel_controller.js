import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="transcript-panel"
//
// The transcript is a collapsed <details> in the session detail page's panel
// group. Two things need handling that a bare <details> does not do:
//
// 1. Opening it should land on the newest message. While the panel is closed
//    its contents have no layout, so the auto-scroll controller's pinning has
//    nothing to measure and stops running — a session that streamed messages in
//    the background would open at the very top, thousands of rows from what just
//    happened.
// 2. A link into a specific message (the Status panel's #message-N anchors) must
//    open the panel before the browser can scroll to it. A target inside a
//    closed <details> is not scrollable-to, so without this the link silently
//    does nothing.
export default class extends Controller {
  static targets = ["body"]

  connect() {
    this.boundHandleHash = this.handleHash.bind(this)
    window.addEventListener("hashchange", this.boundHandleHash)
    // Handles the case where the page was loaded with #message-N already set.
    this.handleHash()
  }

  disconnect() {
    window.removeEventListener("hashchange", this.boundHandleHash)
  }

  toggled() {
    if (!this.element.open) return
    // Let the browser lay the freshly-shown content out before measuring it.
    requestAnimationFrame(() => this.scrollToBottom())
  }

  // Open the panel and bring the anchored message into view. Called on load and
  // on every hash change, so a second click on a #message-N link re-scrolls.
  handleHash() {
    const hash = window.location.hash
    if (!hash || !hash.startsWith("#message-")) return

    const target = this.element.querySelector(hash)
    if (!target) return

    this.element.open = true
    requestAnimationFrame(() => {
      target.scrollIntoView({ block: "center" })
      target.classList.add("ring-2", "ring-indigo-400", "ring-inset")
      setTimeout(() => target.classList.remove("ring-2", "ring-indigo-400", "ring-inset"), 2500)
    })
  }

  scrollToBottom() {
    const container = this.element.closest("[data-scroll-container]")
    if (container) {
      container.scrollTop = container.scrollHeight
    } else {
      window.scrollTo({ top: document.body.scrollHeight, behavior: "instant" })
    }
  }
}
