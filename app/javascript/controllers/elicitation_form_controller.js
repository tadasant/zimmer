import { Controller } from "@hotwired/stimulus"

// Handles elicitation form interactions (Accept/Decline with dynamic form fields).
//
// Collects field values from the dynamically-rendered form based on the JSON Schema,
// then submits the response via fetch with Turbo Stream accept header.
export default class extends Controller {
  static targets = ["field", "fieldsContainer", "acceptButton", "declineButton"]
  static values = {
    respondUrl: String,
    schema: Object
  }

  accept() {
    const content = this.collectFieldValues()
    this.submitResponse("accept", content)
  }

  decline() {
    this.submitResponse("decline", null)
  }

  collectFieldValues() {
    const content = {}

    if (!this.hasFieldTarget) return content

    this.fieldTargets.forEach(field => {
      const name = field.dataset.fieldName
      const type = field.dataset.fieldType

      switch (type) {
        case "boolean":
          content[name] = field.checked
          break
        case "number":
          content[name] = field.value ? parseFloat(field.value) : null
          break
        case "integer":
          content[name] = field.value ? parseInt(field.value, 10) : null
          break
        default:
          content[name] = field.value || null
      }
    })

    return content
  }

  async submitResponse(actionType, content) {
    // Disable buttons to prevent double-submit
    this.disableButtons()

    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content

    const body = new FormData()
    body.append("action_type", actionType)
    if (content) {
      body.append("content", JSON.stringify(content))
    }

    try {
      const response = await fetch(this.respondUrlValue, {
        method: "PATCH",
        headers: {
          "Accept": "text/vnd.turbo-stream.html",
          "X-CSRF-Token": csrfToken
        },
        body: body
      })

      if (response.ok) {
        const html = await response.text()
        Turbo.renderStreamMessage(html)
      } else {
        console.error("Elicitation response failed:", response.status)
        this.enableButtons()
      }
    } catch (error) {
      console.error("Elicitation response error:", error)
      this.enableButtons()
    }
  }

  disableButtons() {
    if (this.hasAcceptButtonTarget) {
      this.acceptButtonTarget.disabled = true
      this.acceptButtonTarget.classList.add("opacity-50", "cursor-not-allowed")
    }
    if (this.hasDeclineButtonTarget) {
      this.declineButtonTarget.disabled = true
      this.declineButtonTarget.classList.add("opacity-50", "cursor-not-allowed")
    }
  }

  enableButtons() {
    if (this.hasAcceptButtonTarget) {
      this.acceptButtonTarget.disabled = false
      this.acceptButtonTarget.classList.remove("opacity-50", "cursor-not-allowed")
    }
    if (this.hasDeclineButtonTarget) {
      this.declineButtonTarget.disabled = false
      this.declineButtonTarget.classList.remove("opacity-50", "cursor-not-allowed")
    }
  }
}
