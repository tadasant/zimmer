import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="flash"
export default class extends Controller {
  static values = {
    duration: { type: Number, default: 5000 }
  }

  connect() {
    // Auto-dismiss after specified duration (default 5 seconds)
    this.schedule()
  }

  // A toast rewritten in place (lib/toast.js updateToast) gets a new duration,
  // counted from the rewrite. Before connect there is no timer to re-arm.
  durationValueChanged() {
    if (this.timeout) this.schedule()
  }

  disconnect() {
    if (this.timeout) {
      clearTimeout(this.timeout)
      this.timeout = null
    }
  }

  schedule() {
    if (this.timeout) clearTimeout(this.timeout)
    this.timeout = setTimeout(() => {
      this.dismiss()
    }, this.durationValue)
  }

  dismiss() {
    this.element.classList.add('opacity-0', 'translate-x-full')

    // Remove element after animation completes
    setTimeout(() => {
      this.element.remove()
    }, 300)
  }
}
