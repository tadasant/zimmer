import { Controller } from "@hotwired/stimulus"
import { csrfToken } from "lib/csrf"

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

    // The token is empty when the page exposes none — the test environment
    // disables forgery protection, so `csrf_meta_tags` renders nothing. Send the
    // header either way: the request must still fire there, so we never gate the
    // fetch on the token's presence.
    fetch(url, {
      method: "POST",
      headers: { "X-CSRF-Token": csrfToken() }
    }).catch(() => {
      // Best-effort: a missed activity touch only means this session keeps its
      // current poll cadence. Not worth surfacing to the user.
    })
  }
}
