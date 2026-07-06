import { Controller } from "@hotwired/stimulus"

/**
 * EnqueuedMessageEditController - Handles inline editing and copying of enqueued messages
 *
 * Features:
 * - Switch between view and edit modes
 * - Save changes via PATCH request
 * - Copy message content to clipboard
 * - Cancel editing and restore original values
 *
 * The content and goal values are stored as JSON-encoded strings in data
 * attributes to prevent XSS vulnerabilities from special characters in message content.
 */
export default class extends Controller {
  static targets = [
    "viewMode",
    "editMode",
    "contentTextarea",
    "goalTextarea",
    "saveButton",
    "copyButton",
    "copyIcon",
    "checkIcon"
  ]

  static values = {
    content: String,
    goal: String,
    updateUrl: String
  }

  connect() {
    this.feedbackTimeout = null
    this.saving = false
  }

  disconnect() {
    if (this.feedbackTimeout) {
      clearTimeout(this.feedbackTimeout)
      this.feedbackTimeout = null
    }
  }

  // Parse the JSON-encoded content value
  get parsedContent() {
    try {
      return JSON.parse(this.contentValue)
    } catch (e) {
      // Fallback for non-JSON values (shouldn't happen in normal usage)
      return this.contentValue
    }
  }

  // Parse the JSON-encoded goal value
  get parsedGoal() {
    try {
      return JSON.parse(this.goalValue)
    } catch (e) {
      // Fallback for non-JSON values (shouldn't happen in normal usage)
      return this.goalValue || ""
    }
  }

  // Enter edit mode
  edit(event) {
    event.preventDefault()
    event.stopPropagation()

    if (this.hasViewModeTarget && this.hasEditModeTarget) {
      this.viewModeTarget.classList.add("hidden")
      this.editModeTarget.classList.remove("hidden")

      // Focus the content textarea
      if (this.hasContentTextareaTarget) {
        this.contentTextareaTarget.focus()
        // Move cursor to end
        const len = this.contentTextareaTarget.value.length
        this.contentTextareaTarget.setSelectionRange(len, len)
      }
    }
  }

  // Cancel editing and restore original values
  cancel(event) {
    event.preventDefault()
    event.stopPropagation()

    if (this.hasContentTextareaTarget) {
      this.contentTextareaTarget.value = this.parsedContent
    }
    if (this.hasGoalTextareaTarget) {
      this.goalTextareaTarget.value = this.parsedGoal
    }

    if (this.hasViewModeTarget && this.hasEditModeTarget) {
      this.editModeTarget.classList.add("hidden")
      this.viewModeTarget.classList.remove("hidden")
    }
  }

  // Save changes
  async save(event) {
    event.preventDefault()
    event.stopPropagation()

    if (this.saving) return
    this.saving = true

    const content = this.hasContentTextareaTarget ? this.contentTextareaTarget.value : ""
    const goal = this.hasGoalTextareaTarget ? this.goalTextareaTarget.value : ""

    // Disable save button
    if (this.hasSaveButtonTarget) {
      this.saveButtonTarget.disabled = true
      this.saveButtonTarget.textContent = "Saving..."
    }

    try {
      const response = await fetch(this.updateUrlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          "Accept": "text/vnd.turbo-stream.html",
          "X-CSRF-Token": this.csrfToken
        },
        body: new URLSearchParams({
          content: content,
          goal: goal
        })
      })

      if (response.ok) {
        // Turbo will handle the stream response and replace the element
        const html = await response.text()
        Turbo.renderStreamMessage(html)
      } else {
        console.error("Failed to save:", response.statusText)
        // Re-enable save button on error
        if (this.hasSaveButtonTarget) {
          this.saveButtonTarget.disabled = false
          this.saveButtonTarget.textContent = "Save"
        }
      }
    } catch (error) {
      console.error("Error saving:", error)
      if (this.hasSaveButtonTarget) {
        this.saveButtonTarget.disabled = false
        this.saveButtonTarget.textContent = "Save"
      }
    } finally {
      this.saving = false
    }
  }

  // Copy content to clipboard
  async copy(event) {
    event.preventDefault()
    event.stopPropagation()

    const text = this.parsedContent

    if (!text) {
      return
    }

    try {
      await navigator.clipboard.writeText(text)
      this.showCopiedFeedback()
    } catch (err) {
      console.error("Failed to copy:", err)
      this.fallbackCopy(text)
    }
  }

  fallbackCopy(text) {
    const textarea = document.createElement("textarea")
    textarea.value = text
    textarea.style.position = "fixed"
    textarea.style.opacity = "0"
    document.body.appendChild(textarea)
    textarea.select()

    try {
      const successful = document.execCommand("copy")
      if (successful) {
        this.showCopiedFeedback()
      }
    } catch (err) {
      console.error("Fallback copy failed:", err)
    }

    document.body.removeChild(textarea)
  }

  showCopiedFeedback() {
    if (this.feedbackTimeout) {
      clearTimeout(this.feedbackTimeout)
      this.feedbackTimeout = null
    }

    // Show checkmark, hide copy icon
    if (this.hasCopyIconTarget && this.hasCheckIconTarget) {
      this.copyIconTarget.classList.add("hidden")
      this.checkIconTarget.classList.remove("hidden")
    }

    // Change button color
    if (this.hasCopyButtonTarget) {
      this.copyButtonTarget.classList.add("text-green-600")
      this.copyButtonTarget.classList.remove("text-gray-400")
    }

    // Reset after 2 seconds
    this.feedbackTimeout = setTimeout(() => {
      this.resetCopyFeedback()
    }, 2000)
  }

  resetCopyFeedback() {
    // Guard against disconnected elements (e.g., if Turbo replaced the DOM)
    if (!this.element.isConnected) return

    this.feedbackTimeout = null
    if (this.hasCopyIconTarget) {
      this.copyIconTarget.classList.remove("hidden")
    }
    if (this.hasCheckIconTarget) {
      this.checkIconTarget.classList.add("hidden")
    }
    if (this.hasCopyButtonTarget) {
      this.copyButtonTarget.classList.remove("text-green-600")
      this.copyButtonTarget.classList.add("text-gray-400")
    }
  }

  get csrfToken() {
    const meta = document.querySelector("meta[name='csrf-token']")
    return meta ? meta.getAttribute("content") : ""
  }
}
