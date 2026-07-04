import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="dashboard-notes"
// Manages a slide-in sidebar on the dashboard for editing session notes.
// Clicking a notes icon on a session card opens the sidebar with that session's notes.
export default class extends Controller {
  static targets = ["sidebar", "overlay", "textarea", "status", "sessionTitle"]
  static values = {
    debounceMs: { type: Number, default: 1500 }
  }

  connect() {
    this.debounceTimer = null
    this.saving = false
    this.savePromise = null
    this.activeSessionId = null
    this.lastSavedValue = null
    this.highlightedCard = null
    this.boundHandleKeydown = this.handleKeydown.bind(this)
    document.addEventListener("keydown", this.boundHandleKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this.boundHandleKeydown)
    if (this.debounceTimer) {
      clearTimeout(this.debounceTimer)
    }
    this.flushPendingChanges()
    this.removeHighlight()
  }

  handleKeydown(event) {
    if (event.key === "Escape" && this.isOpen()) {
      this.close()
    }
  }

  // Called from session card notes icon: data-action="click->dashboard-notes#open"
  // Expects data-session-id, data-session-notes, data-session-title on the button
  open(event) {
    event.preventDefault()
    event.stopPropagation()

    const button = event.currentTarget
    const sessionId = button.dataset.sessionId
    const notes = button.dataset.sessionNotes || ""
    const title = button.dataset.sessionTitle || `Session #${sessionId}`

    // If same session is already open, close instead
    if (this.activeSessionId === parseInt(sessionId) && this.isOpen()) {
      this.close()
      return
    }

    // Save pending changes from previous session before switching
    this.flushPendingChanges()

    this.activeSessionId = parseInt(sessionId)
    this.textareaTarget.value = notes
    this.lastSavedValue = notes
    this.sessionTitleTarget.textContent = title
    this.showStatus("")

    // Highlight the active card
    this.removeHighlight()
    const card = document.getElementById(`session_${sessionId}`)
    if (card) {
      this.highlightedCard = card
      card.classList.add("ring-2", "ring-indigo-500", "ring-offset-2", "rounded-lg")
    }

    // Open sidebar
    this.sidebarTarget.classList.remove("translate-x-full")
    this.overlayTarget.classList.remove("hidden")

    // Focus textarea
    requestAnimationFrame(() => this.textareaTarget.focus())
  }

  close() {
    this.flushPendingChanges()

    this.sidebarTarget.classList.add("translate-x-full")
    this.overlayTarget.classList.add("hidden")
    this.removeHighlight()
    this.activeSessionId = null

    if (this.debounceTimer) {
      clearTimeout(this.debounceTimer)
      this.debounceTimer = null
    }
  }

  // Flush any pending unsaved changes synchronously (best-effort)
  flushPendingChanges() {
    if (!this.activeSessionId || this.lastSavedValue === null) return

    const currentValue = this.textareaTarget.value
    if (currentValue === this.lastSavedValue) return

    // Use keepalive fetch to flush during disconnect/navigation
    const url = `/sessions/${this.activeSessionId}/update_notes`
    const csrfToken = document.querySelector("[name='csrf-token']")?.content
    if (!csrfToken) return

    fetch(url, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": csrfToken
      },
      body: JSON.stringify({ session_notes: currentValue }),
      keepalive: true
    }).then(() => {
      this.lastSavedValue = currentValue
      this.updateCardData(this.activeSessionId, currentValue)
    }).catch(() => {
      // Best-effort
    })
  }

  isOpen() {
    return !this.sidebarTarget.classList.contains("translate-x-full")
  }

  removeHighlight() {
    if (this.highlightedCard) {
      this.highlightedCard.classList.remove("ring-2", "ring-indigo-500", "ring-offset-2", "rounded-lg")
      this.highlightedCard = null
    }
  }

  // Called on input - debounced auto-save
  onInput() {
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
    if (!this.activeSessionId) return

    const currentValue = this.textareaTarget.value

    if (currentValue === this.lastSavedValue) {
      this.showStatus("saved")
      return
    }

    if (this.saving) {
      // Queue a re-save after current save completes
      if (this.savePromise) {
        this.savePromise.then(() => this.save())
      }
      return
    }

    this.saving = true
    this.showStatus("saving")

    this.savePromise = this.doSave(this.activeSessionId, currentValue)
    await this.savePromise
    this.savePromise = null
  }

  async doSave(sessionId, value) {
    try {
      const response = await fetch(`/sessions/${sessionId}/update_notes`, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector("[name='csrf-token']").content
        },
        body: JSON.stringify({ session_notes: value })
      })

      if (!response.ok) {
        const data = await response.json()
        throw new Error(data.error || "Failed to save notes")
      }

      this.lastSavedValue = value
      this.showStatus("saved")
      this.updateCardData(sessionId, value)
    } catch (error) {
      console.error("Error saving session notes:", error)
      this.showStatus("error")
    } finally {
      this.saving = false
    }
  }

  updateCardData(sessionId, notes) {
    const card = document.getElementById(`session_${sessionId}`)
    if (!card) return

    const notesButton = card.querySelector(`[data-session-id="${sessionId}"][data-action*="dashboard-notes#open"]`)
    if (notesButton) {
      notesButton.dataset.sessionNotes = notes

      // Update icon color based on whether notes are present
      if (notes && notes.trim().length > 0) {
        notesButton.classList.remove("text-gray-300", "hover:text-indigo-400")
        notesButton.classList.add("text-indigo-400", "hover:text-indigo-600")
      } else {
        notesButton.classList.remove("text-indigo-400", "hover:text-indigo-600")
        notesButton.classList.add("text-gray-300", "hover:text-indigo-400")
      }
    }
  }

  showStatus(state) {
    if (!this.hasStatusTarget) return

    const el = this.statusTarget
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
      default:
        el.textContent = ""
        el.className = ""
    }
  }
}
