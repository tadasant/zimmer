import { Controller } from "@hotwired/stimulus"
import { Turbo, cable } from "@hotwired/turbo-rails"

// Connects to data-controller="stream-visibility-recovery"
//
// Restores a page that was hidden long enough for its ActionCable socket to die
// — the backgrounded standalone PWA, the locked phone, the bfcache restore.
//
// Two things can be broken in that moment, and they need different answers:
//
//   1. The socket is dead, so no *future* update will arrive. Fixed by reopening
//      the consumer, which makes ActionCable re-subscribe every subscription on
//      the connection. Costs a WebSocket handshake and no rendering at all.
//   2. Whatever was broadcast while the page was away is gone. Broadcasts are
//      fire-and-forget with no replay, so re-subscribing cannot recover them.
//      Fixed by re-rendering from the server.
//
// (2) is why this controller reloads. The bug was that it reloaded on *every*
// reopen: `pageshow` fires with `persisted` on the bfcache restore iOS performs
// each time a standalone PWA is reopened, and the handler treated that event
// alone as proof of a dead cable — so it reloaded whether or not anything was
// wrong, throwing away scroll position and every other piece of accumulated DOM
// state on a screen the user opens dozens of times a day.
//
// So ask instead of assuming. `connection.isOpen()` is the ground truth, and a
// socket that outlived the hide missed nothing: there is nothing to reconnect
// and nothing to reconcile, so the recovery is skipped outright and reopening
// the app costs nothing. Only a genuinely dead socket reaches the reload.
//
// A morphing refresh was tried here, to make even that case invisible, and
// rejected. Morphing reconciles the live DOM against server HTML, and Stimulus
// controllers in this app keep state in value attributes the server does not
// render — log-level-filter writes its own `level-value` in connect(). Idiomorph
// removes any attribute absent from the server's markup, so that state silently
// reverts to its default and the controller then acts on it: in testing, a morph
// reverted the filter to "minimal" and hid all 66 timeline items. That hazard is
// generic to the app, not specific to one controller, so the reconcile stays a
// plain replacing visit until those controllers are made morph-safe.
//
// Triggers:
//   - visibilitychange -> 'visible', after the page was hidden at least
//     `staleAfter`. Shorter hides are ignored: the socket survives them.
//   - pageshow with event.persisted === true (bfcache restore).
export default class extends Controller {
  static values = {
    // Minimum hidden duration (ms) before the socket is worth checking at all.
    staleAfter: { type: Number, default: 5000 },
    // How long (ms) to let the reopened socket land before replacing the page.
    // The re-render happens either way — a dead socket missed content, and
    // re-subscribing cannot replay it — but going first means a visit that is
    // slow or never arrives still leaves a page with live updates behind it.
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
    // A bfcache restore means the page was frozen, which usually — but not
    // always — means the socket was closed underneath it. recover() checks
    // rather than assuming: on iOS this fires every time the PWA is reopened,
    // and assuming is what made every reopen a reload.
    if (event.persisted) this.recover()
  }

  // Restore live updates, and re-render only if something was actually missed.
  async recover() {
    if (this.isRecovering) return

    // A page with no stream sources has no live updates to lose, and asking for
    // a consumer would open a WebSocket it never wanted.
    if (this.streamSources.length === 0) return

    this.isRecovering = true

    // A consumer we cannot read tells us nothing about the socket, so fall back
    // to what this controller did before it knew how to ask: re-render. Leaving
    // a possibly-frozen page alone is the one outcome worse than a reload.
    let connection = null
    try {
      connection = (await cable.getConsumer())?.connection
    } catch (_e) {
      connection = null
    }

    try {
      // The socket outlived the hide, so nothing was broadcast into a void and
      // nothing needs re-rendering. This is the path that used to reload.
      if (connection?.isOpen()) return

      // Reopening re-subscribes every subscription on the connection, which is
      // what actually restores live updates. `cable-reconnect` independently
      // re-subscribes any individual source that stays dark after it.
      connection?.reopen()

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
  // away. Only ever reached with a socket that was genuinely found dead.
  reload() {
    // An offline reopen has nothing to fetch and the visit would only fail. The
    // socket stays reopened, so updates resume when the network does.
    if (navigator.onLine === false) return

    Turbo.visit(window.location.href, { action: "replace" })
  }
}
