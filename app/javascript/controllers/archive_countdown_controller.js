import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="archive-countdown"
export default class extends Controller {
  static targets = ["archiveButton"]
  static values = {
    sessionId: Number,
    archiveUrl: String
  }

  startCountdown() {
    // Submit immediately - no countdown needed (undo will be in toast)
    this.archiveSession()
  }

  archiveSession() {
    // Create a form and submit it to archive the session
    const form = document.createElement("form")
    form.method = "POST"
    form.action = this.archiveUrlValue

    // Add CSRF token
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
    if (csrfToken) {
      const csrfInput = document.createElement("input")
      csrfInput.type = "hidden"
      csrfInput.name = "authenticity_token"
      csrfInput.value = csrfToken
      form.appendChild(csrfInput)
    }

    document.body.appendChild(form)
    form.submit()
  }
}
