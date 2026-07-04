import { Controller } from "@hotwired/stimulus"

// Mobile session-detail joystick menu.
//
// One floating bubble (bottom-right). Tap-and-hold to fan out radial petals
// up-and-to-the-left toward the thumb; drag onto a petal to highlight; release
// to commit. The "View PR" petal expands a second-layer sub-arc when the
// session has more than one PR attached. A quick tap (no drag) opens a
// bottom-sheet list as the accessibility fallback.
//
// The page-global chat-bubble FAB and notes-drawer toggle are suppressed on
// mobile by server-rendered CSS in the _mobile_joystick partial (not from this
// controller) so the redundant FABs can't stack over the radial trigger and
// swallow its taps — see the comment on that <style> block for why CSS beats a
// JS hook here (the chat-bubble is turbo-permanent).
export default class extends Controller {
  static targets = [
    "trigger",
    "overlay",
    "petals",
    "petal",
    "subArc",
    "subPetals",
    "sheet",
    "sheetOverlay",
    "modalRoot"
  ]

  static values = {
    prUrls: { type: Array, default: [] },
    prLabels: { type: Object, default: {} }
  }

  connect() {
    this.expanded = false
    this.activePetal = null
    this.activeSubPetal = null
    this.subArcOpen = false
    this.startX = 0
    this.startY = 0
    this.dragged = false
    this.DRAG_THRESHOLD_PX = 12

    // Bind handlers once for add/removeEventListener parity.
    this._onPointerMove = this._onPointerMove.bind(this)
    this._onPointerUp = this._onPointerUp.bind(this)
    this._onKeyDown = this._onKeyDown.bind(this)

    document.addEventListener("keydown", this._onKeyDown)
  }

  disconnect() {
    document.removeEventListener("keydown", this._onKeyDown)
    document.removeEventListener("pointermove", this._onPointerMove)
    document.removeEventListener("pointerup", this._onPointerUp)
    document.removeEventListener("pointercancel", this._onPointerUp)
  }

  _onKeyDown(event) {
    if (event.key === "Escape") {
      if (this.subArcOpen) this._closeSubArc()
      else if (this.expanded) this._collapse()
      else if (this._sheetOpen()) this._closeSheet()
      else this._closeAllModals()
    }
  }

  // ---- Pointer / touch lifecycle ----

  start(event) {
    // Allow keyboard / click-through opens on the trigger button: a plain
    // click (no pointer movement) falls through to `tap` after pointerup.
    event.preventDefault()
    const point = this._point(event)
    this.startX = point.x
    this.startY = point.y
    this.dragged = false
    this.activePetal = null
    this.activeSubPetal = null

    // Begin tracking globally so a finger that leaves the bubble is followed.
    document.addEventListener("pointermove", this._onPointerMove)
    document.addEventListener("pointerup", this._onPointerUp)
    document.addEventListener("pointercancel", this._onPointerUp)

    this._expand()
  }

  _onPointerMove(event) {
    const point = this._point(event)
    const dx = point.x - this.startX
    const dy = point.y - this.startY
    if (!this.dragged && Math.hypot(dx, dy) > this.DRAG_THRESHOLD_PX) {
      this.dragged = true
    }

    // Find the petal (or sub-petal) underneath the pointer.
    const hit = document.elementFromPoint(point.x, point.y)
    const subPetal = hit?.closest("[data-joystick-menu-target='subPetals'] [data-petal-pr-url]")
    const petal = hit?.closest("[data-joystick-menu-target='petal']")

    if (subPetal && this.subArcOpen) {
      this._setActiveSubPetal(subPetal)
    } else if (petal) {
      this._setActiveSubPetal(null)
      this._setActivePetal(petal)
      // Open or close the sub-arc depending on which petal we're over.
      if (petal.dataset.petalKey === "view-pr" && this.prUrlsValue.length > 1) {
        if (!this.subArcOpen) this._openSubArc()
      } else if (this.subArcOpen) {
        this._closeSubArc()
      }
    } else {
      // Pointer is outside any petal.
      if (!this.subArcOpen) {
        this._setActivePetal(null)
      }
    }
  }

