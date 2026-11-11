import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"
import { csrfToken } from "lib/csrf"
import { showAlert } from "lib/toast"

// Handles elicitation form interactions (Accept/Decline/Dismiss with dynamic form fields).
//
// Collects field values from the dynamically-rendered form based on the JSON Schema,
// then submits the response via fetch with Turbo Stream accept header.
export default class extends Controller {
  static targets = ["field", "fieldsContainer", "acceptButton", "declineButton", "cancelButton", "acceptHint"]
  static values = {
    respondUrl: String,
    schema: Object
  }

  connect() {
    this.refreshAccept()
  }

  // A required yes/no field is the question Accept answers. Sent unticked it is an
  // explicit `false`, which an MCP server reads as a refusal — the 1Password
  // server reports it as "declined" — so a click meant as approval would record a
  // decline (session #27239). Accept stays off until every such box is ticked;
  // Decline is how to say no.
  refreshAccept() {
    if (!this.hasAcceptButtonTarget) return

    const ready = this.unansweredRequiredBooleans().length === 0
    this.acceptButtonTarget.disabled = !ready
    this.acceptButtonTarget.classList.toggle("opacity-50", !ready)
    this.acceptButtonTarget.classList.toggle("cursor-not-allowed", !ready)
    if (this.hasAcceptHintTarget) this.acceptHintTarget.classList.toggle("hidden", ready)
  }

  unansweredRequiredBooleans() {
    if (!this.hasFieldTarget) return []

    return this.fieldTargets.filter(field =>
      field.dataset.fieldType === "boolean" && field.dataset.fieldRequired === "true" && !field.checked
    )
  }

  accept() {
    if (this.unansweredRequiredBooleans().length > 0) {
      this.refreshAccept()
      return
    }

    const content = this.collectFieldValues()
    this.submitResponse("accept", content)
  }

  decline() {
    this.submitResponse("decline", null)
  }

  // "Dismiss": the protocol's cancel — the user is not answering, and the MCP
  // server should stop waiting rather than poll until the request expires.
  cancel() {
    this.submitResponse("cancel", null)
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

  // The banner goes at the click; the server is asked after. A refusal brings it
  // back, with the refusal as a toast — or as the server's own alert, when it
  // answered with a stream (an answer already given elsewhere removes the banner
  // for good and says so).
  async submitResponse(actionType, content) {
    this.disableButtons()
    const banner = this.element
    const place = { parent: banner.parentNode, next: banner.nextSibling }
    banner.remove()

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
          "X-CSRF-Token": csrfToken()
        },
        body: body
      })
      const spoke = (response.headers.get("content-type") || "").includes("turbo-stream")
      if (!response.ok) {
        this.putBack(banner, place)
        if (!spoke) showAlert(`The answer could not be sent. The server answered ${response.status}.`)
      }
      if (spoke) Turbo.renderStreamMessage(await response.text())
    } catch (error) {
      this.putBack(banner, place)
      showAlert("The answer could not be sent: the server could not be reached.")
    }
  }

  putBack(banner, place) {
    this.enableButtons()
    this.refreshAccept()
    if (!place.parent || !place.parent.isConnected) return
    const next = place.next && place.next.parentNode === place.parent ? place.next : null
    place.parent.insertBefore(banner, next)
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
    if (this.hasCancelButtonTarget) {
      this.cancelButtonTarget.disabled = true
      this.cancelButtonTarget.classList.add("opacity-50", "cursor-not-allowed")
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
    if (this.hasCancelButtonTarget) {
      this.cancelButtonTarget.disabled = false
      this.cancelButtonTarget.classList.remove("opacity-50", "cursor-not-allowed")
    }
  }
}
