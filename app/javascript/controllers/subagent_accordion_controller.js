import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="subagent-accordion"
// Manages expandable subagent transcript accordions with auto-scroll support
export default class extends Controller {
  static targets = ["content", "chevron", "messageContainer", "lastMessage"]
  static values = {
    agentId: String,
    expanded: { type: Boolean, default: false }
  }

  connect() {
    // Initialize expanded state from value
    this.updateExpandedState()

    // Set up intersection observer for auto-scroll
    this.setupIntersectionObserver()

    // Bind event handler once for proper cleanup
    this.boundHandleStreamRender = this.handleStreamRender.bind(this)
    document.addEventListener("turbo:before-stream-render", this.boundHandleStreamRender)
  }

  disconnect() {
    // Clean up observer and tracked element
    if (this.observer) {
      this.observer.disconnect()
    }
    this.lastObservedElement = null

    // Remove event listener using the bound reference
    if (this.boundHandleStreamRender) {
      document.removeEventListener("turbo:before-stream-render", this.boundHandleStreamRender)
    }
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
      // Rotate chevron when expanded
      this.chevronTarget.classList.toggle("rotate-90", this.expandedValue)
    }
  }

  expandedValueChanged() {
    this.updateExpandedState()
  }

  // Set up intersection observer for the last message
  // This tracks whether user is viewing the latest content
  setupIntersectionObserver() {
    this.lastMessageVisible = true

    this.observer = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (entry.target === this.lastMessageTarget) {
          this.lastMessageVisible = entry.isIntersecting
        }
      })
    }, { threshold: 0.1 })

    this.updateLastMessageObserver()
  }

  updateLastMessageObserver() {
    if (!this.observer) return

    // Unobserve the previous element to prevent memory leaks
    if (this.lastObservedElement && this.lastObservedElement !== this.lastMessageTarget) {
      this.observer.unobserve(this.lastObservedElement)
    }

    // Observe the new last message target
    if (this.hasLastMessageTarget) {
      this.observer.observe(this.lastMessageTarget)
      this.lastObservedElement = this.lastMessageTarget
    }
  }

  // Handle Turbo Stream renders - scroll if viewing latest content
  handleStreamRender(event) {
    const target = event.target
    if (!target || !target.getAttribute) return

    const targetId = target.getAttribute("target")

    // Check if this stream is for our accordion's message container
    if (targetId && targetId.includes(`subagent_${this.agentIdValue}`)) {
      setTimeout(() => {
        this.messageAppended()
      }, 0)
    }
  }

  // Called when a new message is appended
  messageAppended() {
    // Update the observer to track the new last message
    this.updateLastMessageObserver()

    // Only auto-scroll if expanded and user was viewing the latest content
    if (this.expandedValue && this.lastMessageVisible && this.hasMessageContainerTarget) {
      this.messageContainerTarget.scrollTo({
        top: this.messageContainerTarget.scrollHeight,
        behavior: "smooth"
      })
    }
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
