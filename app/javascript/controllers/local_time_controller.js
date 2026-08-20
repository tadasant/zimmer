import { Controller } from "@hotwired/stimulus"

// Rewrites a server-rendered UTC timestamp into the viewer's local wall clock.
//
// The server has no timezone for the reader, so the element ships with readable
// UTC text ("Aug 20, 02:12 UTC") and this rewrites it in place once the browser
// — which does know — has it. If this never runs the note is still correct, just
// in UTC. The title attribute keeps the UTC reading available on hover either way.
//
// Usage: <time datetime="2026-08-20T02:12:00Z" data-controller="local-time">
export default class extends Controller {
  connect() {
    const iso = this.element.getAttribute("datetime")
    if (!iso) return

    const date = new Date(iso)
    if (isNaN(date.getTime())) return

    this.element.textContent = date.toLocaleString([], {
      month: "short",
      day: "numeric",
      hour: "numeric",
      minute: "2-digit"
    })
  }
}
