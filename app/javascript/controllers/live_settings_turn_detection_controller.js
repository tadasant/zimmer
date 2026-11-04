import { Controller } from "@hotwired/stimulus"

// The Voice section of /live/settings. Marks which turn detection settings apply
// under the mode selected in the form, before anything is saved. The page renders
// the saved mode's state; this keeps it true as the select moves. A setting with
// no effect stays editable, so it can be set ahead of a switch.
export default class extends Controller {
  static targets = ["mode", "knob", "modeNote"]
  static values = { default: String }

  connect() {
    this.update()
  }

  update() {
    const mode = this.modeTarget.value || this.defaultValue

    this.knobTargets.forEach((knob) => {
      const applies = knob.dataset.appliesUnder === mode
      knob.querySelector("[data-knob-badge='active']").classList.toggle("hidden", !applies)
      knob.querySelector("[data-knob-badge='inactive']").classList.toggle("hidden", applies)
    })
    this.modeNoteTargets.forEach((note) => note.classList.toggle("hidden", note.dataset.mode !== mode))
  }
}
