import { Controller } from "@hotwired/stimulus"

// The Quick Router's Advanced accordion (app/views/sessions/_quick_router_advanced).
//
// Its whole job is that the two pickers cannot disagree: a model id belongs to
// exactly one runtime's catalog, so picking a harness rebuilds the model list
// from that runtime's models and drops any model the old runtime had. The server
// validates the pair again regardless of what is posted — this only stops the UI
// from producing the mismatch in the first place.
//
// Blank is the default in both pickers, and it NAMES the fallback rather than
// selecting it ("Default (Claude Code)", "Default (opus)"), so an untouched
// accordion posts nothing and the ordinary create-time resolution applies.
//
// Mounted on the <details> itself, so `reset()` can re-collapse it. The two
// surfaces that close — the dashboard's phone overlay and the chat bubble — fire
// a `quick-router-advanced:reset` event at this element rather than reaching into
// its controls, which keeps the panel's notion of "back to defaults" in one place.
export default class extends Controller {
  static targets = ["runtime", "model", "spot"]

  static values = {
    defaultRuntime: String,      // the router root's runtime — what blank means
    runtimeModels: Object,       // { claude_code: [{ id, label }, ...], ... }
    runtimeDefaultModels: Object // { claude_code: "opus", ... }
  }

  runtimeChanged() {
    this.renderModelOptions()
  }

  // Back to the state a fresh render produces: collapsed, both pickers on their
  // blank "Default (…)" option, spot unticked. Per-submission knobs, not sticky
  // preferences.
  reset() {
    if (this.hasRuntimeTarget) this.runtimeTarget.value = ""
    if (this.hasSpotTarget) this.spotTarget.checked = false
    this.renderModelOptions()
    this.element.open = false
  }

  // The runtime this submission would actually run on: the picked one, or the
  // router root's when the picker is still blank.
  effectiveRuntime() {
    const picked = this.hasRuntimeTarget ? this.runtimeTarget.value : ""
    return picked || this.defaultRuntimeValue
  }

  // Rebuilds the model <select> for the effective runtime, always landing back on
  // the blank option: the model that was selected belonged to the previous
  // runtime's catalog and carrying it over is exactly the mismatch to avoid.
  //
  // Renders the catalog's LABEL, not the bare id. On Codex and Pi the label is the
  // only place a model says it needs a ChatGPT login or is deprecated
  // ("gpt-5.6-terra (default, ChatGPT auth)", "gpt-5.3-codex (deprecated)"), and
  // the harness picker is what makes those two reachable here at all.
  //
  // A runtime the map does not carry offers nothing rather than falling back to
  // another runtime's list — the same answer QuickRouterOptions#resolve_model
  // gives on the same miss, so the picker and the server never disagree.
  renderModelOptions() {
    if (!this.hasModelTarget) return

    const runtime = this.effectiveRuntime()
    const models = this.runtimeModelsValue[runtime] || []
    const fallback = this.runtimeDefaultModelsValue[runtime]

    const blankLabel = fallback ? `Default (${fallback})` : "Default"
    const options = [`<option value="">${this._escape(blankLabel)}</option>`].concat(
      models.map(model => `<option value="${this._escape(model.id)}">${this._escape(model.label || model.id)}</option>`)
    )

    this.modelTarget.innerHTML = options.join("")
    this.modelTarget.value = ""
  }

  _escape(value) {
    return String(value).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;" }[c]))
  }
}
