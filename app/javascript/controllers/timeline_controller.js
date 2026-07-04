import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="timeline"
export default class extends Controller {
  connect() {
    // Listen for turbo stream renders to remove empty state
    this.element.addEventListener('turbo:before-stream-render', this.removeEmptyState.bind(this))

    // Also check on connect in case items were added
    this.checkAndRemoveEmptyState()
  }

  disconnect() {
    this.element.removeEventListener('turbo:before-stream-render', this.removeEmptyState.bind(this))
  }

  removeEmptyState(event) {
    this.checkAndRemoveEmptyState()
  }

  checkAndRemoveEmptyState() {
    const emptyMessage = this.element.querySelector('#empty-timeline-message')
    if (emptyMessage) {
      // Check if there are any other children besides the empty message and running loader
      const otherChildren = Array.from(this.element.children).filter(
        child => child.id !== 'empty-timeline-message' && !child.id.includes('_running_loader')
      )

      if (otherChildren.length > 0) {
        emptyMessage.remove()
      }
    }
  }
}
