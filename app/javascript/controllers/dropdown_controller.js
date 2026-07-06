import { Controller } from "@hotwired/stimulus"

// Simple dropdown controller for toggling visibility of a menu
// Usage:
//   <div data-controller="dropdown">
//     <button data-action="click->dropdown#toggle">Toggle</button>
//     <div data-dropdown-target="menu" class="hidden">Menu content</div>
//   </div>
export default class extends Controller {
  static targets = ["menu"]

  connect() {
    // Close dropdown when clicking outside
    this.handleClickOutside = this.handleClickOutside.bind(this)
    document.addEventListener("click", this.handleClickOutside)
  }

  disconnect() {
    document.removeEventListener("click", this.handleClickOutside)
  }

  toggle(event) {
    event.stopPropagation()
    this.menuTarget.classList.toggle("hidden")
  }

  handleClickOutside(event) {
    if (!this.element.contains(event.target)) {
      this.menuTarget.classList.add("hidden")
    }
  }
}
