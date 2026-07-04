import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="auto-scroll"
// Handles auto-scrolling to bottom when new timeline items arrive via Turbo Streams
export default class extends Controller {
  static targets = ["timelineContainer"]

  connect() {
    // Track connection state to prevent listener setup after disconnect
    this.isConnected = true

    // Track tailing state (whether user is at bottom)
    // Start with true since we expect the session_scroll_controller to scroll to bottom
    this.tailing = true

    // Bind handlers to preserve `this` context for add/remove
    this.boundHandleStreamRender = this.handleStreamRender.bind(this)
    this.boundHandleScroll = this.handleScroll.bind(this)

    // Listen for Turbo Stream updates
    document.addEventListener("turbo:before-stream-render", this.boundHandleStreamRender)

    // Delay setting up scroll listener until after initial scroll to bottom completes.
    // This prevents the scroll handler from firing during the initial scroll and
    // incorrectly setting tailing=false.
    // The session_scroll_controller uses double requestAnimationFrame, so we use triple.
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        requestAnimationFrame(() => {
          // Check connection state to prevent adding listener after disconnect
          if (this.isConnected) {
            // Full-page view scrolls on the window; inside the dashboard drawer the
            // detail is loaded into an overflow-y-auto panel. Attach the scroll
            // listener to whichever element actually scrolls so tailing detection
            // works in both contexts.
            this.activeScrollTarget = this.findScrollContainer() || window
            this.activeScrollTarget.addEventListener("scroll", this.boundHandleScroll)
            this.observeContentGrowth()
          }
        })
      })
    })
  }

  disconnect() {
    this.isConnected = false
    document.removeEventListener("turbo:before-stream-render", this.boundHandleStreamRender)
    if (this.activeScrollTarget) {
      this.activeScrollTarget.removeEventListener("scroll", this.boundHandleScroll)
    }
    if (this.resizeObserver) {
      this.resizeObserver.disconnect()
      this.resizeObserver = null
    }
  }

  handleStreamRender(event) {
    // Check if the stream is for the timeline
    const target = event.target

    if (target && target.getAttribute) {
      const targetId = target.getAttribute("target")

      if (targetId && targetId.includes("_timeline")) {
        // Schedule scroll after the DOM update
        setTimeout(() => {
          if (this.tailing) {
            this.scrollToBottom()
          }
        }, 0)
      }
    }
  }

  // Keep the view pinned to the bottom as appended content settles. A streamed
  // item's final height (timestamps, card padding, markdown/code/tool-call cards,
  // fonts, images) lands after the DOM insertion that handleStreamRender reacts
  // to, so a single scroll-to-bottom stops short of the true bottom. Re-pinning on
  // every size change of the content keeps the newest message fully in view while
  // the user is tailing, matching the full-page session view. Self-regulating: a
  // user who scrolls up clears tailing, so the observer stops re-pinning.
  observeContentGrowth() {
    if (typeof ResizeObserver === "undefined") return
    const content = this.hasTimelineContainerTarget ? this.timelineContainerTarget : this.element
    this.resizeObserver = new ResizeObserver(() => {
      if (this.tailing) {
        this.scrollToBottom()
      }
    })
    this.resizeObserver.observe(content)
  }

  handleScroll() {
    // Guard against disconnected state to prevent errors after controller cleanup
    if (!this.isConnected) return
    this.tailing = this.isAtBottom()
  }

  // Find the element that actually scrolls. Inside the dashboard drawer the detail
  // is loaded into a panel marked with [data-scroll-container]; we locate it by DOM
  // ancestry so detection never races layout (probing computed overflow fails when
  // the container isn't overflowing yet, leaving the listener attached to the wrong
  // element). In the full-page view no such ancestor exists and the window scrolls,
  // so we return null. Caches the result once found.
  findScrollContainer() {
    if (this.scrollContainer) return this.scrollContainer
    const start = this.hasTimelineContainerTarget ? this.timelineContainerTarget : this.element
    const container = start.closest("[data-scroll-container]")
    if (container) {
      this.scrollContainer = container
      return container
    }
    return null
  }

  // Get the height of any fixed bottom elements (running loader, follow-up form)
  getFixedBottomHeight() {
    let height = 0
    // Check for running loader (ID is on wrapper, fixed class is on child)
    const runningLoader = document.querySelector('[id$="_running_loader"] .fixed.bottom-0')
    if (runningLoader) {
      height = Math.max(height, runningLoader.offsetHeight)
    }
    // Check for follow-up form (ID and fixed class are on same element)
    const followUpForm = document.querySelector('[id$="_follow_up_form"].fixed.bottom-0')
    if (followUpForm) {
      height = Math.max(height, followUpForm.offsetHeight)
    }
    return height
  }

  isAtBottom() {
    // Consider "at bottom" if within threshold of the effective bottom
    // Account for any fixed bottom elements that overlap the content
    const threshold = 100
    const fixedBottomHeight = this.getFixedBottomHeight()
    const container = this.findScrollContainer()
    if (container) {
      return container.scrollHeight - container.scrollTop - container.clientHeight < threshold + fixedBottomHeight
    }
    const scrolledToBottom = document.documentElement.scrollHeight - window.scrollY - window.innerHeight < threshold + fixedBottomHeight
    return scrolledToBottom
  }

  scrollToBottom() {
    const container = this.findScrollContainer()
    if (container) {
      container.scrollTop = container.scrollHeight
    } else {
      window.scrollTo({
        top: document.body.scrollHeight,
        behavior: 'instant'
      })
    }
  }
}
