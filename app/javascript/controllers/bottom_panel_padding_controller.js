import { Controller } from "@hotwired/stimulus"

// Dynamically adjusts padding at the bottom of the content area
// to prevent overlap with the fixed bottom panel (follow-up form + queued messages)
export default class extends Controller {
  static targets = ["panel", "spacer"]

  connect() {
    // Set up ResizeObserver to watch for panel size changes
    this.resizeObserver = new ResizeObserver(() => {
      this.updatePadding()
    })

    if (this.hasPanelTarget) {
      this.resizeObserver.observe(this.panelTarget)
    }

    // Initial update
    this.updatePadding()

    // Also update when Turbo Stream replaces content
    this.boundUpdatePadding = this.updatePadding.bind(this)
    document.addEventListener("turbo:before-stream-render", this.boundUpdatePadding)
    document.addEventListener("turbo:render", this.boundUpdatePadding)
  }

  disconnect() {
    if (this.resizeObserver) {
      this.resizeObserver.disconnect()
    }
    if (this.boundUpdatePadding) {
      document.removeEventListener("turbo:before-stream-render", this.boundUpdatePadding)
      document.removeEventListener("turbo:render", this.boundUpdatePadding)
    }
  }

  updatePadding() {
    if (!this.hasPanelTarget || !this.hasSpacerTarget) return

    // Get the actual height of the bottom panel
    const panelHeight = this.panelTarget.offsetHeight

    // Add some buffer (16px) for comfort
    const totalPadding = panelHeight + 16

    // Update the spacer height
    this.spacerTarget.style.height = `${totalPadding}px`
  }
}
