import { Controller } from "@hotwired/stimulus"

// Simple dropdown controller for toggling visibility of a menu
// Usage:
//   <div data-controller="dropdown">
//     <button data-dropdown-target="button" data-action="click->dropdown#toggle" aria-expanded="false">Toggle</button>
//     <div data-dropdown-target="menu" class="hidden">Menu content</div>
//   </div>
//
// The button target is optional and carries the open state: a menu whose trigger
// is the only route to what is inside it has to say whether it is open, and to
// close on Escape, or a keyboard reader has no way out of it.
export default class extends Controller {
  static targets = ["menu", "button"]

  connect() {
    this.handleClickOutside = this.handleClickOutside.bind(this)
    this.handleKeydown = this.handleKeydown.bind(this)
    document.addEventListener("click", this.handleClickOutside)
    document.addEventListener("keydown", this.handleKeydown)
  }

  disconnect() {
    document.removeEventListener("click", this.handleClickOutside)
    document.removeEventListener("keydown", this.handleKeydown)
  }

  toggle(event) {
    event.stopPropagation()
    this.setOpen(this.menuTarget.classList.contains("hidden"))
  }

  handleClickOutside(event) {
    if (!this.element.contains(event.target)) this.setOpen(false)
  }

  // Focus returns to the trigger when what was focused is inside the menu being
  // hidden. Without it a keyboard user lands on <body>, because the element they
  // were on has just become display:none.
  handleKeydown(event) {
    if (event.key !== "Escape" || this.menuTarget.classList.contains("hidden")) return
    const hadFocus = this.menuTarget.contains(document.activeElement)
    this.setOpen(false)
    if (hadFocus && this.hasButtonTarget) this.buttonTarget.focus()
  }

  setOpen(open) {
    this.menuTarget.classList.toggle("hidden", !open)
    if (this.hasButtonTarget) this.buttonTarget.setAttribute("aria-expanded", String(open))
  }
}
