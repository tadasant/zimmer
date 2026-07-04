import { Controller } from "@hotwired/stimulus"

// Polls the login_status endpoint for an in-flight RuntimeLoginAttempt and
// applies the returned Turbo Stream, surfacing the verification URL/code and
// status transitions as the worker drives the login CLI.
//
// The controller lives on the non-terminal login-attempt element. Each poll
// replaces that element (or, on success, the whole account card). When the
// replacement is itself terminal it carries no controller, so polling stops
// naturally; disconnect() clears the timer for the element being torn down.
//
// Usage: data-controller="quotas-login-poller"
//        data-quotas-login-poller-url-value="<login_status_path>"
//        data-quotas-login-poller-interval-value="2000"
export default class extends Controller {
  static values = {
    url: String,
    interval: { type: Number, default: 2000 }
  }

  // Give up after this many consecutive failed polls (network error or non-2xx)
  // so a persistently-failing endpoint doesn't poll forever in the background.
  static MAX_CONSECUTIVE_ERRORS = 10

  connect() {
    this.stopped = false
    this.errorCount = 0
    this.timer = setInterval(() => this.poll(), this.intervalValue)
  }

  disconnect() {
    this.stopped = true
    if (this.timer) {
      clearInterval(this.timer)
      this.timer = null
    }
  }

  async poll() {
    if (this.stopped || this.polling) return
    this.polling = true
    try {
      const response = await fetch(this.urlValue, {
        headers: { Accept: "text/vnd.turbo-stream.html" },
        credentials: "same-origin"
      })
      if (!response.ok) {
        this.recordError()
        return
      }
      const stream = await response.text()
      // The element may have been disconnected while awaiting the response.
      if (this.stopped) return
      this.errorCount = 0
      this.applyStream(stream)
    } catch (_e) {
      // Transient network error — the next tick retries, up to the error cap.
      this.recordError()
    } finally {
      this.polling = false
    }
  }

  // The poll response replaces the whole login panel — including, in the
  // awaiting_code state, the authorization-code <form> the user pastes into and
  // clicks Submit on. Applying it on every tick (every intervalValue ms) tears
  // that form out and rebuilds it from scratch, which breaks the submit in two
  // ways: a click landing on the old Submit button after the swap hits a node
  // that is no longer in the document (no submit fires), and a click landing in
  // the brief window before the rebuilt field is repopulated submits an empty
  // code (which the controller silently drops). Either way "pasting the code
  // does nothing".
  //
  // While awaiting_code the verification URL and the panel are static — a poll
  // that still reports awaiting_code carries no new information, so there is
  // nothing to render. Apply the stream only when the status actually changes
  // (into awaiting_code, or onward to completing/succeeded/failed/...); skip the
  // redundant same-status re-renders so the form the user is interacting with
  // stays put: same node, same value, same focus. This keeps the Submit path
  // intact across the entire awaiting_code window without any snapshot/restore.
  applyStream(stream) {
    const current = this.element.dataset.loginStatus
    const next = this.parseLoginStatus(stream)
    if (current === "awaiting_code" && next === "awaiting_code") return
    window.Turbo.renderStreamMessage(stream)
  }

  // Read the attempt's status out of a login_status Turbo Stream payload. The
  // streamed panel carries it as data-login-status on the login-attempt element.
  // Returns null when the stream has no such marker (e.g. the success response
  // swaps in the whole account card), in which case the caller applies it — the
  // skip only ever suppresses a redundant awaiting_code → awaiting_code render.
  parseLoginStatus(stream) {
    try {
      const doc = new DOMParser().parseFromString(stream, "text/html")
      // Turbo Stream content lives inside <turbo-stream><template>…; <template>
      // contents parse into .content rather than the main tree, so reach in.
      const template = doc.querySelector("turbo-stream template")
      const el = template ? template.content.querySelector("[data-login-status]") : null
      return el ? el.dataset.loginStatus : null
    } catch (_e) {
      return null
    }
  }

  recordError() {
    this.errorCount += 1
    if (this.errorCount >= this.constructor.MAX_CONSECUTIVE_ERRORS) {
      this.disconnect()
    }
  }
}
