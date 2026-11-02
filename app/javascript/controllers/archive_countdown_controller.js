import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"
import { csrfToken } from "lib/csrf"
import { showAlert, showNotice } from "lib/toast"

// Connects to data-controller="archive-countdown"
//
// The session header's Trash. In the dashboard's drawer it submits a Turbo form,
// and optimistic_actions.js takes the card behind the drawer away at the click.
// On the session's own full page there is no card: the page itself is what goes,
// so the browser visits the board at once and the archive is asked for in the
// background; its answer — the Undo toast, or a refusal — is rendered into the
// board when it comes.
export default class extends Controller {
  static targets = ["archiveButton"]
  static values = {
    sessionId: Number,
    archiveUrl: String
  }

  startCountdown() {
    // Submit immediately - no countdown needed (undo will be in toast)
    if (this.onOwnPage()) {
      this.archiveAndGoHome()
    } else {
      this.archiveSession()
    }
  }

  // Whether this button is on the session's own full page, as opposed to the
  // drawer on the dashboard's URL (the same test #archive makes with the referer).
  onOwnPage() {
    const path = window.location.pathname
    return /^\/sessions\/[^/]+$/.test(path) && !/^\/sessions\/(new|starting|search)$/.test(path)
  }

  // Home now; the archive in the background. The request says it is not the page's
  // own form (X-Zimmer-Optimistic), so #archive answers with its streams rather
  // than the 303 it gives the full page, and those streams — the card's removal,
  // the Undo toast, or the "Archive anyway" refusal — render into the board.
  async archiveAndGoHome() {
    const url = this.archiveUrlValue
    const body = new URLSearchParams({ authenticity_token: csrfToken() })
    // The answer is rendered into the board, not into this page on its way out:
    // a stream landing before the visit has swapped the body in would put the
    // toast into the document being left. A visit that never finishes (another
    // click first) must not hold the answer forever, so the wait is bounded.
    const boardLoaded = new Promise((resolve) => {
      document.addEventListener("turbo:load", resolve, { once: true })
      setTimeout(resolve, 10_000)
    })
    Turbo.visit("/")
    try {
      const response = await fetch(url, {
        method: "POST",
        headers: {
          "Accept": "text/vnd.turbo-stream.html",
          "X-Zimmer-Optimistic": "1",
          "Content-Type": "application/x-www-form-urlencoded"
        },
        body
      })
      const type = response.headers.get("content-type") || ""
      const text = await response.text()
      await boardLoaded
      if (!type.includes("turbo-stream")) {
        if (!response.ok) showAlert(`The session could not be moved to trash. The server answered ${response.status}.`)
      } else if (window.location.pathname === "/") {
        Turbo.renderStreamMessage(text)
      } else if (response.ok) {
        // The reader went elsewhere meanwhile: the board's Undo toast belongs to
        // the board, so the outcome is said plainly here.
        showNotice("Session moved to trash.")
      } else {
        showAlert("The session could not be moved to trash. Open it from the board to see why.")
      }
    } catch (error) {
      await boardLoaded
      showAlert("The session could not be moved to trash: the server could not be reached.")
    }
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

    // Add CSRF token. Appended unconditionally: an empty `authenticity_token`
    // and an absent one are the same rejection to Rails, so there is nothing to
    // gain from a second code path for the empty case.
    const csrfInput = document.createElement("input")
    csrfInput.type = "hidden"
    csrfInput.name = "authenticity_token"
    csrfInput.value = csrfToken()
    form.appendChild(csrfInput)

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