  _onPointerUp(event) {
    document.removeEventListener("pointermove", this._onPointerMove)
    document.removeEventListener("pointerup", this._onPointerUp)
    document.removeEventListener("pointercancel", this._onPointerUp)

    if (!this.dragged) {
      // Quick tap: collapse the radial and surface the bottom-sheet fallback.
      this._collapse()
      this._openSheet()
      return
    }

    // Drag-release: commit the highlighted petal (if any).
    if (this.subArcOpen && this.activeSubPetal) {
      const url = this.activeSubPetal.dataset.petalPrUrl
      this._collapseAll()
      if (url) {
        this._touchActivity()
        window.open(url, "_blank", "noopener,noreferrer")
      }
      return
    }
    if (this.activePetal) {
      const key = this.activePetal.dataset.petalKey
      this._collapseAll()
      this._commit(key)
      return
    }

    this._collapseAll()
  }

  _point(event) {
    if (event.touches && event.touches[0]) {
      return { x: event.touches[0].clientX, y: event.touches[0].clientY }
    }
    if (event.changedTouches && event.changedTouches[0]) {
      return { x: event.changedTouches[0].clientX, y: event.changedTouches[0].clientY }
    }
    return { x: event.clientX, y: event.clientY }
  }

  // ---- Expand / collapse ----

  _expand() {
    if (this.expanded) return
    this.expanded = true
    if (this.hasTriggerTarget) this.triggerTarget.setAttribute("aria-expanded", "true")
    this.overlayTarget.classList.remove("pointer-events-none", "opacity-0")
    this.overlayTarget.classList.add("opacity-100")
    this.petalsTargets.forEach((el, i) => {
      el.classList.remove("opacity-0", "pointer-events-none", "scale-50")
      el.classList.add("opacity-100", "scale-100")
    })
    this.petalTargets.forEach((el, i) => {
      // staggered animation via inline transition delay
      el.style.transitionDelay = `${i * 18}ms`
      el.classList.remove("opacity-0", "scale-50", "translate-x-0", "translate-y-0", "pointer-events-none")
      el.classList.add("opacity-100", "scale-100", "pointer-events-auto")
      // apply target offset stored as data attributes
      const tx = el.dataset.targetX || "0"
      const ty = el.dataset.targetY || "0"
      el.style.transform = `translate(${tx}px, ${ty}px)`
    })
  }

  _collapse() {
    if (!this.expanded) return
    this.expanded = false
    if (this.hasTriggerTarget) this.triggerTarget.setAttribute("aria-expanded", "false")
    this.activePetal = null
    this.activeSubPetal = null
    this.overlayTarget.classList.add("opacity-0", "pointer-events-none")
    this.overlayTarget.classList.remove("opacity-100")
    this.petalTargets.forEach((el) => {
      el.style.transitionDelay = "0ms"
      el.style.transform = "translate(0px, 0px)"
      el.classList.add("opacity-0", "scale-50", "pointer-events-none")
      el.classList.remove("opacity-100", "scale-100", "pointer-events-auto")
      el.removeAttribute("data-active")
    })
    this._closeSubArc()
  }

  _collapseAll() {
    this._closeSubArc()
    this._collapse()
  }

  _setActivePetal(petal) {
    if (this.activePetal === petal) return
    if (this.activePetal) this.activePetal.removeAttribute("data-active")
    this.activePetal = petal
    if (petal) petal.setAttribute("data-active", "true")
  }

  _setActiveSubPetal(petal) {
    if (this.activeSubPetal === petal) return
    if (this.activeSubPetal) this.activeSubPetal.removeAttribute("data-active")
    this.activeSubPetal = petal
    if (petal) petal.setAttribute("data-active", "true")
  }

