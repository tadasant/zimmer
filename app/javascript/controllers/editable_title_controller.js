import { Controller } from "@hotwired/stimulus"
import { csrfHeaders } from "lib/csrf"
import { showAlert } from "lib/toast"

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

    // The new title shows at once, here and wherever the page repeats it; the
    // server is asked after, and a refusal puts the old one back with a toast.
    const previous = this.titleValue
    const show = (title) => {
      this.displayTarget.textContent = title
      const syncSelector = this.displayTarget.dataset.syncsWith
      if (syncSelector) {
        document.querySelectorAll(syncSelector).forEach(el => {
          el.textContent = title
        })
      }
    }
    this.titleValue = newTitle
    show(newTitle)
    this.finishEditing()

    fetch(`/sessions/${this.sessionIdValue}/update_title`, {
      method: "PATCH",
      headers: csrfHeaders(),
      body: JSON.stringify({ title: newTitle })
    })
    .then(async response => {
      if (!response.ok) {
        const data = await response.json().catch(() => ({}))
        throw new Error(data.error || `The server answered ${response.status}.`)
      }
    })
    .catch(error => {
      this.titleValue = previous
      show(previous)
      const reason = error instanceof TypeError ? "The server could not be reached." : error.message
      showAlert(`The title could not be changed. ${reason} Nothing changed.`)
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
