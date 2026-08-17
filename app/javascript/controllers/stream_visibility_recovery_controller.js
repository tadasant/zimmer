import { Controller } from "@hotwired/stimulus"
import { Turbo, cable } from "@hotwired/turbo-rails"
import { backfillLiveRegions } from "lib/live_region_backfill"

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
//      Only the server can say what the page should look like now.
//
// (2) used to be answered with a full replacing `Turbo.visit`, and that is the
// bug this controller exists to not have: iOS suspends a backgrounded standalone
// PWA, which kills the WebSocket, so the socket is dead on *every* reopen and the
// visit fired every time. Checking `isOpen()` first — the previous attempt at
// this — only made the case that never happens free.
//
// So the answer to (2) is a backfill instead: fetch the page the server would
// render now and reconcile only the regions broadcasts target (see
// lib/live_region_backfill.js and the `data-live-region` markers in the views).
// Missed timeline items, a changed status badge and a stale header land in the
// document the reader was already looking at — same scroll position, same open
// disclosures, same expanded items, no navigation at all.
//
// A backfill that cannot complete falls back to the visit. A page that silently
// failed to recover is the one outcome worse than a page that lost its place.
//
// Triggers:
//   - visibilitychange -> 'visible', after the page was hidden at least
//     `staleAfter`. Shorter hides do not kill the socket.
//   - pageshow with event.persisted === true (bfcache restore).
export default class extends Controller {
  static values = {
    // Minimum hidden duration (ms) before the socket is worth checking at all.
    staleAfter: { type: Number, default: 5000 },
    // How long (ms) to let the reopened socket land before backfilling. Doing it
    // in this order means an update broadcast *during* the backfill still has a
    // subscription to arrive on.
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

  // Restore live updates, and backfill only if something was missed.
  async recover() {
    if (this.isRecovering) return

    // A page with no stream sources has no live updates to lose.
    if (this.streamSources.length === 0) return

    this.isRecovering = true

    // A consumer that cannot be read says nothing about the socket, so fall
    // through to the backfill. Leaving a possibly-frozen page alone is the one
    // outcome worse than recovering it.
    let connection = null
    try {
      connection = (await cable.getConsumer())?.connection
    } catch (_e) {
      connection = null
    }

    if (connection?.isOpen()) {
      this.isRecovering = false
      this.dispatch("recovered", { detail: { socketWasOpen: true, changed: 0 } })
      return
    }

    try {
      // A socket still completing its handshake is already on its way back;
      // reopening would tear that down and start the delay over.
      if (!connection?.isActive()) connection?.reopen()

      await this.settle(this.reconnectGraceValue)

      await this.backfill()
    } finally {
      // Hold the guard past the backfill rather than releasing it here. A reopen
      // can deliver pageshow and visibilitychange back to back, and each would
      // otherwise stack another fetch onto the one already in flight.
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

  // Pick up what was broadcast while the page was away, in place. Reached only
  // for a socket that reported itself closed.
  async backfill() {
    let fresh

    try {
      const response = await fetch(window.location.href, {
        headers: { Accept: "text/html" },
        credentials: "same-origin",
        cache: "no-store"
      })

      // A redirect means this URL is no longer the page it was — signed out, or
      // the record is gone. Let the browser follow it properly.
      if (response.redirected || !response.ok) return this.reload()

      fresh = new DOMParser().parseFromString(await response.text(), "text/html")
    } catch (_e) {
      return this.reload()
    }

    const changed = backfillLiveRegions(fresh)
    this.dispatch("recovered", { detail: { socketWasOpen: false, changed } })
  }

  // The fallback, and the whole of what this controller used to do. Recovers
  // everything and costs the reader their place, so it is reached only when the
  // backfill could not run at all.
  reload() {
    Turbo.visit(window.location.href, { action: "replace" })
  }
}
