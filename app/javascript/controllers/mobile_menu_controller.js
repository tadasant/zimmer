import { Controller } from "@hotwired/stimulus"

/**
 * Mobile Menu Controller
 *
 * Handles the hamburger menu functionality for mobile devices.
 * Toggles visibility of menu items and manages the hamburger icon animation.
 */
export default class extends Controller {
  static targets = ["menu", "button", "openIcon", "closeIcon"]
  static values = {
    open: { type: Boolean, default: false }
  }

  connect() {
    // Close menu when clicking outside
    this.handleClickOutside = this.handleClickOutside.bind(this)
    document.addEventListener("click", this.handleClickOutside)
  }

  disconnect() {
    document.removeEventListener("click", this.handleClickOutside)
  }

  toggle() {
    this.openValue = !this.openValue
    this.updateMenuVisibility()
  }

  close() {
    this.openValue = false
    this.updateMenuVisibility()
  }

  handleClickOutside(event) {
    if (this.openValue && !this.element.contains(event.target)) {
      this.close()
    }
  }

  updateMenuVisibility() {
    if (this.hasMenuTarget) {
      if (this.openValue) {
        this.menuTarget.classList.remove("hidden")
      } else {
        this.menuTarget.classList.add("hidden")
      }
    }

    if (this.hasOpenIconTarget && this.hasCloseIconTarget) {
      if (this.openValue) {
        this.openIconTarget.classList.add("hidden")
        this.closeIconTarget.classList.remove("hidden")
      } else {
        this.openIconTarget.classList.remove("hidden")
        this.closeIconTarget.classList.add("hidden")
      }
    }

    // Update aria-expanded for accessibility
    if (this.hasButtonTarget) {
      this.buttonTarget.setAttribute("aria-expanded", this.openValue.toString())
    }
  }
}
