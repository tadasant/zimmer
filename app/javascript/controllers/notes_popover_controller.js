import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="notes-popover"
// Shows a popover with session notes on hover
export default class extends Controller {
  static targets = ["popover"]

  connect() {
    this.hideTimeout = null
  }

  disconnect() {
    if (this.hideTimeout) {
      clearTimeout(this.hideTimeout)
    }
  }

  show() {
    if (!this.hasPopoverTarget) return
    if (this.hideTimeout) {
      clearTimeout(this.hideTimeout)
      this.hideTimeout = null
    }
    this.popoverTarget.classList.remove("hidden")
  }

  hide() {
    if (!this.hasPopoverTarget) return
    // Small delay to allow moving mouse to popover
    this.hideTimeout = setTimeout(() => {
      this.popoverTarget.classList.add("hidden")
    }, 200)
  }

  keepOpen() {
    if (this.hideTimeout) {
      clearTimeout(this.hideTimeout)
      this.hideTimeout = null
    }
  }
}
