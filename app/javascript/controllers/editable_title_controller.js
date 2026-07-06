import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="editable-title"
export default class extends Controller {
  static targets = ["display", "input", "form"]
  static values = {
    sessionId: Number,
    title: String
  }

  connect() {
    this.editing = false
  }

  disconnect() {
    if (this.editing) {
      this.finishEditing()
    }
  }

  get turboFrame() {
    return this.element.closest("turbo-frame")
  }

  edit(event) {
    event.preventDefault()
    event.stopPropagation() // Prevent card link click

    if (this.editing) return

    this.editing = true
    this.displayTarget.classList.add("hidden")
    this.inputTarget.classList.remove("hidden")
    this.inputTarget.value = this.titleValue || ""
    this.inputTarget.focus()
    this.inputTarget.select()

    // Mark the turbo frame as editing so live updates skip this card
    const frame = this.turboFrame
    if (frame) {
      frame.setAttribute("data-editing", "true")
    }
  }

  save(event) {
    event.preventDefault()
    if (!this.editing) return

    const newTitle = this.inputTarget.value.trim()

    if (newTitle === "") {
      this.cancel()
      return
    }

    // Make PATCH request to update title
    fetch(`/sessions/${this.sessionIdValue}/update_title`, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": document.querySelector("[name='csrf-token']").content
      },
      body: JSON.stringify({ title: newTitle })
    })
    .then(response => {
      if (!response.ok) {
        throw new Error("Failed to update title")
      }
      return response.json()
    })
    .then(data => {
      this.titleValue = newTitle
      this.displayTarget.textContent = newTitle
      // Sync title to any linked elements (e.g. group row summary title)
      const syncSelector = this.displayTarget.dataset.syncsWith
      if (syncSelector) {
        document.querySelectorAll(syncSelector).forEach(el => {
          el.textContent = newTitle
        })
      }
      this.finishEditing()
    })
    .catch(error => {
      console.error("Error updating title:", error)
      alert("Failed to update title. Please try again.")
      this.finishEditing()
    })
  }

  cancel() {
    this.finishEditing()
  }

  finishEditing() {
    this.editing = false
    this.inputTarget.classList.add("hidden")
    this.displayTarget.classList.remove("hidden")

    // Remove the editing guard from the turbo frame
    const frame = this.turboFrame
    if (frame) {
      frame.removeAttribute("data-editing")
    }
  }

  handleKeydown(event) {
    if (event.key === "Enter") {
      event.preventDefault()
      this.save(event)
    } else if (event.key === "Escape") {
      this.cancel()
    }
  }
}
