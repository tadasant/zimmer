import { Controller } from "@hotwired/stimulus"
import { csrfHeaders } from "lib/csrf"

// Connects to data-controller="editable-effort"
// Inline editor for the reasoning-effort level on the session detail page. The
// server owns the rules (Sessions::UpdateEffort): the options rendered are the
// levels the session's model takes, and "default" clears the override.
export default class extends Controller {
  static targets = ["display", "editor", "select", "status"]
  static values = { sessionId: Number }

  edit() {
    this.displayTarget.classList.add("hidden")
    this.editorTarget.classList.remove("hidden")
  }

  cancel() {
    this.editorTarget.classList.add("hidden")
    this.displayTarget.classList.remove("hidden")
    this.statusTarget.textContent = ""
  }

  async save() {
    this.statusTarget.textContent = "Saving..."
    this.statusTarget.className = "text-xs text-gray-500 ml-2 self-center"

    try {
      const response = await fetch(`/sessions/${this.sessionIdValue}/update_effort`, {
        method: "PATCH",
        headers: csrfHeaders({ "Accept": "application/json" }),
        body: JSON.stringify({ effort: this.selectTarget.value })
      })
      const data = await response.json()

      if (response.ok) {
        const value = this.displayTarget.querySelector("[data-role='effort-value']")
        if (value) value.textContent = data.description
        this.cancel()
      } else {
        this.statusTarget.textContent = data.error || "Failed to update"
        this.statusTarget.className = "text-xs text-red-600 ml-2 self-center"
      }
    } catch (error) {
      this.statusTarget.textContent = "Network error"
      this.statusTarget.className = "text-xs text-red-600 ml-2 self-center"
    }
  }
}
