import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["timeline"]

  // How long after connect to keep re-pinning the scroll position to the bottom
  // while the transcript's content settles. Rich content (markdown, code blocks,
  // tool-call cards, fonts, images) reflows taller after the first paint, so a
  // single scroll-to-bottom measured at connect time lands short of the true
  // bottom. We observe size changes and re-pin until layout stabilises.
  static SETTLE_MS = 1000

  // Tolerance (px) for distinguishing a user scroll-up from content growth
  // during the settle window. Content reflowing taller leaves scrollTop
  // unchanged; a user scrolling up lowers it. We stop re-pinning once scrollTop
  // drops more than this below the last pinned position.
  static SETTLE_USER_SCROLL_TOLERANCE_PX = 4

  connect() {
    // Scroll to the bottom of the timeline when the detail renders, then keep it
    // pinned to the bottom while late-laying-out content grows the container.
    this.scrollToBottomAfterRender()
  }

  disconnect() {
    this.stopSettleObserver()
  }

  scrollToBottomAfterRender() {
    if (!this.hasTimelineTarget) return

    // Double requestAnimationFrame ensures the browser has finished the first
    // layout pass after all initial DOM updates from Turbo and Stimulus.
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        this.scrollToBottom()
        this.startSettleObserver()
      })
    })
  }

  scrollToBottom() {
    const container = this.findScrollContainer()
    if (container) {
      container.scrollTop = container.scrollHeight
      return
    }

    // Full-page view: the window/document is the scroller. Only scroll if the
    // timeline extends below the viewport so we don't scroll into blank space.
    const timelineRect = this.timelineTarget.getBoundingClientRect()
    const timelineBottom = window.scrollY + timelineRect.bottom
    if (timelineBottom > window.innerHeight) {
      window.scrollTo({ top: document.body.scrollHeight, behavior: "instant" })
    }
  }

  // Re-pin to the bottom whenever the scrollable content changes size, for a
  // short window after connect. This keeps the initial position glued to the
  // true bottom as content settles, instead of landing wherever the height
  // happened to be at the double-rAF instant.
  startSettleObserver() {
    if (typeof ResizeObserver === "undefined") return

    const container = this.findScrollContainer()
    // In the full-page view there is no inner scroll container; the window
    // scroller already re-clamps to the document bottom, so a settle observer
    // isn't needed there.
    if (!container) return

    // Remember where we last pinned so the observer can tell content growth
    // (scrollTop unchanged) from a user scroll-up (scrollTop lowered).
    this.lastPinnedScrollTop = container.scrollTop
    this.settleObserver = new ResizeObserver(() => {
      // If the user scrolled up since the last pin, stop fighting them and let
      // the observer go idle — don't yank them back to the bottom as content
      // continues to settle. Growth alone never lowers scrollTop, so this only
      // trips on a deliberate scroll-up.
      if (container.scrollTop < this.lastPinnedScrollTop - this.constructor.SETTLE_USER_SCROLL_TOLERANCE_PX) {
        this.stopSettleObserver()
        return
      }
      container.scrollTop = container.scrollHeight
      this.lastPinnedScrollTop = container.scrollTop
    })
    // Observe the content (the element that grows), falling back to the
    // container itself.
    const content = this.hasTimelineTarget ? this.timelineTarget : container
    this.settleObserver.observe(content)

    // Stop re-pinning once layout has had time to settle, so the observer never
    // fights a user who scrolls up after the transcript has loaded.
    this.settleTimeout = setTimeout(() => this.stopSettleObserver(), this.constructor.SETTLE_MS)
  }

  stopSettleObserver() {
    if (this.settleObserver) {
      this.settleObserver.disconnect()
      this.settleObserver = null
    }
    if (this.settleTimeout) {
      clearTimeout(this.settleTimeout)
      this.settleTimeout = null
    }
  }

  // Find the element that actually scrolls. Inside the dashboard drawer the
  // detail is loaded into a panel marked with [data-scroll-container]; we locate
  // it by DOM ancestry so detection never races layout. In the full-page view no
  // such ancestor exists and the window is the scroller, so we return null.
  findScrollContainer() {
    if (this.scrollContainer) return this.scrollContainer
    const container = this.element.closest("[data-scroll-container]")
    if (container) {
      this.scrollContainer = container
      return container
    }
    return null
  }
}
