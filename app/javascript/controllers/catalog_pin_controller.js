import { Controller } from "@hotwired/stimulus"

// Drives one catalog-pin row on the settings page. "Pin to current HEAD" copies
// the live resolved SHA into the ref input; "Clear" empties it. Submitting the
// surrounding form persists the values.
export default class extends Controller {
  static targets = ["input"]
  static values = { head: String }

  pinToHead() {
    if (this.hasInputTarget && this.headValue) {
      this.inputTarget.value = this.headValue
      this.inputTarget.focus()
    }
  }

  clear() {
    if (this.hasInputTarget) {
      this.inputTarget.value = ""
      this.inputTarget.focus()
    }
  }
}
