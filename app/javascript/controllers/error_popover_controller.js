import { Controller } from "@hotwired/stimulus"

// Error popover controller for showing full error text on hover/click
// Usage:
//   <div data-controller="error-popover"
//        data-error-popover-content-value="Full error message here">
//     <span data-error-popover-target="trigger"
//           data-action="click->error-popover#toggle mouseenter->error-popover#showDelayed mouseleave->error-popover#hideDelayed">
//       Truncated error...
//     </span>
//     <div data-error-popover-target="popover" class="hidden">
//       <!-- Popover content rendered here -->
//     </div>
//   </div>
export default class extends Controller {
  static targets = ["trigger", "popover"]
  static values = {
    content: String,
    title: { type: String, default: "Error Details" }
  }

  connect() {
    this.isOpen = false
    this.hoverTimeout = null
    this.handleClickOutside = this.handleClickOutside.bind(this)
    this.handleEscape = this.handleEscape.bind(this)
    this.handleScroll = this.handleScroll.bind(this)
    this.renderPopoverContent()
  }

  disconnect() {
    this.cleanup()
    if (this.hoverTimeout) {
      clearTimeout(this.hoverTimeout)
    }
  }

  renderPopoverContent() {
    if (!this.hasPopoverTarget) return

    this.popoverTarget.innerHTML = `
      <div class="error-popover-container">
        <div class="error-popover-header">
          <span class="error-popover-title">${this.escapeHtml(this.titleValue)}</span>
          <button type="button"
                  class="error-popover-close"
                  data-action="click->error-popover#hide"
                  aria-label="Close">
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>
        </div>
        <div class="error-popover-content">
          <pre class="error-popover-text">${this.escapeHtml(this.contentValue)}</pre>
        </div>
      </div>
    `
  }

  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }

  toggle(event) {
    event.preventDefault()
    event.stopPropagation()

    if (this.isOpen) {
      this.hide()
    } else {
      this.show()
    }
  }

  show() {
    if (this.isOpen) return

    this.isOpen = true
    this.popoverTarget.classList.remove("hidden")
    this.positionPopover()

    // Add event listeners
    document.addEventListener("click", this.handleClickOutside)
    document.addEventListener("keydown", this.handleEscape)
    window.addEventListener("scroll", this.handleScroll, true)
  }

  hide() {
    if (!this.isOpen) return

    this.isOpen = false
    this.popoverTarget.classList.add("hidden")
    this.cleanup()
  }

  showDelayed() {
    // Cancel any pending hide
    if (this.hoverTimeout) {
      clearTimeout(this.hoverTimeout)
      this.hoverTimeout = null
    }

    // Show after a short delay (300ms)
    this.hoverTimeout = setTimeout(() => {
      this.show()
    }, 300)
  }

  hideDelayed() {
    // Cancel any pending show
    if (this.hoverTimeout) {
      clearTimeout(this.hoverTimeout)
      this.hoverTimeout = null
    }

    // Hide after a short delay (200ms) to allow moving to popover
    this.hoverTimeout = setTimeout(() => {
      // Don't hide if hovering over the popover
      if (!this.popoverTarget.matches(":hover")) {
        this.hide()
      }
    }, 200)
  }

  positionPopover() {
    if (!this.hasTriggerTarget || !this.hasPopoverTarget) return

    const trigger = this.triggerTarget
    const popover = this.popoverTarget
    const triggerRect = trigger.getBoundingClientRect()
    const viewportWidth = window.innerWidth
    const viewportHeight = window.innerHeight

    // Reset position to measure natural size
    popover.style.left = "0"
    popover.style.top = "0"
    popover.style.right = "auto"
    popover.style.bottom = "auto"
    popover.style.maxWidth = `${Math.min(500, viewportWidth - 32)}px`

    const popoverRect = popover.getBoundingClientRect()

    // Calculate position - prefer below and centered, but adjust as needed
    let top = triggerRect.bottom + 8
    let left = triggerRect.left + (triggerRect.width / 2) - (popoverRect.width / 2)

    // Adjust if going off right edge
    if (left + popoverRect.width > viewportWidth - 16) {
      left = viewportWidth - popoverRect.width - 16
    }

    // Adjust if going off left edge
    if (left < 16) {
      left = 16
    }

    // If no room below, show above
    if (top + popoverRect.height > viewportHeight - 16) {
      top = triggerRect.top - popoverRect.height - 8
    }

    // If still doesn't fit, position at viewport bottom
    if (top < 16) {
      top = 16
    }

    popover.style.position = "fixed"
    popover.style.left = `${left}px`
    popover.style.top = `${top}px`
    popover.style.zIndex = "9999"
  }

  handleClickOutside(event) {
    if (!this.element.contains(event.target)) {
      this.hide()
    }
  }

  handleEscape(event) {
    if (event.key === "Escape") {
      this.hide()
    }
  }

  handleScroll() {
    if (this.isOpen) {
      this.positionPopover()
    }
  }

  cleanup() {
    document.removeEventListener("click", this.handleClickOutside)
    document.removeEventListener("keydown", this.handleEscape)
    window.removeEventListener("scroll", this.handleScroll, true)
  }
}
