import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="enqueued-message-accordion"
// Manages expandable enqueued message accordion
export default class extends Controller {
  static targets = ["content", "chevron", "toggleButton"]
  static values = {
    expanded: { type: Boolean, default: false }
  }

  connect() {
    // Initialize collapsed state
    this.updateExpandedState()
  }

  // Toggle accordion expanded/collapsed state
  toggle() {
    this.expandedValue = !this.expandedValue
    this.updateExpandedState()
  }

  updateExpandedState() {
    if (this.hasContentTarget) {
      this.contentTarget.classList.toggle("hidden", !this.expandedValue)
    }

    if (this.hasChevronTarget) {
      // Rotate chevron when expanded (90deg)
      if (this.expandedValue) {
        this.chevronTarget.style.transform = "rotate(90deg)"
      } else {
        this.chevronTarget.style.transform = "rotate(0deg)"
      }
    }
  }

  expandedValueChanged() {
    this.updateExpandedState()
  }

  // Expand the accordion
  expand() {
    this.expandedValue = true
  }

  // Collapse the accordion
  collapse() {
    this.expandedValue = false
  }
}
