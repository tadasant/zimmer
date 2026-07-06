import { Controller } from "@hotwired/stimulus"

// Controls the collapsible enqueued messages panel
// Persists collapsed state in sessionStorage per session
export default class extends Controller {
  static targets = ["content", "toggleButton", "toggleIcon", "helpText"]
  static values = {
    sessionId: Number
  }

  connect() {
    // Restore collapsed state from sessionStorage
    this.restoreState()
  }

  get storageKey() {
    if (!this.sessionIdValue) return null
    return `enqueuedMessagesCollapsed_${this.sessionIdValue}`
  }

  toggle() {
    const isCollapsed = this.contentTarget.classList.contains("hidden")

    if (isCollapsed) {
      this.expand()
    } else {
      this.collapse()
    }
  }

  collapse() {
    this.contentTarget.classList.add("hidden")
    this.contentTarget.setAttribute("aria-hidden", "true")
    this.toggleIconTarget.style.transform = "rotate(-90deg)"
    this.toggleButtonTarget.setAttribute("aria-expanded", "false")
    if (this.hasHelpTextTarget) {
      this.helpTextTarget.textContent = "Click to expand"
    }
    if (this.storageKey) {
      sessionStorage.setItem(this.storageKey, "true")
    }
  }

  expand() {
    this.contentTarget.classList.remove("hidden")
    this.contentTarget.removeAttribute("aria-hidden")
    this.toggleIconTarget.style.transform = "rotate(0deg)"
    this.toggleButtonTarget.setAttribute("aria-expanded", "true")
    if (this.hasHelpTextTarget) {
      this.helpTextTarget.textContent = "Will be sent automatically when the agent requests input"
    }
    if (this.storageKey) {
      sessionStorage.removeItem(this.storageKey)
    }
  }

  restoreState() {
    if (!this.storageKey) return
    const isCollapsed = sessionStorage.getItem(this.storageKey) === "true"
    if (isCollapsed) {
      this.collapse()
    }
  }
}
