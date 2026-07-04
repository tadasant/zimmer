import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="session-activity"
//
// Fires a non-blocking, side-effect-only POST to the session's touch_activity
// endpoint so the backend stamps `last_user_activity_at` = now. This resets
// PollBackoff to the fast (every-cron-tick) cadence, so GitHub PR/CI/merge
// status starts refreshing promptly again after the user engages.
//
// Used on "open PR" buttons: the link still opens GitHub in a *new tab* (we do
// NOT call preventDefault), so the page firing this request is never torn down
// and a plain fetch flushes reliably. We deliberately avoid `keepalive`, whose
// separate request infrastructure can be deprioritized or canceled by the
// browser when a new window opens on the same tick.
export default class extends Controller {
  static values = { url: String }

  touch() {
    const url = this.urlValue
    if (!url) return

    // Include the CSRF token when the page exposes one (production/dev have
    // forgery protection on, so it's always present). It is intentionally
    // optional: the test environment disables forgery protection and omits the
    // meta tag, and the request must still fire there — so we never gate the
    // fetch on the token's presence.
    const headers = {}
    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
    if (csrfToken) headers["X-CSRF-Token"] = csrfToken

    fetch(url, {
      method: "POST",
      headers
    }).catch(() => {
      // Best-effort: a missed activity touch only means this session keeps its
      // current poll cadence. Not worth surfacing to the user.
    })
  }
}
