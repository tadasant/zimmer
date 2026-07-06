import { Controller } from "@hotwired/stimulus"

// Handles agent root selection and updates the hidden agent root name field
export default class extends Controller {
  static targets = ["nameField"]

  updateName(event) {
    const agentRootName = event.target.dataset.agentRootName
    if (agentRootName && this.hasNameFieldTarget) {
      this.nameFieldTarget.value = agentRootName
    }
  }
}
