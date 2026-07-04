import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="pull-to-refresh"
// Implements pull-to-refresh gesture across the whole scrollable surface,
// mirroring the feel of native iOS / Twitter / Instagram refresh:
//   - whole page is the touch capture area (not a thin header strip)
//   - only activates when the page is scrolled to the top, EXCEPT for touches
//     that start on a `data-pull-to-refresh-target="trigger"` element (the
//     sticky header on session detail pages), which always commit regardless
//     of scrollY so users can refresh from deep in a long transcript
//   - threshold ~70px of indicator travel before commit, with 0.5 resistance
//     gives ~140px of finger travel — a deliberate pull, not a flick
//   - haptic feedback on threshold crossing on devices that support it
export default class extends Controller {
  static values = {
    // Indicator travel distance (after resistance) at which the pull commits.
    // ~70px commit + 0.5 resistance = ~140px finger travel, matching Twitter/iOS.
    threshold: { type: Number, default: 70 },
    // Maximum indicator travel — finger can pull further but the indicator
    // stops growing, producing a rubber-band-like ceiling.
    maxPull: { type: Number, default: 150 },
    // Resistance applied to raw finger movement when computing indicator
    // travel — lower = more resistance = more deliberate pull.
    resistance: { type: Number, default: 0.5 }
  }

  static targets = ["indicator", "trigger"]

  connect() {
    this.isRefreshing = false
    this.isPulling = false
    this.pullStartY = 0
    this.pullStartX = 0
    this.currentPullDistance = 0
    this.thresholdCrossed = false
    this.refreshTimeout = null
    this.gestureFromTrigger = false

    // Only enable on touch devices
    if (!this.isTouchDevice()) {
      return
    }

    // Bind handlers
    this.boundTouchStart = this.handleTouchStart.bind(this)
    this.boundTouchMove = this.handleTouchMove.bind(this)
    this.boundTouchEnd = this.handleTouchEnd.bind(this)
    this.boundTouchCancel = this.handleTouchCancel.bind(this)

    // Add listeners with passive: false to allow preventDefault on touchmove
    this.element.addEventListener("touchstart", this.boundTouchStart, { passive: true })
    this.element.addEventListener("touchmove", this.boundTouchMove, { passive: false })
    this.element.addEventListener("touchend", this.boundTouchEnd, { passive: true })
    this.element.addEventListener("touchcancel", this.boundTouchCancel, { passive: true })

    // Create the indicator element if not already present
    this.createIndicator()
  }

  disconnect() {
    if (this.refreshTimeout) {
      clearTimeout(this.refreshTimeout)
      this.refreshTimeout = null
    }

    if (this.hasIndicatorTarget) {
      this.indicatorTarget.remove()
    }

    if (this.boundTouchStart) {
      this.element.removeEventListener("touchstart", this.boundTouchStart)
      this.element.removeEventListener("touchmove", this.boundTouchMove)
      this.element.removeEventListener("touchend", this.boundTouchEnd)
      this.element.removeEventListener("touchcancel", this.boundTouchCancel)
    }
  }

  isTouchDevice() {
    return "ontouchstart" in window || navigator.maxTouchPoints > 0
  }

  touchStartedOnTrigger(target) {
    if (!this.hasTriggerTarget || !target) return false
    return this.triggerTargets.some(trigger => trigger.contains(target))
  }

  createIndicator() {
    if (this.hasIndicatorTarget) {
      return
    }

    const indicator = document.createElement("div")
    indicator.dataset.pullToRefreshTarget = "indicator"
    indicator.className = "pull-to-refresh-indicator"
    indicator.setAttribute("role", "status")
    indicator.setAttribute("aria-live", "polite")
    indicator.setAttribute("aria-hidden", "true")
    indicator.innerHTML = `
      <div class="pull-to-refresh-content">
        <svg class="pull-to-refresh-arrow" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" aria-hidden="true">
          <path fill-rule="evenodd" d="M5.293 9.707a1 1 0 010-1.414l4-4a1 1 0 011.414 0l4 4a1 1 0 01-1.414 1.414L11 7.414V15a1 1 0 11-2 0V7.414L6.707 9.707a1 1 0 01-1.414 0z" clip-rule="evenodd" />
        </svg>
        <svg class="pull-to-refresh-spinner hidden" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" aria-hidden="true">
          <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
          <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
        </svg>
        <span class="pull-to-refresh-text">Pull to refresh</span>
      </div>
    `

    this.element.insertBefore(indicator, this.element.firstChild)
  }

  handleTouchStart(event) {
    if (this.isRefreshing) {
      return
    }

    // Allow the gesture when the touch lands on a trigger target (sticky
    // header) regardless of scroll position — otherwise require scrollY === 0.
    const fromTrigger = this.touchStartedOnTrigger(event.target)
    if (!fromTrigger && window.scrollY !== 0) {
      return
    }

    this.pullStartY = event.touches[0].clientY
    this.pullStartX = event.touches[0].clientX
    this.gestureFromTrigger = fromTrigger
    this.isPulling = false
    this.thresholdCrossed = false
  }

