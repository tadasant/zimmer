import { Controller } from "@hotwired/stimulus"

// Runtime selector for the new session form.
//
// Broadcasts a document-level "ao:runtime-changed" event when the runtime
// changes so the model selector — which lives in a sibling DOM subtree, not
// inside this controller — can swap to the runtime's model catalog without
// being coupled through the DOM hierarchy. The agent-root list is deliberately
// runtime-independent (a root's runtime is a per-session override), so the root
// selector does not listen. The <select> itself submits as `agent_runtime`.
export default class extends Controller {
  static targets = ["select"]

  change() {
    document.dispatchEvent(
      new CustomEvent("ao:runtime-changed", {
        detail: { runtime: this.selectTarget.value }
      })
    )
  }
}
