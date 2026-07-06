import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="editable-model"
// Inline editor for the model on the session detail page
export default class extends Controller {
  static targets = ["display", "editor", "select", "status"]
  static values = {
    sessionId: Number,
    model: String, // Currently selected model
    availableModels: Array // Array of model identifier strings
  }

  connect() {
    this.isEditing = false
  }

  edit() {
    this.isEditing = true
    this.displayTarget.classList.add("hidden")
    this.editorTarget.classList.remove("hidden")

    // Set the select to current model value
    this.selectTarget.value = this.modelValue || ""
  }

  cancel() {
    this.isEditing = false
    this.editorTarget.classList.add("hidden")
    this.displayTarget.classList.remove("hidden")
    this.statusTarget.textContent = ""
  }

  async save() {
    const newModel = this.selectTarget.value
    if (!newModel) return

    // Guard: only models in this session's runtime catalog are submittable.
    const allowed = this.availableModelsValue || []
    if (allowed.length > 0 && !allowed.includes(newModel)) {
      this.statusTarget.textContent = "Invalid model for this runtime"
      this.statusTarget.className = "text-xs text-red-600 ml-2 self-center"
      return
    }

    this.statusTarget.textContent = "Saving..."
    this.statusTarget.className = "text-xs text-gray-500 ml-2 self-center"

    try {
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
      const response = await fetch(`/sessions/${this.sessionIdValue}/update_model`, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken,
          "Accept": "application/json"
        },
        body: JSON.stringify({ model: newModel })
      })

      const data = await response.json()

      if (response.ok) {
        this.modelValue = newModel
        this.updateDisplay(newModel)
        this.cancel()

        // Brief success indicator
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

  updateDisplay(model) {
    const displayText = this.displayTarget.querySelector("[data-role='model-value']")
    if (displayText) {
      displayText.textContent = model
    }
  }
}
