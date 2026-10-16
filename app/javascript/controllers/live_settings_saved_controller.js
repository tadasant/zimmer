import { Controller } from "@hotwired/stimulus"

// Rendered on /live/settings right after a save. Tells the call dock
// (live_voice_controller.js) the Live settings changed, so an open voice call
// fetches and sends a fresh session.update instead of waiting for the next call.
export default class extends Controller {
  connect() {
    window.dispatchEvent(new CustomEvent("live-voice:settings-changed"))
  }
}
