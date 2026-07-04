import { Controller } from "@hotwired/stimulus"

// Page-level "click to pick a blocker" interaction for the sessions index.
//
// Clicking a session's lock button (block-picker#start) puts the whole index
// into selection mode: every session card becomes clickable and a banner
// explains what to do. Clicking any card then marks that card's session as the
// blocker of the session whose lock was clicked — no manual ID entry.
//
// The controller lives on the index wrapper so a single capture-phase click
// listener can intercept clicks on any card across both the individual and
// grouped views. Cards expose their session id via data-block-picker-card-id.
export default class extends Controller {
  static targets = ["banner", "label"]
  static values = {
    active: { type: Boolean, default: false },
    blockedId: Number,
    markUrlTemplate: String
  }

  // Enter selection mode for the session whose lock button was clicked.
  start(event) {
    event.preventDefault()
    event.stopPropagation()
    this.blockedIdValue = Number(event.params.id)
    this.activeValue = true
  }

  // Leave selection mode without making a change.
  cancel(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }
    this.activeValue = false
  }

  // Capture-phase click handler. While selecting, a click on any card resolves
  // to that card's session and uses it as the blocker, swallowing the click so
  // the card's own links/buttons don't fire.
  onClick(event) {
    if (!this.activeValue) return
    if (this.hasBannerTarget && this.bannerTarget.contains(event.target)) return

    const card = event.target.closest("[data-block-picker-card-id]")
    if (!card) return

    event.preventDefault()
    event.stopPropagation()

    const blockerId = Number(card.dataset.blockPickerCardId)
    if (!blockerId || blockerId === this.blockedIdValue) {
      // A session cannot be blocked by itself — ignore and keep selecting.
      return
    }
    this.submit(blockerId)
  }

  async submit(blockerId) {
    const url = this.markUrlTemplateValue.replace("__ID__", String(this.blockedIdValue))
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content

    try {
      const response = await fetch(url, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken,
          "Accept": "application/json"
        },
        body: JSON.stringify({ blocked_by_session_id: blockerId })
      })
      if (response.ok) {
        window.location.reload()
      } else {
        const data = await response.json().catch(() => ({}))
        alert(data.error || "Failed to mark session as blocked")
        this.activeValue = false
      }
    } catch (error) {
      console.error("Error marking session as blocked:", error)
      alert("Failed to mark session as blocked. Check the console for details.")
      this.activeValue = false
    }
  }

  activeValueChanged() {
    this.element.classList.toggle("block-picking", this.activeValue)
    if (this.hasBannerTarget) {
      this.bannerTarget.classList.toggle("hidden", !this.activeValue)
    }
    if (this.activeValue && this.hasLabelTarget) {
      this.labelTarget.textContent =
        `Select the session that is blocking #${this.blockedIdValue} — click any session card.`
    }
  }

  onKeydown(event) {
    if (event.key === "Escape" && this.activeValue) {
      this.cancel()
    }
  }

  connect() {
    this.boundClick = this.onClick.bind(this)
    this.element.addEventListener("click", this.boundClick, { capture: true })
    this.boundKeydown = this.onKeydown.bind(this)
    document.addEventListener("keydown", this.boundKeydown)
  }

  disconnect() {
    this.element.removeEventListener("click", this.boundClick, { capture: true })
    document.removeEventListener("keydown", this.boundKeydown)
  }
}
