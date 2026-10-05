import { Controller } from "@hotwired/stimulus"

// Reasoning-effort picker for the new session form.
//
// The levels a session may set depend on its model, so the options follow the
// model picker through the document-level "ao:model-changed" event that
// model-select broadcasts. For a model that takes no effort setting the field
// is hidden and disabled, so it is left out of the submit entirely. The empty
// "Default" option submits nothing either, leaving the model's own level.
export default class extends Controller {
  static targets = ["select"]
  static values = {
    options: Object, // { runtime: { model: { levels: [...], default: "high" } } }
    runtime: String,
    model: String
  }

  connect() {
    this.boundModelChanged = this.handleModelChanged.bind(this)
    document.addEventListener("ao:model-changed", this.boundModelChanged)
  }

  disconnect() {
    document.removeEventListener("ao:model-changed", this.boundModelChanged)
  }

  handleModelChanged(event) {
    const { runtime, model } = event.detail || {}
    if (!runtime) return

    this.runtimeValue = runtime
    this.modelValue = model || ""
    this.render()
  }

  render() {
    const choice = (this.optionsValue[this.runtimeValue] || {})[this.modelValue]
    const enabled = Boolean(choice)
    this.element.classList.toggle("hidden", !enabled)
    this.selectTarget.disabled = !enabled
    if (!enabled) {
      this.selectTarget.innerHTML = ""
      return
    }

    // Keep the chosen level when the new model takes it too.
    const previous = this.selectTarget.value
    const options = [`<option value="">Default (${choice.default})</option>`]
      .concat(choice.levels.map(level => `<option value="${level}">${level}</option>`))
    this.selectTarget.innerHTML = options.join("")
    this.selectTarget.value = choice.levels.includes(previous) ? previous : ""
  }
}
