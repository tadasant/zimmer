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
    // Let Turbo intercept, so SessionsController#archive answers on its
    // turbo_stream branch and the card is removed in place. The form belongs on
    // document.body rather than inside this button's `session_detail` frame: a
    // frame-scoped submission has its response scoped to that frame, and the
    // stream that removes the dashboard card behind it would never land.
    form.dataset.turbo = "true"
    // A submission vehicle, not UI, for the beat it spends in the document.
    form.hidden = true

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
    // Turbo listens for the `submit` event, and a native form.submit() fires
    // none — the browser POSTs for real, #archive answers on its format.html
    // branch, and the redirect reloads the dashboard from the top. Only
    // requestSubmit() fires the event. Turbo dispatches turbo:submit-end on
    // every settled outcome, so the form always cleans itself up; the native
    // fallback tears the document down with it.
    form.addEventListener("turbo:submit-end", () => form.remove(), { once: true })
    if (form.requestSubmit) {
      form.requestSubmit()
    } else {
      form.submit()
    }
  }
}
