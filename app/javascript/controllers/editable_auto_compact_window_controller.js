import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="editable-auto-compact-window"
// Inline editor for the Claude Code context window (auto_compact_window) on the
// session detail page. Mirrors editable_model_controller.js.
//
// The value is consumed as CLAUDE_CODE_AUTO_COMPACT_WINDOW at process spawn
// time, so a change takes effect on the next turn / restart — not on the
// currently running process. The display hint communicates this.
export default class extends Controller {
  static targets = ["display", "editor", "input", "status", "value"]
  static values = {
    sessionId: Number,
    window: Number, // Currently persisted auto_compact_window
    max: Number // Upper bound (matches Session::MAX_AUTO_COMPACT_WINDOW)
  }

  connect() {
    this.isEditing = false
  }

  edit() {
    this.isEditing = true
    this.displayTarget.classList.add("hidden")
    this.editorTarget.classList.remove("hidden")

    // Seed the input with the current value
    this.inputTarget.value = this.windowValue || ""
    this.inputTarget.focus()
  }

  cancel() {
    this.isEditing = false
    this.editorTarget.classList.add("hidden")
    this.displayTarget.classList.remove("hidden")
    this.statusTarget.textContent = ""
  }

  async save() {
    const newWindow = parseInt(this.inputTarget.value, 10)
    const max = this.maxValue || 1000000

    if (!Number.isInteger(newWindow) || newWindow <= 0 || newWindow > max) {
      this.statusTarget.textContent = `Enter an integer between 1 and ${max.toLocaleString()}`
      this.statusTarget.className = "text-xs text-red-600 ml-2 self-center"
      return
    }

    this.statusTarget.textContent = "Saving..."
    this.statusTarget.className = "text-xs text-gray-500 ml-2 self-center"

    try {
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
      const response = await fetch(`/sessions/${this.sessionIdValue}/update_auto_compact_window`, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken,
          "Accept": "application/json"
        },
        body: JSON.stringify({ auto_compact_window: newWindow })
      })

      const data = await response.json()

      if (response.ok) {
        this.windowValue = data.auto_compact_window
        this.updateDisplay(data.auto_compact_window)
        this.cancel()
        this.statusTarget.textContent = ""
      } else {
        this.statusTarget.textContent = data.error || "Failed to update"
        this.statusTarget.className = "text-xs text-red-600 ml-2 self-center"
      }
    } catch (error) {
      this.statusTarget.textContent = "Network error"
      this.statusTarget.className = "text-xs text-red-600 ml-2 self-center"
    }
  }

  updateDisplay(window) {
    if (this.hasValueTarget) {
      this.valueTarget.textContent = Number(window).toLocaleString()
    }
  }
}
