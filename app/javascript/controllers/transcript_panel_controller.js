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
//
// Both have to wait for the rows to exist. The panel's contents are a
// <turbo-frame loading="lazy"> that only fetches once the disclosure opens (a
// frame inside a closed <details> has no layout, so Turbo leaves it alone), so
// at the moment of opening there is nothing to scroll to yet — measuring or
// querying then would land on the skeleton. `whenLoaded` is the one place that
// waits, and both paths go through it.
export default class extends Controller {
  static targets = ["body", "frame"]

  // Whether this panel's rows are deferred into a frame at all.
  //
  // Read from the controller element rather than inferred from the frame target
  // being present, and that distinction is the whole reason the value exists:
  // Stimulus connects a controller as soon as its element is parsed, which on a
  // streamed document is BEFORE the frame nested inside it exists. Asking
  // `hasFrameTarget` at connect() therefore answers "no frame" for a panel that
  // very much has one, and every caller waiting on the load would fire
  // immediately against an empty panel.
  static values = { deferred: Boolean }

  // The only fragment shape this controller acts on. Anything else — including
  // an agent-written link that happens to start with "#message-" but is not a
  // valid selector — is ignored rather than thrown at querySelector.
  static MESSAGE_FRAGMENT = /^#message-\d+$/

  connect() {
    // Callbacks waiting for the frame. Flushed by frameLoaded().
    this.pending = []

    this.boundHandleHash = this.handleHash.bind(this)
    window.addEventListener("hashchange", this.boundHandleHash)

    // Listened for on the <details>, not on the frame: turbo:frame-load bubbles,
    // and the disclosure is in the DOM before the frame is. Containment is also
    // the right scope — the only frame inside this panel is this panel's own.
    this.boundFrameLoaded = this.frameLoaded.bind(this)
    this.element.addEventListener("turbo:frame-load", this.boundFrameLoaded)

    // Handles the case where the page was loaded with #message-N already set.
    //
    // Skipped inside the dashboard drawer: the drawer does not own the URL, so
    // a hash left over from a previous session's panel would open THIS
    // session's transcript and ring whatever row happens to hold that index.
    if (!this.inDrawer) this.handleHash()
  }

  disconnect() {
    window.removeEventListener("hashchange", this.boundHandleHash)
    this.element.removeEventListener("turbo:frame-load", this.boundFrameLoaded)
  }

  get inDrawer() {
    return this.element.closest("[data-scroll-container]") !== null
  }

  toggled() {
    // Closing clears the reveal: the next open is the reader's own, and wants
    // the newest row again.
    if (!this.element.open) {
      this.revealing = false
      return
    }

    // A reveal opened this panel to land on one specific message, and the toggle
    // it caused must not then scroll past it to the newest row. Cleared on
    // close rather than once the reveal has run, because a frame that was
    // already loaded reveals synchronously — before this toggle is delivered.
    if (this.revealing) return

    this.whenLoaded(() => {
      // Let the browser lay the freshly-shown content out before measuring it.
      requestAnimationFrame(() => this.scrollToBottom())
    })
  }

  handleHash() {
    this.reveal(window.location.hash)
  }

  // Run `callback` once the panel's rows are in the DOM.
  //
  // Immediately when they already are — either the frame has loaded, or this
  // panel does not defer them at all (a caller that renders the rows inline).
  // Otherwise queued until the frame lands, which opening the disclosure is what
  // triggers.
  whenLoaded(callback) {
    if (this.loaded) {
      callback()
      return
    }

    this.pending.push(callback)
  }

  // True when the rows are in the DOM to be measured or queried.
  get loaded() {
    if (!this.deferredValue) return true

    return this.hasFrameTarget && this.frameTarget.hasAttribute("complete")
  }

  // Every queued caller runs, rather than one displacing another: a toggle and a
  // reveal can be waiting on the same load, and both have work to do.
  frameLoaded() {
    const waiting = this.pending
    this.pending = []
    waiting.forEach((callback) => callback())
  }

  // Open the panel and bring the anchored message into view. Called on hash
  // change, and directly by the status-panel controller so a click on a
  // same-page anchor never has to go through the URL.
  // Opening comes BEFORE looking for the row, which is the opposite of the old
  // order and the point of it: the row does not exist until the panel's frame
  // has loaded, and the frame does not load until the panel is open. A fragment
  // that matches no row once the panel is loaded (a stale #message-N, an index
  // past the tail) leaves the panel open and does nothing further, which is what
  // it did before as well.
  reveal(fragment) {
    if (!this.constructor.MESSAGE_FRAGMENT.test(fragment || "")) return

    // Set before opening: the toggle this causes reads it to stand down.
    this.revealing = true
    this.element.open = true

    this.whenLoaded(() => {
      const target = this.element.querySelector(fragment)
      if (!target) return

      requestAnimationFrame(() => {
        target.scrollIntoView({ block: "center" })
        target.classList.add("ring-2", "ring-indigo-400", "ring-inset")
        setTimeout(() => target.classList.remove("ring-2", "ring-indigo-400", "ring-inset"), 2500)
      })
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
