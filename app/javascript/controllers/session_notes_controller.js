import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="session-notes"
// Manages auto-saving session notes with debounce and manual save.
// Handles both mobile drawer and desktop sidebar textareas within the same scope.
// Uses textareaTargets (plural) to sync across all instances.
export default class extends Controller {
  static targets = ["textarea", "status", "drawerPanel", "drawerOverlay", "toggleButton"]
  static values = {
    sessionId: Number,
    debounceMs: { type: Number, default: 1500 }
  }

  connect() {
    this.debounceTimer = null
    this.saving = false
    this.savePromise = null
    this.lastSavedValue = this.activeTextarea.value

    // Document-level Escape key handler for closing mobile drawer
    this.boundHandleKeydown = this.handleKeydown.bind(this)
    document.addEventListener("keydown", this.boundHandleKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this.boundHandleKeydown)

    if (this.debounceTimer) {
      clearTimeout(this.debounceTimer)
    }
    // Flush pending changes on disconnect (page navigation)
    const currentValue = this.activeTextarea.value
    if (currentValue !== this.lastSavedValue) {
      this.flushSave(currentValue)
    }
  }

  handleKeydown(event) {
    if (event.key === "Escape" && this.hasDrawerPanelTarget) {
      const isOpen = !this.drawerPanelTarget.classList.contains("translate-x-full")
      if (isOpen) {
        this.closeDrawer()
      }
    }
  }

  // Get the visible textarea (desktop or mobile), falling back to the first one
  get activeTextarea() {
    for (const textarea of this.textareaTargets) {
      if (textarea.offsetParent !== null) return textarea
    }
    return this.textareaTargets[0]
  }

  // Called on input - debounced auto-save
  onInput(event) {
    // Sync value to all textareas so both mobile and desktop stay in sync
    const value = event.target.value
    for (const textarea of this.textareaTargets) {
      if (textarea !== event.target) {
        textarea.value = value
      }
    }

    this.showStatus("unsaved")

    if (this.debounceTimer) {
      clearTimeout(this.debounceTimer)
    }

    this.debounceTimer = setTimeout(() => {
      this.save()
    }, this.debounceMsValue)
  }

  // Manual save (button click)
  manualSave(event) {
    event.preventDefault()
    if (this.debounceTimer) {
      clearTimeout(this.debounceTimer)
    }
    this.save()
  }

  async save() {
    const currentValue = this.activeTextarea.value

    // Skip if nothing changed
    if (currentValue === this.lastSavedValue) {
      this.showStatus("saved")
      return
    }

    if (this.saving) return
    this.saving = true
    this.showStatus("saving")

    try {
      const response = await fetch(`/sessions/${this.sessionIdValue}/update_notes`, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector("[name='csrf-token']").content
        },
        body: JSON.stringify({ session_notes: currentValue })
      })

      if (!response.ok) {
        const data = await response.json()
        throw new Error(data.error || "Failed to save notes")
      }

      this.lastSavedValue = currentValue
      this.showStatus("saved")
    } catch (error) {
      console.error("Error saving session notes:", error)
      this.showStatus("error")
    } finally {
      this.saving = false
    }
  }

  // Best-effort flush on disconnect. The debounced autosave above is the primary save.
  flushSave(value) {
    const url = `/sessions/${this.sessionIdValue}/update_notes`
    const csrfToken = document.querySelector("[name='csrf-token']")?.content
    if (!csrfToken) return

    // Use fetch with keepalive to complete during page unload
    fetch(url, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": csrfToken
      },
      body: JSON.stringify({ session_notes: value }),
      keepalive: true
    }).catch(() => {
      // Best-effort: nothing to do if it fails on disconnect
    })
  }

  showStatus(state) {
    // Update all status targets (mobile + desktop)
    for (const el of this.statusTargets) {
      switch (state) {
        case "saving":
          el.textContent = "Saving..."
          el.className = "text-xs text-gray-400 italic"
          break
        case "saved":
          el.textContent = "Saved"
          el.className = "text-xs text-green-500"
          setTimeout(() => {
            if (el.textContent === "Saved") {
              el.textContent = ""
            }
          }, 2000)
          break
        case "unsaved":
          el.textContent = "Unsaved changes"
          el.className = "text-xs text-yellow-500"
          break
        case "error":
          el.textContent = "Save failed"
          el.className = "text-xs text-red-500"
          break
      }
    }
  }

  // Mobile drawer toggle
  toggleDrawer() {
    if (!this.hasDrawerPanelTarget) return

    const isOpen = !this.drawerPanelTarget.classList.contains("translate-x-full")
    if (isOpen) {
      this.closeDrawer()
    } else {
      this.openDrawer()
    }
  }

  openDrawer() {
    if (!this.hasDrawerPanelTarget) return
    this.drawerPanelTarget.classList.remove("translate-x-full")
    this.drawerOverlayTarget.classList.remove("hidden")
    if (this.hasToggleButtonTarget) {
      this.toggleButtonTarget.setAttribute("aria-expanded", "true")
    }
  }

  closeDrawer() {
    if (!this.hasDrawerPanelTarget) return
    this.drawerPanelTarget.classList.add("translate-x-full")
    this.drawerOverlayTarget.classList.add("hidden")
    if (this.hasToggleButtonTarget) {
      this.toggleButtonTarget.setAttribute("aria-expanded", "false")
    }
  }
}
