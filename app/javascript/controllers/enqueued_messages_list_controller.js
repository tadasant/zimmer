import { Controller } from "@hotwired/stimulus"

// Manages drag-and-drop reordering of enqueued messages
// Uses HTML5 drag and drop API to allow users to reorder pending messages
//
// Usage:
//   <div data-controller="enqueued-messages-list" data-enqueued-messages-list-session-id-value="123">
//     <div data-enqueued-messages-list-target="item"
//          data-message-id="1"
//          data-action="dragstart->enqueued-messages-list#dragStart dragend->enqueued-messages-list#dragEnd"
//          draggable="true">
//       Message content...
//     </div>
//   </div>
export default class extends Controller {
  static targets = ["item"]
  static values = {
    sessionId: Number
  }

  connect() {
    this.draggedElement = null
    this.draggedOverElement = null
  }

  // Called when user starts dragging an item
  dragStart(event) {
    this.draggedElement = event.currentTarget
    event.dataTransfer.effectAllowed = "move"
    event.dataTransfer.setData("text/html", event.currentTarget.innerHTML)

    // Add visual feedback
    event.currentTarget.classList.add("opacity-50")
  }

  // Called when user stops dragging
  dragEnd(event) {
    event.currentTarget.classList.remove("opacity-50")

    // Remove all drag-over styling
    this.itemTargets.forEach(item => {
      item.classList.remove("border-t-4", "border-blue-500", "border-b-4")
    })

    this.draggedElement = null
    this.draggedOverElement = null
  }

  // Called when dragged item is over a drop target
  dragOver(event) {
    event.preventDefault() // Necessary to allow drop
    event.dataTransfer.dropEffect = "move"

    const target = event.currentTarget
    if (target === this.draggedElement) return

    // Visual feedback: show where item will be dropped
    this.itemTargets.forEach(item => {
      item.classList.remove("border-t-4", "border-blue-500", "border-b-4")
    })

    // Determine if we should show indicator above or below target
    const rect = target.getBoundingClientRect()
    const midpoint = rect.top + rect.height / 2
    const isAbove = event.clientY < midpoint

    if (isAbove) {
      target.classList.add("border-t-4", "border-blue-500")
    } else {
      target.classList.add("border-b-4", "border-blue-500")
    }

    this.draggedOverElement = target
    this.dropPosition = isAbove ? "before" : "after"
  }

  // Called when dragged item leaves a drop target
  dragLeave(event) {
    const target = event.currentTarget
    target.classList.remove("border-t-4", "border-blue-500", "border-b-4")
  }

  // Called when item is dropped
  drop(event) {
    event.preventDefault()
    event.stopPropagation()

    if (!this.draggedElement || !this.draggedOverElement) return
    if (this.draggedElement === this.draggedOverElement) return

    const draggedMessageId = this.draggedElement.dataset.messageId
    const targetMessageId = this.draggedOverElement.dataset.messageId

    // Calculate new position
    const items = this.itemTargets
    const targetIndex = items.indexOf(this.draggedOverElement)
    const newPosition = this.dropPosition === "before" ? targetIndex + 1 : targetIndex + 2

    // Optimistically update the visual order
    if (this.dropPosition === "before") {
      this.draggedOverElement.parentNode.insertBefore(this.draggedElement, this.draggedOverElement)
    } else {
      this.draggedOverElement.parentNode.insertBefore(this.draggedElement, this.draggedOverElement.nextSibling)
    }

    // Send reorder request to server
    this.reorderMessage(draggedMessageId, newPosition)
  }

  // Send PATCH request to reorder the message
  async reorderMessage(messageId, newPosition) {
    const url = `/sessions/${this.sessionIdValue}/enqueued_messages/${messageId}/reorder`

    try {
      const response = await fetch(url, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.getCsrfToken()
        },
        body: JSON.stringify({ position: newPosition })
      })

      if (!response.ok) {
        throw new Error(`Reorder failed: ${response.status}`)
      }

      // Success - Turbo Stream will update the positions if needed
      // or we could parse the response and update positions optimistically
    } catch (error) {
      console.error("Failed to reorder message:", error)

      // Show error to user
      this.showError("Failed to reorder message. Please refresh and try again.")

      // Reload page to restore correct order
      setTimeout(() => {
        window.location.reload()
      }, 2000)
    }
  }

  // Get CSRF token from meta tag
  getCsrfToken() {
    const token = document.querySelector("[name='csrf-token']")
    return token ? token.content : ""
  }

  // Show error message to user
  showError(message) {
    // Create a simple flash message
    const flash = document.createElement("div")
    flash.className = "fixed top-4 right-4 bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded shadow-lg z-50"
    flash.setAttribute("role", "alert")
    flash.innerHTML = `
      <div class="flex items-center">
        <svg class="w-5 h-5 mr-2" fill="currentColor" viewBox="0 0 20 20">
          <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z" clip-rule="evenodd"/>
        </svg>
        <span>${message}</span>
      </div>
    `

    document.body.appendChild(flash)

    // Auto-remove after 5 seconds
    setTimeout(() => {
      flash.remove()
    }, 5000)
  }
}