  _openSubArc() {
    if (!this.hasSubArcTarget) return
    this.subArcOpen = true
    this.subArcTarget.classList.remove("hidden")
    this.subPetalsTargets.forEach((el, i) => {
      el.style.transitionDelay = `${i * 20}ms`
      const tx = el.dataset.targetX || "0"
      const ty = el.dataset.targetY || "0"
      el.style.transform = `translate(${tx}px, ${ty}px)`
      el.classList.remove("opacity-0", "scale-50")
      el.classList.add("opacity-100", "scale-100")
    })
  }

  _closeSubArc() {
    if (!this.hasSubArcTarget) return
    this.subArcOpen = false
    this.activeSubPetal = null
    this.subPetalsTargets.forEach((el) => {
      el.style.transitionDelay = "0ms"
      el.style.transform = "translate(0px, 0px)"
      el.classList.add("opacity-0", "scale-50")
      el.classList.remove("opacity-100", "scale-100")
      el.removeAttribute("data-active")
    })
    this.subArcTarget.classList.add("hidden")
  }

  // ---- Sheet (tap fallback / accessibility) ----

  toggleSheet() {
    if (this._sheetOpen()) this._closeSheet()
    else this._openSheet()
  }

  _sheetOpen() {
    return this.hasSheetTarget && !this.sheetTarget.classList.contains("translate-y-full")
  }

  _openSheet() {
    if (!this.hasSheetTarget) return
    this.sheetTarget.classList.remove("translate-y-full", "opacity-0")
    this.sheetTarget.classList.add("translate-y-0", "opacity-100")
    this.sheetOverlayTarget.classList.remove("hidden")
  }

  closeSheet() { this._closeSheet() }

  _closeSheet() {
    if (!this.hasSheetTarget) return
    this.sheetTarget.classList.add("translate-y-full", "opacity-0")
    this.sheetTarget.classList.remove("translate-y-0", "opacity-100")
    this.sheetOverlayTarget.classList.add("hidden")
  }

  // Commit a petal key from anywhere (sheet click or radial release).
  fire(event) {
    const key = event.currentTarget.dataset.petalKey
    this._closeSheet()
    this._commit(key)
  }

  // ---- Commit (open panel / open modal / fire form / open URL) ----

  _commit(key) {
    if (!key) return
    switch (key) {
      case "quick-router":
        this._openChatBubble()
        break
      case "edit-notes":
        this._openNotesDrawer()
        break
      case "view-pr": {
        // Single PR: open it. (Multi-PR drag path is handled in _onPointerUp.)
        const urls = this.prUrlsValue
        if (urls.length === 1) {
          this._touchActivity()
          window.open(urls[0], "_blank", "noopener,noreferrer")
        } else if (urls.length > 1) {
          // From the sheet fallback, open the most recent (matches prior behavior).
          this._touchActivity()
          window.open(urls[urls.length - 1], "_blank", "noopener,noreferrer")
        }
        break
      }
      case "trash":
        this._submitForm(this.element.dataset.archiveUrl, "post")
        break
      case "restore":
        this._submitForm(this.element.dataset.unarchiveUrl, "post")
        break
      case "view-artifacts":
        this._openModal("artifacts")
        break
      case "refresh":
        this._submitForm(this.element.dataset.refreshUrl, "post")
        break
      case "pause":
        this._submitForm(this.element.dataset.pauseUrl, "post")
        break
      case "restart":
        this._submitForm(this.element.dataset.restartUrl, "post")
        break
      case "favorite":
        this._submitForm(this.element.dataset.favoriteUrl, "patch")
        break
    }
  }

  _openChatBubble() {
    // Click the chat-bubble FAB programmatically. The FAB is hidden on mobile
    // via CSS (display:none), but a programmatic click still fires its handler,
    // which opens the (separately-rendered) Quick Router panel.
    const fab = document.querySelector("#chat-bubble > button")
    if (fab) fab.click()
  }

