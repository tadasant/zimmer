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
    // turbo_stream branch and the card is removed in place. Mirrors
    // joystick_menu_controller#_submitForm, which archives the same way.
    form.dataset.turbo = "true"
    // The form is a submission vehicle, not UI: keep it out of the layout for
    // the beat it spends in the document.
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
    // A native form.submit() does NOT fire a `submit` event, so Turbo never
    // sees the submission: the browser performs a real POST navigation, the
    // archive action answers on its format.html branch, and the redirect to the
    // dashboard reloads the whole page — throwing away the scroll position the
    // drawer this button lives in was opened over. requestSubmit() fires the
    // event, so Turbo sends `Accept: text/vnd.turbo-stream.html` and applies
    // the returned stream in place. The native call stays as a fallback for any
    // browser without requestSubmit: a full reload beats a dead button.
    form.addEventListener("turbo:submit-end", () => form.remove(), { once: true })
    if (form.requestSubmit) {
      form.requestSubmit()
    } else {
      form.submit()
    }
  }
}
