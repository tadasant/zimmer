import { Controller } from "@hotwired/stimulus"

/**
 * TranscriptCopyController - Copies the full transcript to clipboard
 *
 * This controller provides a copy button to copy the entire session transcript
 * in a nicely formatted text that can be pasted into a new conversation.
 *
 * The transcript data is fetched from a dedicated endpoint to get the full
 * formatted content, avoiding the need to store large amounts of data in
 * data attributes.
 *
 * Usage:
 *   <div data-controller="transcript-copy" data-transcript-copy-url-value="/sessions/:id/transcript.txt">
 *     <button data-action="click->transcript-copy#copy" data-transcript-copy-target="button">
 *       Copy Full Transcript
 *     </button>
 *   </div>
 */
export default class extends Controller {
  static values = {
    url: String
  }

  static targets = ["button", "copyIcon", "checkIcon", "errorIcon", "spinner"]

  connect() {
    this.feedbackTimeout = null
    this.isLoading = false
  }

  disconnect() {
    if (this.feedbackTimeout) {
      clearTimeout(this.feedbackTimeout)
      this.feedbackTimeout = null
    }
  }

  async copy(event) {
    event.preventDefault()

    if (this.isLoading) {
      return
    }

    if (!this.urlValue) {
      console.error("TranscriptCopyController: No URL value provided")
      this.showErrorFeedback()
      return
    }

    this.isLoading = true
    this.showLoadingState()

    let text = null

    try {
      const response = await fetch(this.urlValue, {
        method: "GET",
        headers: {
          "Accept": "text/plain"
        }
      })

      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}`)
      }

      text = await response.text()

      if (!text || text.trim() === "") {
        console.error("TranscriptCopyController: No transcript content available")
        this.showErrorFeedback()
        return
      }

      await navigator.clipboard.writeText(text)
      this.showCopiedFeedback()
    } catch (err) {
      console.error("Failed to copy transcript:", err)
      // Fallback to execCommand for older browsers or permission issues
      if (text) {
        this.fallbackCopy(text)
      } else {
        this.showErrorFeedback()
      }
    } finally {
      this.isLoading = false
      this.hideLoadingState()
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

  showLoadingState() {
    if (this.hasSpinnerTarget) {
      this.spinnerTarget.classList.remove("hidden")
    }
    if (this.hasCopyIconTarget) {
      this.copyIconTarget.classList.add("hidden")
    }
    if (this.hasButtonTarget) {
      this.buttonTarget.disabled = true
      this.buttonTarget.classList.add("opacity-50", "cursor-wait")
    }
  }

  hideLoadingState() {
    if (this.hasSpinnerTarget) {
      this.spinnerTarget.classList.add("hidden")
    }
    if (this.hasButtonTarget) {
      this.buttonTarget.disabled = false
      this.buttonTarget.classList.remove("opacity-50", "cursor-wait")
    }
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
      this.buttonTarget.classList.remove("text-gray-500", "hover:text-gray-700", "hover:bg-gray-100")
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
      this.buttonTarget.classList.remove("text-gray-500", "hover:text-gray-700", "hover:bg-gray-100")
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
      this.buttonTarget.classList.add("text-gray-500", "hover:text-gray-700", "hover:bg-gray-100")
    }
  }
}
