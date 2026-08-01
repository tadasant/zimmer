import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="live-updates-status"
//
// Keeps the "live updates paused" banner honest after the page has loaded.
//
// The banner reports that BroadcastService's circuit breaker is open — which is
// to say, that Turbo Stream broadcasts are being dropped. That rules out the
// channel Zimmer would normally use to update a banner in place: announcing the
// outage over the thing that is broken. It also rules out rendering it at page
// load and leaving it, because the breaker opens (and closes, 60 seconds later)
// while the user is sitting on a page they are not about to reload — the whole
// point of the issue is a UI that freezes and looks fine.
//
// So: poll. The server renders the banner's markup, this controller only swaps
// the fragment in, and polling stops while the tab is hidden (and refreshes once
// on return, so the banner is right the moment the user looks at it again).
export default class extends Controller {
  static values = {
    url: String,
    // Well under the breaker's 60s reset window, so a paused stretch is reported
    // for most of its life rather than announced just as it ends.
    interval: { type: Number, default: 15000 }
  }

  connect() {
    // The server-rendered fragment is already current, so start the clock rather
    // than polling immediately.
    this.boundVisibilityChange = this.handleVisibilityChange.bind(this)
    document.addEventListener("visibilitychange", this.boundVisibilityChange)
    this.startPolling()
  }

  disconnect() {
    this.stopPolling()
    document.removeEventListener("visibilitychange", this.boundVisibilityChange)
  }

  startPolling() {
    if (this.pollTimer) return
    this.pollTimer = setInterval(() => this.poll(), this.intervalValue)
  }

  stopPolling() {
    if (!this.pollTimer) return
    clearInterval(this.pollTimer)
    this.pollTimer = null
  }

  handleVisibilityChange() {
    if (document.hidden) {
      this.stopPolling()
    } else {
      this.startPolling()
      this.poll()
    }
  }

  async poll() {
    if (!this.urlValue) return

    try {
      const response = await fetch(this.urlValue, {
        headers: { Accept: "text/html" },
        credentials: "same-origin"
      })
      if (!response.ok) return
      this.element.innerHTML = await response.text()
    } catch (_e) {
      // A failed poll needs no handling of its own: the banner keeps whatever it
      // last showed and the next tick tries again. Surfacing "couldn't check
      // whether updates are paused" would be noise on top of an outage.
    }
  }
}
