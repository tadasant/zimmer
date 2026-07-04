import { Controller } from "@hotwired/stimulus"

/**
 * MessageCopyController - Adds copy functionality to transcript entries
 *
 * This controller provides a copy button for transcript entry messages,
 * allowing users to copy the raw markdown content of any message.
 *
 * The content value is stored as JSON-encoded string in the data attribute
 * to prevent XSS vulnerabilities from special characters in message content.
 *
 * Usage:
 *   <div data-controller="message-copy" data-message-copy-content-value='"json encoded content"'>
 *     <!-- message content -->
 *   </div>
 */
export default class extends Controller {
  static values = {
    content: String
  }

  static targets = ["button", "copyIcon", "checkIcon", "errorIcon"]

  connect() {
    this.feedbackTimeout = null
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

  async copy(event) {
    event.preventDefault()

    const text = this.parsedContent

    if (!text) {
      this.showErrorFeedback()
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
      // execCommand returns a boolean indicating success, not a promise
      const successful = document.execCommand("copy")
      if (successful) {
        this.showCopiedFeedback()
      } else {
        console.error("Fallback copy failed: execCommand returned false")
        this.showErrorFeedback()
      }
    } catch (err) {
      console.error("Fallback copy failed:", err)
      this.showErrorFeedback()
    }

    document.body.removeChild(textarea)
  }

  showCopiedFeedback() {
    // Cancel any existing timeout
    if (this.feedbackTimeout) {
      clearTimeout(this.feedbackTimeout)
      this.feedbackTimeout = null
    }

    // Show checkmark, hide copy icon
    if (this.hasCopyIconTarget && this.hasCheckIconTarget) {
      this.copyIconTarget.classList.add("hidden")
      this.checkIconTarget.classList.remove("hidden")
    }

    // Change button background to green
    if (this.hasButtonTarget) {
      this.buttonTarget.classList.add("bg-green-100", "text-green-700")
      this.buttonTarget.classList.remove("bg-gray-100", "text-gray-500")
    }

    // Reset after 2 seconds
    this.feedbackTimeout = setTimeout(() => {
      this.resetFeedback()
    }, 2000)
  }

  showErrorFeedback() {
    // Cancel any existing timeout
    if (this.feedbackTimeout) {
      clearTimeout(this.feedbackTimeout)
      this.feedbackTimeout = null
    }

    // Show error icon, hide copy icon
    if (this.hasCopyIconTarget && this.hasErrorIconTarget) {
      this.copyIconTarget.classList.add("hidden")
      this.errorIconTarget.classList.remove("hidden")
    }

    // Change button background to red
    if (this.hasButtonTarget) {
      this.buttonTarget.classList.add("bg-red-100", "text-red-700")
      this.buttonTarget.classList.remove("bg-gray-100", "text-gray-500")
    }

    // Reset after 2 seconds
    this.feedbackTimeout = setTimeout(() => {
      this.resetFeedback()
    }, 2000)
  }

  resetFeedback() {
    this.feedbackTimeout = null
    if (this.hasCopyIconTarget) {
      this.copyIconTarget.classList.remove("hidden")
    }
    if (this.hasCheckIconTarget) {
      this.checkIconTarget.classList.add("hidden")
    }
    if (this.hasErrorIconTarget) {
      this.errorIconTarget.classList.add("hidden")
    }
    if (this.hasButtonTarget) {
      this.buttonTarget.classList.remove("bg-green-100", "text-green-700", "bg-red-100", "text-red-700")
      this.buttonTarget.classList.add("bg-gray-100", "text-gray-500")
    }
  }
}
