import { Controller } from "@hotwired/stimulus"
import { backfillLiveRegions } from "lib/live_region_backfill"

// Connects to data-controller="session-activation"
//
// Rendered only into a session detail body that answered a background prefetch
// (SessionsController#allow_prefetch_reuse). The dashboard's list fetched that
// body before anyone clicked, and the browser may show it from its HTTP cache
// for a couple of minutes afterwards. Two things follow from that, and this
// controller answers both once the body is actually on screen:
//
//   1. The server never saw the click. A prefetch is not a view, so it skipped
//      marking the session's notifications read and recording the touch. The
//      request made here is an ordinary GET of the same URL, which does both.
//   2. The body may be up to two minutes old. Its Turbo Stream subscriptions only
//      carry what is broadcast from now on, so the same request's answer is
//      reconciled into the page's `data-live-region`s (lib/live_region_backfill),
//      in place: no navigation, no lost scroll position or open disclosure.
//
// Nothing here runs while the body is only cached — a response in the HTTP cache
// is bytes, not a document, so there is no socket, no polling, no deferred-panel
// fetch until the body is rendered. A page the browser prerenders on its own
// (Chrome's omnibox does) waits for `prerenderingchange` before it counts.
//
// The marker removes itself afterwards, so a Turbo snapshot of the page does not
// carry it into a later restore.
// The controller's own signal, also aborted after `ms`. AbortSignal.any is
// Safari 17.4+; an older browser keeps the disconnect abort and loses the timeout.
function withTimeout(signal, ms) {
  if (typeof AbortSignal.any !== "function" || typeof AbortSignal.timeout !== "function") return signal
  return AbortSignal.any([signal, AbortSignal.timeout(ms)])
}

export default class extends Controller {
  static values = {
    url: String,
    // The Turbo-Frame header the drawer's frame load sends; the cached copy is
    // keyed on it (Vary: Turbo-Frame), so the refreshed copy should be too.
    frame: String,
    // How long to wait for the body's stream subscriptions to be confirmed
    // before asking for the fresh copy. Waiting first means an update broadcast
    // while the request is in flight still has a subscription to arrive on.
    subscribeTimeout: { type: Number, default: 2000 },
    fetchTimeout: { type: Number, default: 10000 }
  }

  connect() {
    this.abortController = new AbortController()
    this.activate()
  }

  disconnect() {
    this.abortController.abort()
    clearTimeout(this.pollTimer)
  }

  async activate() {
    const signal = this.abortController.signal
    try {
      await this.whenShown()
      await this.whenSubscribed()
      if (signal.aborted) return

      const headers = { Accept: "text/html, application/xhtml+xml" }
      if (this.frameValue) headers["Turbo-Frame"] = this.frameValue

      // `reload` goes to the network and stores what comes back, so the cached
      // prefetch copy is replaced by an ordinary must-revalidate one and the next
      // load of this URL does not repeat the stale paint.
      const response = await fetch(this.urlValue, {
        headers,
        credentials: "same-origin",
        cache: "reload",
        signal: withTimeout(signal, this.fetchTimeoutValue)
      })
      if (!response.ok || response.redirected) return

      const fresh = new DOMParser().parseFromString(await response.text(), "text/html")
      if (signal.aborted) return

      const changed = backfillLiveRegions(fresh, { within: this.detailRoot })
      this.dispatch("activated", { detail: { changed } })
    } catch (error) {
      // The body on screen is still a real, recent render with live
      // subscriptions; a failed catch-up is not worth more than a note.
      if (!signal.aborted) console.warn("[session-activation] could not refresh a prefetched session page", error)
    } finally {
      if (!signal.aborted) this.element.remove()
    }
  }

  get detailRoot() {
    return this.element.closest("[data-current-session-id]") || document
  }

  whenShown() {
    if (!document.prerendering) return Promise.resolve()
    return new Promise((resolve) => document.addEventListener("prerenderingchange", resolve, { once: true }))
  }

  whenSubscribed() {
    const sources = Array.from(this.detailRoot.querySelectorAll("turbo-cable-stream-source"))
    const deadline = Date.now() + this.subscribeTimeoutValue
    return new Promise((resolve) => {
      const check = () => {
        const ready = sources.every((source) => source.hasAttribute("connected"))
        if (ready || Date.now() >= deadline || this.abortController.signal.aborted) return resolve()
        this.pollTimer = setTimeout(check, 50)
      }
      check()
    })
  }
}
