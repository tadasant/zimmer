import { Controller } from "@hotwired/stimulus"

// Model selector for the new session form.
//
// Keeps the model dropdown scoped to the selected runtime and in sync with the
// chosen agent root. Reacts to two document-level events broadcast by sibling
// controllers (which live outside this controller's DOM subtree):
//   - "ao:runtime-changed"     → rebuild options from the runtime's catalog
//   - "ao:agent-root-changed"  → select that root's default model when compatible
export default class extends Controller {
  static targets = ["select", "hiddenField"]
  static values = {
    agentRootDefaults: Object, // { agentRootName: "opus", ... }
    runtimeModels: Object,     // { claude_code: ["opus", "sonnet", "haiku"], ... }
    runtimeDefaults: Object,   // { claude_code: "opus", ... }
    runtime: String            // currently selected runtime
  }

  connect() {
    this.boundRuntimeChanged = this.handleRuntimeChanged.bind(this)
    this.boundAgentRootChanged = this.handleAgentRootChanged.bind(this)
    document.addEventListener("ao:runtime-changed", this.boundRuntimeChanged)
    document.addEventListener("ao:agent-root-changed", this.boundAgentRootChanged)
  }

  disconnect() {
    document.removeEventListener("ao:runtime-changed", this.boundRuntimeChanged)
    document.removeEventListener("ao:agent-root-changed", this.boundAgentRootChanged)
  }

  handleRuntimeChanged(event) {
    const runtime = event.detail?.runtime
    if (!runtime) return

    this.runtimeValue = runtime
    this.renderOptions(runtime)

    // Reset to the runtime's default model — the previously selected model may
    // not belong to the new runtime's catalog.
    const fallback = this.runtimeDefaultsValue[runtime]
    if (fallback) this.setModel(fallback)
  }

  handleAgentRootChanged(event) {
    const agentRootName = event.detail?.agentRootName
    if (!agentRootName) return

    const allowed = this.modelsForCurrentRuntime()
    const rootDefault = this.agentRootDefaultsValue[agentRootName]
    const model = allowed.includes(rootDefault)
      ? rootDefault
      : this.runtimeDefaultsValue[this.runtimeValue]
    if (model) this.setModel(model)
  }

  // Update the submitted value when the user picks a model directly.
  updateHiddenField() {
    this.hiddenFieldTarget.value = this.selectTarget.value
  }

  modelsForCurrentRuntime() {
    return this.runtimeModelsValue[this.runtimeValue] || []
  }

  renderOptions(runtime) {
    const models = this.runtimeModelsValue[runtime] || []
    this.selectTarget.innerHTML = models
      .map(model => `<option value="${model}">${model}</option>`)
      .join("")
  }

  setModel(model) {
    this.selectTarget.value = model
    this.hiddenFieldTarget.value = model
  }
}
