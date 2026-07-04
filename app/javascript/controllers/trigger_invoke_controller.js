import { Controller } from "@hotwired/stimulus"

// Controls the visibility of the manual trigger invoke panel on the trigger show page.
// Toggles the panel open/closed and disables the submit button after form submission
// to prevent double-clicks.
export default class extends Controller {
  static targets = ["panel", "submitButton"]

  toggle() {
    this.panelTarget.classList.toggle("hidden")
  }

  submitButtonTargetConnected() {
    this.submitButtonTarget.closest("form").addEventListener("submit", () => {
      this.submitButtonTarget.disabled = true
      this.submitButtonTarget.textContent = "Running…"
    })
  }
}
