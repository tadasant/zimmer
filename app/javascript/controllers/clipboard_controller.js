import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="clipboard"
export default class extends Controller {
  static targets = ["feedback"]

  copy(event) {
    event.preventDefault()

    const value = event.currentTarget.getAttribute("data-clipboard-value")

    if (!value) {
      console.error("No clipboard value found")
      return
    }

    // Copy to clipboard using the Clipboard API
    navigator.clipboard.writeText(value)
      .then(() => {
        this.showFeedback()
      })
      .catch(err => {
        console.error("Failed to copy to clipboard:", err)
        // Fallback for older browsers
        this.fallbackCopy(value)
      })
  }

  fallbackCopy(text) {
    const textarea = document.createElement("textarea")
    textarea.value = text
    textarea.style.position = "fixed"
    textarea.style.opacity = "0"
    document.body.appendChild(textarea)
    textarea.select()

    try {
      document.execCommand("copy")
      this.showFeedback()
    } catch (err) {
      console.error("Fallback copy failed:", err)
    }

    document.body.removeChild(textarea)
  }

  showFeedback() {
    if (this.hasFeedbackTarget) {
      this.feedbackTarget.classList.remove("hidden")

      // Hide feedback after 2 seconds
      setTimeout(() => {
        this.feedbackTarget.classList.add("hidden")
      }, 2000)
    }
  }
}
