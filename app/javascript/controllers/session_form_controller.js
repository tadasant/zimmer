import { Controller } from "@hotwired/stimulus"

// Character limits are read from data attributes passed from the server
// to ensure consistency with Session::PROMPT_MAX_LENGTH and Session::GOAL_MAX_LENGTH
export default class extends Controller {
  static targets = ["form", "promptTextarea", "submitButton", "cloneOnlyButton"]
  static values = {
    promptMaxLength: { type: Number, default: 500000 },
    goalMaxLength: { type: Number, default: 50000 }
  }

  handleKeydown(event) {
    // Submit form on Cmd+Enter (Mac) or Ctrl+Enter (Windows/Linux)
    if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
      event.preventDefault()
      this.submitForm()
    }
  }

  submitForm() {
    if (this.promptTextareaTarget.value.trim() === "") {
      alert("Please enter a prompt for the agent")
      return
    }

    if (this.promptTextareaTarget.value.length > this.promptMaxLengthValue) {
      alert(`Prompt is too long. Maximum ${this.promptMaxLengthValue.toLocaleString()} characters allowed.`)
      return
    }

    if (!this.validateGoal()) {
      return
    }

    this.submitButtonTarget.disabled = true
    this.submitButtonTarget.textContent = "Creating Session..."

    this.formTarget.requestSubmit()
  }

  handleCloneOnly(event) {
    event.preventDefault()

    if (!this.validateGoal()) {
      return
    }

    this.promptTextareaTarget.value = ""

    if (this.hasCloneOnlyButtonTarget) {
      this.cloneOnlyButtonTarget.disabled = true
      this.cloneOnlyButtonTarget.textContent = "Setting up clone..."
    }

    if (this.hasSubmitButtonTarget) {
      this.submitButtonTarget.disabled = true
    }

    this.formTarget.requestSubmit()
  }

  validateGoal() {
    const goalInput = this.element.querySelector('[data-goal-target="input"]')
    if (goalInput && goalInput.value.length > this.goalMaxLengthValue) {
      alert(`Goal is too long. Maximum ${this.goalMaxLengthValue.toLocaleString()} characters allowed.`)
      return false
    }
    return true
  }
}
