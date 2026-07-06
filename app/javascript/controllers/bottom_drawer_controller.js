import { Controller } from "@hotwired/stimulus"

/**
 * Bottom Drawer Controller
 *
 * Handles the slide-up drawer functionality for mobile follow-up prompts.
 * On mobile, shows a minimal trigger bar that expands to full form when tapped.
 */
export default class extends Controller {
  static targets = ["drawer", "trigger", "content", "overlay"]
  static values = {
    open: { type: Boolean, default: false }
  }

  connect() {
    // Update visibility on connect
    this.updateDrawerVisibility()

    // Store bound handlers for cleanup
    this.boundClose = () => this.close()
    this.boundHandleKeydown = this.handleKeydown.bind(this)

    // Close drawer when clicking overlay
    if (this.hasOverlayTarget) {
      this.overlayTarget.addEventListener("click", this.boundClose)
    }

    // Listen for escape key to close drawer
    document.addEventListener("keydown", this.boundHandleKeydown)
  }

  disconnect() {
    // Clean up event listeners
    if (this.hasOverlayTarget && this.boundClose) {
      this.overlayTarget.removeEventListener("click", this.boundClose)
    }
    if (this.boundHandleKeydown) {
      document.removeEventListener("keydown", this.boundHandleKeydown)
    }
  }

  toggle() {
    this.openValue = !this.openValue
    this.updateDrawerVisibility()
  }

  open() {
    this.openValue = true
    this.updateDrawerVisibility()
  }

  close() {
    this.openValue = false
    this.updateDrawerVisibility()
  }

  updateDrawerVisibility() {
    // Drawer visibility is controlled entirely via hidden class on trigger/content targets
    if (this.hasTriggerTarget) {
      if (this.openValue) {
        this.triggerTarget.classList.add("hidden")
      } else {
        this.triggerTarget.classList.remove("hidden")
      }
    }

    if (this.hasContentTarget) {
      if (this.openValue) {
        this.contentTarget.classList.remove("hidden")
      } else {
        this.contentTarget.classList.add("hidden")
      }
    }

    if (this.hasOverlayTarget) {
      if (this.openValue) {
        this.overlayTarget.classList.remove("hidden")
      } else {
        this.overlayTarget.classList.add("hidden")
      }
    }
  }

  // Handle escape key to close drawer
  handleKeydown(event) {
    if (event.key === "Escape" && this.openValue) {
      this.close()
    }
  }
}
