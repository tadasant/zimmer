import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="flash"
export default class extends Controller {
  static values = {
    duration: { type: Number, default: 5000 }
  }

  connect() {
    // Auto-dismiss after specified duration (default 5 seconds)
    this.timeout = setTimeout(() => {
      this.dismiss()
    }, this.durationValue)
  }

  disconnect() {
    if (this.timeout) {
      clearTimeout(this.timeout)
    }
  }

  dismiss() {
    this.element.classList.add('opacity-0', 'translate-x-full')

    // Remove element after animation completes
    setTimeout(() => {
      this.element.remove()
    }, 300)
  }
}
