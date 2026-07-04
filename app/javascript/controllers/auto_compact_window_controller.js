import { Controller } from "@hotwired/stimulus"

// Toggles the auto-compact-window field based on the selected runtime.
//
// Only Claude Code honors CLAUDE_CODE_AUTO_COMPACT_WINDOW; other runtimes
// (e.g. Codex) have no auto-compact-window analog, so the field is hidden and
// disabled for them. A disabled input is omitted from the form submit, so the
// session keeps the column default rather than persisting a value the runtime
// would ignore. Reacts to the document-level "ao:runtime-changed" event
// broadcast by the runtime-select controller (a sibling DOM subtree).
export default class extends Controller {
  static targets = ["input"]
  static values = { runtime: String }

  connect() {
    this.boundRuntimeChanged = this.handleRuntimeChanged.bind(this)
    document.addEventListener("ao:runtime-changed", this.boundRuntimeChanged)
    this.applyVisibility(this.runtimeValue)
  }

  disconnect() {
    document.removeEventListener("ao:runtime-changed", this.boundRuntimeChanged)
  }

  handleRuntimeChanged(event) {
    const runtime = event.detail?.runtime
    if (!runtime) return
    this.applyVisibility(runtime)
  }

  applyVisibility(runtime) {
    const enabled = runtime === "claude_code"
    this.element.classList.toggle("hidden", !enabled)
    this.inputTarget.disabled = !enabled
  }
}
