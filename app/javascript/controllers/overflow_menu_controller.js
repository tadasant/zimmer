import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="overflow-menu"
//
// The "⋮" overflow container on a session card's footer row. It exists so that
// secondary actions have somewhere to live without widening a card that is read
// on a phone as often as on a laptop — Pause Until is its first entry, not its
// only possible one.
//
// The menu is a plain positioned box; anything inside it lays out in normal flow.
// That is deliberate: a child popover anchored inside an already-absolute menu is
// what pushes controls off the right edge of a 375px viewport, so the panel a menu
// row opens expands the menu itself instead.
// Vertical room a menu row's expanded panel needs beyond the closed menu box.
// Sized to the tallest thing the menu opens today (the Pause Until panel: six
// presets, a datetime picker and a prompt field).
const MENU_EXPANSION_HEADROOM = 400

export default class extends Controller {
  static targets = ["button", "menu"]

  connect() {
    this._outsideClick = this._outsideClick.bind(this)
    this._onKeydown = this._onKeydown.bind(this)
  }

  disconnect() {
    document.removeEventListener("click", this._outsideClick)
    document.removeEventListener("keydown", this._onKeydown)
  }

  toggle(event) {
    event.preventDefault()
    event.stopPropagation()
    if (this.menuTarget.classList.contains("hidden")) {
      this.open()
    } else {
      this.close()
    }
  }

  open() {
    this.menuTarget.classList.remove("hidden")
    this._placeMenu()
    this.buttonTarget.setAttribute("aria-expanded", "true")
    // Defer so the click that opened the menu doesn't immediately close it.
    setTimeout(() => {
      document.addEventListener("click", this._outsideClick)
      document.addEventListener("keydown", this._onKeydown)
    }, 0)
  }

  close() {
    this.menuTarget.classList.add("hidden")
    this.buttonTarget.setAttribute("aria-expanded", "false")
    document.removeEventListener("click", this._outsideClick)
    document.removeEventListener("keydown", this._onKeydown)
  }

  // Open upward by default — a card's actions sit at its bottom edge, and a menu
  // that drops down covers the card below it. But a card near the top of the
  // viewport has no room above, and the panel a menu row expands into is taller
  // than the menu itself, so measure the whole thing rather than the closed box.
  //
  // Runs while the menu is visible but before anything expands inside it, so the
  // budget is the menu's own height plus headroom for the tallest panel it opens.
  _placeMenu() {
    const anchor = this.buttonTarget.getBoundingClientRect()
    const needed = this.menuTarget.getBoundingClientRect().height + MENU_EXPANSION_HEADROOM
    const opensUp = anchor.top >= needed || anchor.top > window.innerHeight - anchor.bottom

    this.menuTarget.classList.toggle("bottom-full", opensUp)
    this.menuTarget.classList.toggle("mb-2", opensUp)
    this.menuTarget.classList.toggle("top-full", !opensUp)
    this.menuTarget.classList.toggle("mt-2", !opensUp)
  }

  _outsideClick(event) {
    if (!this.element.contains(event.target)) this.close()
  }

  _onKeydown(event) {
    if (event.key === "Escape") this.close()
  }
}
