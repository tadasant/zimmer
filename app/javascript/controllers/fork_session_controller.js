import { Controller } from "@hotwired/stimulus"

/**
 * ForkSessionController - Handles forking a session at a specific message
 *
 * This controller provides a fork button on transcript messages that allows
 * users to create a new session branching from that point in the conversation.
 * The forked session opens in a new window.
 *
 * Usage:
 *   <div data-controller="fork-session"
 *        data-fork-session-url-value="/sessions/123/fork"
 *        data-fork-session-message-index-value="5">
 *     <button data-action="click->fork-session#fork" data-fork-session-target="button">
 *       Fork
 *     </button>
 *   </div>
 */
export default class extends Controller {
  static values = {
    url: String,
    messageIndex: Number
  }

  static targets = ["button", "forkIcon", "spinnerIcon", "checkIcon", "errorIcon"]

  connect() {
    this.isForking = false
    this.feedbackTimeout = null
  }

  disconnect() {
    if (this.feedbackTimeout) {
      clearTimeout(this.feedbackTimeout)
      this.feedbackTimeout = null
    }
  }

  async fork(event) {
    event.preventDefault()
    event.stopPropagation()

    // Prevent double-clicks
    if (this.isForking) return
    this.isForking = true

    this.showSpinner()

    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": this.csrfToken
        },
        body: JSON.stringify({
          message_index: this.messageIndexValue
        })
      })

      const data = await response.json()

      if (response.ok && data.success) {
        this.showSuccess()
        // Open the forked session in a new window/tab
        window.open(data.session_url, "_blank")
      } else {
        console.error("Fork failed:", data.error)
        this.showError()
        // Show a brief error message
        if (data.error) {
          this.showToast(`Fork failed: ${data.error}`, "error")
        }
      }
    } catch (err) {
      console.error("Fork request failed:", err)
      this.showError()
      this.showToast("Fork request failed. Please try again.", "error")
    } finally {
      this.isForking = false
    }
  }

  get csrfToken() {
    const meta = document.querySelector('meta[name="csrf-token"]')
    return meta ? meta.getAttribute("content") : ""
  }

  showSpinner() {
    if (this.hasForkIconTarget) {
      this.forkIconTarget.classList.add("hidden")
    }
    if (this.hasSpinnerIconTarget) {
      this.spinnerIconTarget.classList.remove("hidden")
    }
    if (this.hasButtonTarget) {
      this.buttonTarget.disabled = true
      this.buttonTarget.classList.add("opacity-50", "cursor-wait")
    }
  }

  showSuccess() {
    // Clear any existing timeout
    if (this.feedbackTimeout) {
      clearTimeout(this.feedbackTimeout)
      this.feedbackTimeout = null
    }

    if (this.hasSpinnerIconTarget) {
      this.spinnerIconTarget.classList.add("hidden")
    }
    if (this.hasCheckIconTarget) {
      this.checkIconTarget.classList.remove("hidden")
    }
    if (this.hasButtonTarget) {
      this.buttonTarget.classList.add("bg-green-100", "text-green-700")
      this.buttonTarget.classList.remove("bg-gray-100", "text-gray-500", "opacity-50", "cursor-wait")
      this.buttonTarget.disabled = false
    }

    // Reset after 2 seconds
    this.feedbackTimeout = setTimeout(() => {
      this.resetFeedback()
    }, 2000)
  }

  showError() {
    // Clear any existing timeout
    if (this.feedbackTimeout) {
      clearTimeout(this.feedbackTimeout)
      this.feedbackTimeout = null
    }

    if (this.hasSpinnerIconTarget) {
      this.spinnerIconTarget.classList.add("hidden")
    }
    if (this.hasErrorIconTarget) {
      this.errorIconTarget.classList.remove("hidden")
    }
    if (this.hasButtonTarget) {
      this.buttonTarget.classList.add("bg-red-100", "text-red-700")
      this.buttonTarget.classList.remove("bg-gray-100", "text-gray-500", "opacity-50", "cursor-wait")
      this.buttonTarget.disabled = false
    }

    // Reset after 3 seconds
    this.feedbackTimeout = setTimeout(() => {
      this.resetFeedback()
    }, 3000)
  }

  resetFeedback() {
    this.feedbackTimeout = null

    if (this.hasForkIconTarget) {
      this.forkIconTarget.classList.remove("hidden")
    }
    if (this.hasSpinnerIconTarget) {
      this.spinnerIconTarget.classList.add("hidden")
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

  showToast(message, type = "info") {
    // Create a simple toast notification
    const toast = document.createElement("div")
    toast.className = `fixed bottom-4 right-4 px-4 py-2 rounded-lg shadow-lg z-50 transition-opacity duration-300 ${
      type === "error" ? "bg-red-500 text-white" : "bg-gray-800 text-white"
    }`
    toast.textContent = message
    document.body.appendChild(toast)

    // Fade out and remove after 3 seconds
    setTimeout(() => {
      toast.classList.add("opacity-0")
      setTimeout(() => toast.remove(), 300)
    }, 3000)
  }
}
