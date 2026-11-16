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
//      request made here is an ordinary GET of the same URL, which does both. It
//      goes out at once and is not cancelled if the reader closes the drawer a
//      second later: a quick look is still a look.
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
// The marker removes itself as it starts, so a Turbo snapshot taken while the
// request is out cannot carry it into a later restore and count the view twice.
export default class extends Controller {
  static values = {
    url: String,
    // The Turbo-Frame header the drawer's frame load sends; the cached copy is
    // keyed on it (Vary: Turbo-Frame), so the refreshed copy should be too.
    frame: String,
    fetchTimeout: { type: Number, default: 10000 }
  }

  connect() {
    const detailRoot = this.element.closest("[data-current-session-id]")
    const request = { url: this.urlValue, frame: this.frameValue, timeout: this.fetchTimeoutValue }
    this.element.remove()
    activate(request, detailRoot)
  }
}

function whenShown() {
  if (!document.prerendering) return Promise.resolve()
  return new Promise((resolve) => document.addEventListener("prerenderingchange", resolve, { once: true }))
}

async function activate({ url, frame, timeout }, detailRoot) {
  try {
    await whenShown()

    const headers = { Accept: "text/html, application/xhtml+xml" }
    if (frame) headers["Turbo-Frame"] = frame

    // `reload` goes to the network and stores what comes back, so the cached
    // prefetch copy is replaced by an ordinary must-revalidate one and the next
    // load of this URL does not repeat the stale paint.
    const response = await fetch(url, {
      headers,
      credentials: "same-origin",
      cache: "reload",
      signal: typeof AbortSignal.timeout === "function" ? AbortSignal.timeout(timeout) : undefined
    })
    if (!response.ok || response.redirected) return

    const fresh = new DOMParser().parseFromString(await response.text(), "text/html")
    // Closed or navigated away while the request was out: the view is recorded,
    // and there is nothing on screen left to bring up to date.
    if (!detailRoot?.isConnected) return

    const changed = backfillLiveRegions(fresh, { within: detailRoot })
    detailRoot.dispatchEvent(new CustomEvent("session-activation:activated", { bubbles: true, detail: { changed } }))
  } catch (error) {
    // The body on screen is still a real, recent render with live
    // subscriptions; a failed catch-up is not worth more than a note.
    console.warn("[session-activation] could not refresh a prefetched session page", error)
  }
}
