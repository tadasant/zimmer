import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="status-panel"
//
// The summary's markdown is rendered by the shared renderer, which stamps
// target="_blank" on every link — correct for the PR and CI links that make up
// most of a summary, absurd for a `#message-214` anchor that points at the
// Transcript panel a few hundred pixels further down the same card.
//
// Rather than fork the shared renderer (and with it its safe_links_only
// enforcement), this intercepts clicks on those anchors and hands the fragment
// straight to the sibling transcript-panel controller. Going through the URL
// instead would push a history entry per click and, in the dashboard drawer,
// rewrite the dashboard's own URL.
export default class extends Controller {
  static MESSAGE_FRAGMENT = /^#message-\d+$/

  followFragment(event) {
    const anchor = event.target.closest("a")
    if (!anchor) return

    const href = anchor.getAttribute("href")
    if (!this.constructor.MESSAGE_FRAGMENT.test(href || "")) return

    const transcript = this.transcriptController
    if (!transcript) return

    event.preventDefault()
    transcript.reveal(href)
  }

  // The transcript panel is a sibling section of the same card, so it is reached
  // through their shared container rather than by DOM ancestry. Scoping the
  // lookup to that container is what keeps a drawer copy from driving the
  // full-page copy's transcript.
  get transcriptController() {
    const group = this.element.closest("[data-session-panels]")
    const details = group?.querySelector("details[data-controller~='transcript-panel']")
    if (!details) return null

    return this.application.getControllerForElementAndIdentifier(details, "transcript-panel")
  }
}
