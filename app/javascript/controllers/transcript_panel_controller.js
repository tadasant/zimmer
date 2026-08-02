import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="transcript-panel"
//
// The transcript is a collapsed <details> in the session detail page's panel
// group. Two things need handling that a bare <details> does not do:
//
// 1. Opening it should land on the newest message. While the panel is closed its
//    contents have no layout, so the auto-scroll controller's pinning has
//    nothing to measure and stops running — a session that streamed messages in
//    the background would open at the very top, thousands of rows from what just
//    happened.
// 2. A link into a specific message (the Status panel's #message-N anchors) must
//    open the panel before the browser can scroll to it. A target inside a
//    closed <details> is not scrollable-to, so without this the link silently
//    does nothing.
export default class extends Controller {
  static targets = ["body"]

  // The only fragment shape this controller acts on. Anything else — including
  // an agent-written link that happens to start with "#message-" but is not a
  // valid selector — is ignored rather than thrown at querySelector.
  static MESSAGE_FRAGMENT = /^#message-\d+$/

  connect() {
    this.boundHandleHash = this.handleHash.bind(this)
    window.addEventListener("hashchange", this.boundHandleHash)

    // Handles the case where the page was loaded with #message-N already set.
    //
    // Skipped inside the dashboard drawer: the drawer does not own the URL, so
    // a hash left over from a previous session's panel would open THIS
    // session's transcript and ring whatever row happens to hold that index.
    if (!this.inDrawer) this.handleHash()
  }

  disconnect() {
    window.removeEventListener("hashchange", this.boundHandleHash)
  }

  get inDrawer() {
    return this.element.closest("[data-scroll-container]") !== null
  }

  toggled() {
    if (!this.element.open) return
    // Let the browser lay the freshly-shown content out before measuring it.
    requestAnimationFrame(() => this.scrollToBottom())
  }

  handleHash() {
    this.reveal(window.location.hash)
  }

  // Open the panel and bring the anchored message into view. Called on hash
  // change, and directly by the status-panel controller so a click on a
  // same-page anchor never has to go through the URL.
  reveal(fragment) {
    if (!this.constructor.MESSAGE_FRAGMENT.test(fragment || "")) return

    const target = this.element.querySelector(fragment)
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
