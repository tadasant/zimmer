import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="stream-visibility-recovery"
//
// When a mobile PWA is backgrounded or the device sleeps, the OS suspends the
// page and the underlying ActionCable WebSocket dies silently. When the user
// reopens the app, Turbo Stream subscriptions are stale and live updates no
// longer arrive. This controller detects the page becoming visible again and
// forces a Turbo.visit reload, which re-renders the page and re-establishes
// fresh <turbo-cable-stream-source> subscriptions via their connectedCallback.
//
// Triggers:
//   - visibilitychange -> 'visible' after the page was hidden long enough that
//     the WebSocket is likely dead, OR any cable stream source is missing the
//     `connected` attribute (which turbo-rails sets/removes on subscription
//     connect/disconnect events).
//   - pageshow with event.persisted === true (bfcache restore — the previous
//     page state is frozen and the cable consumer is definitely dead).
export default class extends Controller {
  static values = {
    // Minimum hidden duration (ms) before we consider the WebSocket potentially
    // stale and trigger a refresh. Brief tab switches shouldn't cause reloads.
    staleAfter: { type: Number, default: 5000 },
    // Grace period (ms) after becoming visible before we check for missing
    // `connected` attributes — lets ActionCable's monitor attempt reconnect on
    // its own before we force a full refresh.
    reconnectGrace: { type: Number, default: 1500 }
  }

  connect() {
    this.hiddenAt = null
    this.isRefreshing = false

    this.boundVisibilityChange = this.handleVisibilityChange.bind(this)
    this.boundPageShow = this.handlePageShow.bind(this)

    document.addEventListener("visibilitychange", this.boundVisibilityChange)
    window.addEventListener("pageshow", this.boundPageShow)
  }

  disconnect() {
    document.removeEventListener("visibilitychange", this.boundVisibilityChange)
    window.removeEventListener("pageshow", this.boundPageShow)
  }

  handleVisibilityChange() {
    if (document.visibilityState === "hidden") {
      this.hiddenAt = Date.now()
      return
    }

    if (document.visibilityState !== "visible") return

    const hiddenDuration = this.hiddenAt ? Date.now() - this.hiddenAt : 0
    this.hiddenAt = null

    // Brief tab switches don't kill the WebSocket — let it ride.
    if (hiddenDuration < this.staleAfterValue) return

    // Give ActionCable's connection monitor a chance to reconnect on its own.
    // If after the grace period any stream source is still disconnected, force
    // a full refresh.
    setTimeout(() => this.refreshIfStreamsDisconnected(), this.reconnectGraceValue)
  }

  handlePageShow(event) {
    // bfcache restore: the page was frozen, the cable consumer is dead.
    if (event.persisted) {
      this.forceRefresh()
    }
  }

  refreshIfStreamsDisconnected() {
    if (this.isRefreshing) return

    const sources = document.querySelectorAll("turbo-cable-stream-source")
    if (sources.length === 0) return

    const anyDisconnected = Array.from(sources).some(
      (source) => !source.hasAttribute("connected")
    )

    if (anyDisconnected) this.forceRefresh()
  }

  forceRefresh() {
    if (this.isRefreshing) return
    this.isRefreshing = true

    if (typeof Turbo !== "undefined") {
      Turbo.visit(window.location.href, { action: "replace" })
    } else {
      window.location.reload()
    }

    // Reset the flag after a short delay so subsequent visibility changes can
    // trigger another refresh if needed.
    setTimeout(() => {
      this.isRefreshing = false
    }, 2000)
  }
}
