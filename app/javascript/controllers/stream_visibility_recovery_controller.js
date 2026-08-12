import { Controller } from "@hotwired/stimulus"
import { Turbo, cable } from "@hotwired/turbo-rails"

// Connects to data-controller="stream-visibility-recovery"
//
// Recovers a page that was hidden long enough for its ActionCable socket to die
// — the backgrounded standalone PWA, the locked phone, the bfcache restore.
//
// Two things break in that moment and need different answers:
//
//   1. The socket is dead, so no future update arrives. Reopening the consumer
//      fixes it: ActionCable re-subscribes every subscription on the connection,
//      for the cost of a handshake and no rendering at all.
//   2. Whatever was broadcast while the page was away is gone. Broadcasts are
//      fire-and-forget with no replay, so re-subscribing cannot recover them.
//      Only re-rendering from the server can.
//
// (2) is what the reload is for, and it is reached only for a socket that
// reports itself closed. An open socket carried its subscriptions through the
// hide and queued its messages, so it has missed nothing and the page is left
// untouched — no navigation, no lost scroll position, no collapsed panels. That
// matters because `pageshow` fires with `persisted` on every bfcache restore,
// which on iOS is every single reopen of an installed PWA.
//
// The limit of that check is `readyState`: a socket the browser never reports as
// closed reads as open even when the server is gone, and this controller leaves
// it alone. ActionCable's own monitor and `cable-reconnect` still heal the
// subscription, so updates resume — but content broadcast during the gap is not
// backfilled. See docs limitations.
//
// A morphing refresh was tried for the reload case and rejected: idiomorph
// removes attributes the server does not render, and controllers here keep state
// in exactly those (log-level-filter writes its own `level-value`), so a morph
// reverts that state and the controller then acts on it.
//
// Triggers:
//   - visibilitychange -> 'visible', after the page was hidden at least
//     `staleAfter`. Shorter hides do not kill the socket.
//   - pageshow with event.persisted === true (bfcache restore).
export default class extends Controller {
  static values = {
    // Minimum hidden duration (ms) before the socket is worth checking at all.
    staleAfter: { type: Number, default: 5000 },
    // How long (ms) to let the reopened socket land before replacing the page.
    // The re-render happens either way — a closed socket missed content, and
    // re-subscribing cannot replay it — but reopening first means a visit that
    // is slow or never arrives still leaves a page with live updates behind it.
    reconnectGrace: { type: Number, default: 1500 }
  }

  connect() {
    this.hiddenAt = null
    this.isRecovering = false

    this.boundVisibilityChange = this.handleVisibilityChange.bind(this)
    this.boundPageShow = this.handlePageShow.bind(this)

    document.addEventListener("visibilitychange", this.boundVisibilityChange)
    window.addEventListener("pageshow", this.boundPageShow)
  }

  disconnect() {
    document.removeEventListener("visibilitychange", this.boundVisibilityChange)
    window.removeEventListener("pageshow", this.boundPageShow)
    clearTimeout(this.recoveryTimer)
    clearTimeout(this.releaseTimer)
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

    this.recover()
  }

  handlePageShow(event) {
    if (event.persisted) this.recover()
  }

  // Restore live updates, and re-render only if something was missed.
  async recover() {
    if (this.isRecovering) return

    // A page with no stream sources has no live updates to lose.
    if (this.streamSources.length === 0) return

    this.isRecovering = true

    // A consumer that cannot be read says nothing about the socket, so fall
    // through to the re-render. Leaving a possibly-frozen page alone is the one
    // outcome worse than a reload.
    let connection = null
    try {
      connection = (await cable.getConsumer())?.connection
    } catch (_e) {
      connection = null
    }

    if (connection?.isOpen()) {
      this.isRecovering = false
      return
    }

    try {
      // A socket still completing its handshake is already on its way back;
      // reopening would tear that down and start the delay over.
      if (!connection?.isActive()) connection?.reopen()

      await this.settle(this.reconnectGraceValue)

      this.reload()
    } finally {
      // Hold the guard past the visit rather than releasing it here. A reopen
      // can deliver pageshow and visibilitychange back to back, and each would
      // otherwise stack another navigation onto the one already in flight.
      this.releaseTimer = setTimeout(() => {
        this.isRecovering = false
      }, 2000)
    }
  }

  get streamSources() {
    return Array.from(document.querySelectorAll("turbo-cable-stream-source"))
  }

  settle(delay) {
    return new Promise((resolve) => {
      this.recoveryTimer = setTimeout(resolve, delay)
    })
  }

  // Re-render from the server to pick up what was broadcast while the page was
  // away. Reached only for a socket that reported itself closed.
  reload() {
    Turbo.visit(window.location.href, { action: "replace" })
  }
}
