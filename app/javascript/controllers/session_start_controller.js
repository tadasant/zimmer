import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"
import { currentStart, retryStart, forgetStart, subscribe, DRAFT_KEY } from "lib/session_starts"

// Connects to data-controller="session-start", on /sessions/starting.
//
// The page a start opens on before the server has answered with the session's
// id (see lib/session_starts.js). It shows the words on their way and where the
// start stands; when the id comes it visits the session, replacing itself in
// history so Back is the board; when the server refuses it says why, with Try
// again and Edit (the words back in the board's prompt box).
export default class extends Controller {
  static targets = ["title", "prompt", "pending", "failed", "error", "nothing"]

  connect() {
    const start = currentStart()
    if (!start) {
      // A reload, or a visit by URL: the module's state did not survive. The board
      // lists the session if the server took the start.
      this.nothingTarget.classList.remove("hidden")
      this.pendingTarget.classList.add("hidden")
      return
    }
    this.titleTarget.textContent = start.title
    this.promptTarget.textContent = start.prompt
    this.unsubscribe = subscribe(start, (state) => this.render(state))
  }

  disconnect() {
    this.unsubscribe?.()
  }

  render(start) {
    switch (start.state) {
      case "started":
        this.unsubscribe?.()
        forgetStart()
        Turbo.visit(start.url, { action: "replace" })
        break
      case "failed":
        this.pendingTarget.classList.add("hidden")
        this.failedTarget.classList.remove("hidden")
        this.errorTarget.textContent = start.error
        break
      default:
        this.failedTarget.classList.add("hidden")
        this.pendingTarget.classList.remove("hidden")
    }
  }

  retry() {
    retryStart()
  }

  // The words back where they were typed, for another go.
  edit() {
    const start = currentStart()
    if (start) {
      try { sessionStorage.setItem(DRAFT_KEY, start.prompt) } catch (error) { /* a private window with no storage: the words go with the visit below */ }
    }
    forgetStart()
    Turbo.visit("/", { action: "replace" })
  }
}
