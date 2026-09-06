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
  static targets = ["body", "frame", "streamed"]

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

  // The frame can arrive after this controller does — Stimulus connects on the
  // element as soon as it is parsed, before the frame nested inside it exists —
  // and a panel that was rendered ALREADY OPEN fires no toggle for #toggled to
  // catch. `transcript=open` is exactly that page: the log-level filter's
  // re-fetch asks for the disclosure open so the reader gets the panel back at
  // the level they picked, and a reader on a phone is looking at a panel that
  // has scrolled well down the page. Without this the frame stays lazy there,
  // which is the whole defect #loadFrame exists to remove.
  frameTargetConnected() {
    if (this.element.open) this.loadFrame()
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
    // the newest row again. It also drops anything still waiting on the frame —
    // a scroll-to-bottom that lands after the reader has closed the panel jumps
    // a page they are no longer looking at.
    if (!this.element.open) {
      this.revealing = false
      this.pending = []
      return
    }

    // Ahead of the `revealing` return below, not after it: a reveal that opened
    // a closed panel is still an opening, and it has nothing to scroll to until
    // the rows are fetched.
    this.loadFrame()

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

  // Make opening the disclosure fetch the rows.
  //
  // `loading="lazy"` reads as "fetch once it is shown", and it is not: Turbo
  // watches the frame with an IntersectionObserver and fetches when it APPEARS
  // IN THE VIEWPORT. Layout is only half of that. A panel opened while it sits
  // below the fold gains layout and is still never fetched, so it holds its
  // skeleton and every caller queued on `whenLoaded` waits on a load that has
  // nothing coming.
  //
  // A reader clicking the summary is looking at it, so the frame lands on
  // screen and the distinction almost never shows. The two paths where it does
  // are both openings the reader did not scroll to: a `#message-N` link opened
  // cold, where `reveal` opens the panel under a viewport still parked at the
  // top of the page, and the system suite, which opens every panel by script
  // from wherever the page happens to be. The second is what failed CI run
  // 34060027053 — two LostElicitationBannerTest cases, at an 800x600 window,
  // green at 1400x900, on a commit that touched neither the view nor the test.
  //
  // Eager keeps everything lazy was for. The frame is still untouched for as
  // long as the disclosure is closed, which is the whole point of deferring the
  // panel (see sessions_controller#transcript_panel); this only stops the fetch
  // being contingent on scroll position once the reader has asked for it.
  // Called from three places, so it has to be safe to call twice — and
  // `setAttribute` is not, even with the value the attribute already holds.
  // There is no same-value short circuit: the DOM runs its attribute-change
  // steps regardless, Turbo's `attributeChangedCallback` re-enters
  // `loadingStyleChanged`, and `#loadSourceURL` is guarded only by `complete`.
  // A second call while the first fetch is in flight therefore CANCELS it and
  // issues another — a second GET of the most expensive response the session
  // screen has, after the server has already built the first. Reading the
  // attribute back is what makes the second call the no-op it reads as.
  loadFrame() {
    if (!this.deferredValue || !this.hasFrameTarget) return
    if (this.frameTarget.getAttribute("loading") === "eager") return

    this.frameTarget.setAttribute("loading", "eager")
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
  // reveal can be waiting on the same load, and both have work to do. Dropping
  // the streamed duplicates comes first, so a caller that measures the panel
  // measures its final height.
  frameLoaded() {
    this.dropStreamedDuplicates()

    const waiting = this.pending
    this.pending = []
    waiting.forEach((callback) => callback())
  }

  // Drop rows from the append target that the frame has just brought its own
  // copy of.
  //
  // Both containers are live at once and neither dedupes against the other:
  // Turbo's `append` only compares direct children of its target, and a frame
  // swap does no id reconciliation at all. So a message broadcast into the
  // append target while the panel was closed is rendered a second time by the
  // frame's tail — same row, same id, twice on screen.
  //
  // Keyed on the id being present INSIDE the frame, which is what makes the
  // in-flight case safe: a row broadcast after the server rendered its response
  // is not in the batch, so it is not a duplicate and stays where it landed.
  dropStreamedDuplicates() {
    if (!this.hasStreamedTarget || !this.hasFrameTarget) return

    for (const row of Array.from(this.streamedTarget.children)) {
      if (row.id && this.frameTarget.querySelector(`#${CSS.escape(row.id)}`)) row.remove()
    }
  }

  // Open the panel and bring the anchored message into view. Called on hash
  // change, and directly by the status-panel controller so a click on a
  // same-page anchor never has to go through the URL.
  //
  // Opening precedes looking for the row, and has to: the row does not exist
  // until the panel's frame has loaded, and the frame does not load until the
  // panel is open. A fragment matching no row once it has (a stale #message-N,
  // an index older than the tail) therefore leaves the panel open — so it lands
  // on the newest row instead, which is the same place opening the panel by hand
  // lands, rather than at the top of a hundred rows the reader did not ask for.
  reveal(fragment) {
    if (!this.constructor.MESSAGE_FRAGMENT.test(fragment || "")) return

    // Set before opening: the toggle this causes reads it to stand down.
    this.revealing = true
    this.element.open = true

    // Also here, and not only in #toggled: a panel that was ALREADY open fires
    // no toggle, so the reveal would otherwise queue behind a frame that is
    // still waiting to be scrolled to.
    this.loadFrame()

    this.whenLoaded(() => {
      const target = this.element.querySelector(fragment)
      if (!target) {
        requestAnimationFrame(() => this.scrollToBottom())
        return
      }

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