  _openNotesDrawer() {
    const toggle = document.querySelector("[data-session-notes-target='toggleButton']")
    if (toggle) toggle.click()
  }

  // ---- Modal flow for write-heavy actions ----

  _openModal(kind) {
    const root = this.modalRootTarget
    const modal = root.querySelector(`[data-modal-kind='${kind}']`)
    if (!modal) return
    modal.classList.remove("hidden")
    // The artifacts overview modal is read-only — don't auto-activate any
    // embedded editor (it has none). Per-artifact modals jump straight into
    // edit mode for a write-heavy flow.
    if (kind === "artifacts") return
    requestAnimationFrame(() => {
      const editorButton = modal.querySelector("button[data-action*='#edit']")
      if (editorButton) editorButton.click()
      const input = modal.querySelector("input[type='text'], textarea")
      if (input) input.focus()
    })
  }

  // Two-step nav: close the artifacts overview, open the per-artifact editor.
  modifyArtifact(event) {
    const kind = event.currentTarget.dataset.artifactKind
    if (!kind) return
    const overview = this.modalRootTarget.querySelector("[data-modal-kind='artifacts']")
    if (overview) overview.classList.add("hidden")
    this._openModal(kind)
  }

  closeModal(event) {
    const modal = event.currentTarget.closest("[data-modal-kind]")
    if (!modal) return
    modal.classList.add("hidden")
    // Cancel any in-progress editor inside the modal to reset to display mode.
    const cancelButton = modal.querySelector("button[data-action*='#cancel']")
    if (cancelButton) cancelButton.click()
  }

  _closeAllModals() {
    if (!this.hasModalRootTarget) return
    this.modalRootTarget.querySelectorAll("[data-modal-kind]").forEach((m) => m.classList.add("hidden"))
  }

  // Side-effect-only POST to the session's touch_activity endpoint so the
  // backend resets PollBackoff to the fast GitHub-poll cadence. Fired when a PR
  // is opened from the radial/sheet (which uses window.open, not a real link),
  // mirroring the session-activity controller used on plain PR links. The PR
  // opens in a new window, so the current page survives and a plain fetch
  // flushes reliably — no `keepalive` (its separate request path can be
  // deprioritized or canceled when a new window opens on the same tick).
  _touchActivity() {
    const url = this.element.dataset.touchUrl
    if (!url) return
    // CSRF token is optional: present with forgery protection on (production/
    // dev), absent in the test environment. Never gate the fetch on it.
    const headers = {}
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    if (token) headers["X-CSRF-Token"] = token
    fetch(url, {
      method: "POST",
      headers
    }).catch(() => {
      // Best-effort: a missed touch only means the cadence stays as-is.
    })
  }

  _submitForm(url, method) {
    if (!url) return
    const form = document.createElement("form")
    form.method = "POST"
    form.action = url
    // Let Turbo intercept so controllers returning turbo_stream (e.g., archive)
    // can update the page without a full reload.
    form.dataset.turbo = "true"
    form.setAttribute("accept", "text/vnd.turbo-stream.html, text/html")

    const token = document.querySelector('meta[name="csrf-token"]')?.content
    if (token) {
      const t = document.createElement("input")
      t.type = "hidden"
      t.name = "authenticity_token"
      t.value = token
      form.appendChild(t)
    }
    if (method && method.toLowerCase() !== "post") {
      const m = document.createElement("input")
      m.type = "hidden"
      m.name = "_method"
      m.value = method
      form.appendChild(m)
    }
    document.body.appendChild(form)
    if (window.Turbo && typeof window.Turbo.navigator?.submitForm === "function") {
      window.Turbo.navigator.submitForm(form)
    } else {
      form.requestSubmit ? form.requestSubmit() : form.submit()
    }
  }
}
