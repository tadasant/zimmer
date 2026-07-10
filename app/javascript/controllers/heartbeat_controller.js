import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="heartbeat"
//
// Per-session heartbeat control: a heart icon next to the favorite star with a
// popout to configure how often the heartbeat beats. Clicking the heart when the
// heartbeat is OFF turns it on and opens the popout; clicking when ON just opens
// the popout (where the interval can be changed or the heartbeat turned off).
//
// State is persisted through the web endpoints (JSON), and the icon/popout are
// updated in place client-side — the popout is never blown away by a server
// re-render. Mirrors editable_auto_compact_window_controller.js.
export default class extends Controller {
  static targets = [
    "button", "filledIcon", "outlineIcon", "popover",
    "intervalSelect", "statusBadge", "enableButton", "disableButton", "status"
  ]
  static values = {
    sessionId: Number,
    enabled: Boolean,
    intervalSeconds: Number
  }

  connect() {
    this._outsideClick = this._outsideClick.bind(this)
  }

  disconnect() {
    document.removeEventListener("click", this._outsideClick)
  }

  // Heart icon click: open the popout, turning the heartbeat on if it was off.
  toggle(event) {
    event.preventDefault()
    event.stopPropagation()
    if (this.popoverTarget.classList.contains("hidden")) {
      this._openPopover()
      if (!this.enabledValue) {
        this.setEnabled(true)
      }
    } else {
      this._closePopover()
    }
  }

  enable() {
    this.setEnabled(true)
  }

  disable() {
    // Close the popout when turning off so the control returns to a clean "off"
    // state. (Leaving it open would let a subsequent heart click — which
    // re-opens and re-enables an off heartbeat — silently turn it back on.)
    this.setEnabled(false)
    this._closePopover()
  }

  async setEnabled(enabled) {
    this._setStatus("Saving…")
    const data = await this._patch(`/sessions/${this.sessionIdValue}/toggle_heartbeat`, { enabled })
    if (data) {
      this.enabledValue = data.heartbeat_enabled
      this._applyEnabledState(data.heartbeat_enabled)
      this._setStatus("")
    }
  }

  async changeInterval() {
    const seconds = parseInt(this.intervalSelectTarget.value, 10)
    this._setStatus("Saving…")
    const data = await this._patch(`/sessions/${this.sessionIdValue}/update_heartbeat_interval`, {
      heartbeat_interval_seconds: seconds
    })
    if (data) {
      this.intervalSecondsValue = data.heartbeat_interval_seconds
      this._setStatus("Saved")
      setTimeout(() => this._setStatus(""), 1200)
    }
  }

  // --- helpers ---

  _openPopover() {
    this.popoverTarget.classList.remove("hidden")
    // Defer so the click that opened the popover doesn't immediately close it.
    setTimeout(() => document.addEventListener("click", this._outsideClick), 0)
  }

  _closePopover() {
    this.popoverTarget.classList.add("hidden")
    document.removeEventListener("click", this._outsideClick)
  }

  _outsideClick(event) {
    if (!this.element.contains(event.target)) {
      this._closePopover()
    }
  }

  _applyEnabledState(enabled) {
    // Icon: filled red heart when on, gray outline when off.
    this.filledIconTarget.classList.toggle("hidden", !enabled)
    this.outlineIconTarget.classList.toggle("hidden", enabled)
    this.buttonTarget.classList.toggle("text-red-500", enabled)
    this.buttonTarget.classList.toggle("text-gray-300", !enabled)
    this.buttonTarget.setAttribute("aria-pressed", String(enabled))
    this.buttonTarget.setAttribute(
      "title",
      enabled ? "Heartbeat on — click to configure" : "Heartbeat off — click to enable"
    )

    if (this.hasStatusBadgeTarget) {
      this.statusBadgeTarget.textContent = enabled ? "On" : "Off"
      this.statusBadgeTarget.classList.toggle("bg-red-100", enabled)
      this.statusBadgeTarget.classList.toggle("text-red-700", enabled)
      this.statusBadgeTarget.classList.toggle("bg-gray-100", !enabled)
      this.statusBadgeTarget.classList.toggle("text-gray-500", !enabled)
    }
    if (this.hasEnableButtonTarget) this.enableButtonTarget.classList.toggle("hidden", enabled)
    if (this.hasDisableButtonTarget) this.disableButtonTarget.classList.toggle("hidden", !enabled)
  }

  _setStatus(text) {
    if (this.hasStatusTarget) this.statusTarget.textContent = text
  }

  async _patch(url, body) {
    try {
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
      const response = await fetch(url, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken,
          "Accept": "application/json"
        },
        body: JSON.stringify(body)
      })
      const data = await response.json()
      if (response.ok) return data
      this._setStatus(data.error || "Failed")
      return null
    } catch (error) {
      this._setStatus("Network error")
      return null
    }
  }
}