  handleTouchMove(event) {
    if (this.pullStartY === 0 || this.isRefreshing) {
      return
    }

    // Re-check the scroll guard only for body gestures (a user can scroll the
    // timeline before the touchmove fires). Header-trigger gestures bypass
    // this so they work mid-transcript.
    if (!this.gestureFromTrigger && window.scrollY > 0) {
      this.resetPull()
      return
    }

    const currentY = event.touches[0].clientY
    const currentX = event.touches[0].clientX
    const pullDistance = currentY - this.pullStartY
    const horizontalDistance = Math.abs(currentX - this.pullStartX)

    // Cancel if the user is clearly swiping horizontally (carousel etc).
    // Only matters before the pull has committed.
    if (!this.isPulling && horizontalDistance > Math.abs(pullDistance) * 2) {
      this.resetPull()
      return
    }

    // Only handle downward pulls
    if (pullDistance <= 0) {
      this.resetPull()
      return
    }

    event.preventDefault()
    this.isPulling = true

    this.currentPullDistance = Math.min(pullDistance * this.resistanceValue, this.maxPullValue)

    const wasCrossed = this.thresholdCrossed
    this.thresholdCrossed = this.currentPullDistance >= this.thresholdValue

    // Haptic tap on threshold crossing — feels like Twitter/iOS commit point.
    if (!wasCrossed && this.thresholdCrossed && navigator.vibrate) {
      navigator.vibrate(10)
    }

    this.updateIndicator()
  }

  handleTouchEnd() {
    if (!this.isPulling || this.isRefreshing) {
      this.resetPull()
      return
    }

    if (this.currentPullDistance >= this.thresholdValue) {
      this.triggerRefresh()
    } else {
      this.resetPull()
    }
  }

  handleTouchCancel() {
    this.resetPull()
  }

  updateIndicator() {
    if (!this.hasIndicatorTarget) return

    const indicator = this.indicatorTarget
    const progress = Math.min(this.currentPullDistance / this.thresholdValue, 1)

    // Float the indicator over the viewport when the gesture started on the
    // sticky-header trigger and the page is scrolled — the normal-flow
    // indicator at the top of the document would be invisible above the fold.
    const shouldFloat = this.gestureFromTrigger && window.scrollY > 0
    indicator.classList.toggle("pull-to-refresh-floating", shouldFloat)

    indicator.style.height = `${this.currentPullDistance}px`
    indicator.style.opacity = progress

    indicator.setAttribute("aria-hidden", progress < 0.1 ? "true" : "false")

    if (this.thresholdCrossed) {
      indicator.classList.add("pull-to-refresh-ready")
    } else {
      indicator.classList.remove("pull-to-refresh-ready")
    }

    const arrow = indicator.querySelector(".pull-to-refresh-arrow")
    if (arrow) {
      const rotation = progress >= 1 ? 180 : progress * 180
      arrow.style.transform = `rotate(${rotation}deg)`
    }

    const text = indicator.querySelector(".pull-to-refresh-text")
    if (text) {
      text.textContent = progress >= 1 ? "Release to refresh" : "Pull to refresh"
    }
  }

  async triggerRefresh() {
    this.isRefreshing = true

    if (this.hasIndicatorTarget) {
      const indicator = this.indicatorTarget
      const arrow = indicator.querySelector(".pull-to-refresh-arrow")
      const spinner = indicator.querySelector(".pull-to-refresh-spinner")
      const text = indicator.querySelector(".pull-to-refresh-text")

      if (arrow) arrow.classList.add("hidden")
      if (spinner) spinner.classList.remove("hidden")
      if (text) text.textContent = "Refreshing..."

      indicator.style.height = `${this.thresholdValue}px`
      indicator.style.opacity = "1"
      indicator.setAttribute("aria-hidden", "false")
      indicator.classList.add("pull-to-refresh-ready")
    }

    const refreshEvent = new CustomEvent("pull-to-refresh:refresh", {
      bubbles: true,
      detail: { controller: this }
    })
    this.element.dispatchEvent(refreshEvent)

    // Turbo.visit re-fetches the page, which also re-establishes any
    // <turbo-cable-stream-source> subscriptions — pull-to-refresh thus doubles
    // as the manual escape hatch for stale Turbo Stream connections.
    if (typeof Turbo !== "undefined") {
      await Turbo.visit(window.location.href, { action: "replace" })
    } else {
      window.location.reload()
    }

    this.refreshTimeout = setTimeout(() => {
      this.completeRefresh()
    }, 500)
  }

  completeRefresh() {
    this.isRefreshing = false
    this.refreshTimeout = null
    this.resetPull()
  }

  resetPull() {
    this.pullStartY = 0
    this.pullStartX = 0
    this.currentPullDistance = 0
    this.isPulling = false
    this.thresholdCrossed = false
    this.gestureFromTrigger = false

    if (this.hasIndicatorTarget) {
      const indicator = this.indicatorTarget
      indicator.style.height = "0"
      indicator.style.opacity = "0"
      indicator.setAttribute("aria-hidden", "true")
      indicator.classList.remove("pull-to-refresh-ready")
      indicator.classList.remove("pull-to-refresh-floating")

      const arrow = indicator.querySelector(".pull-to-refresh-arrow")
      const spinner = indicator.querySelector(".pull-to-refresh-spinner")
      const text = indicator.querySelector(".pull-to-refresh-text")

      if (arrow) {
        arrow.classList.remove("hidden")
        arrow.style.transform = "rotate(0deg)"
      }
      if (spinner) spinner.classList.add("hidden")
      if (text) text.textContent = "Pull to refresh"
    }
  }
}
