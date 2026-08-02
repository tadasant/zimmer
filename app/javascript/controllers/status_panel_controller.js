import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="status-panel"
//
// The summary's markdown is rendered by the shared renderer, which stamps
// target="_blank" on every link — correct for the PR and CI links that make up
// most of a summary, absurd for a `#message-214` anchor that points at the
// transcript panel further down this same page.
//
// Rather than fork the shared renderer (and with it its safe_links_only
// enforcement), this intercepts clicks on same-page fragment links inside the
// panel and turns them into a hash change. The transcript-panel controller
// listens for that, opens itself, and scrolls the message into view.
export default class extends Controller {
  followFragment(event) {
    const anchor = event.target.closest("a")
    if (!anchor) return

    const href = anchor.getAttribute("href")
    if (!href || !href.startsWith("#message-")) return

    event.preventDefault()
    // Assigning the same hash twice fires no hashchange, so clear it first —
    // clicking the same link twice should re-scroll to the message.
    if (window.location.hash === href) window.location.hash = ""
    window.location.hash = href
  }
}
