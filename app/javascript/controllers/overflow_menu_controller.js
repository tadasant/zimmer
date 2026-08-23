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
// Sized to the tallest thing a card's menu opens (the Pause Until panel: six
// presets, a datetime picker and a prompt field). A menu whose rows expand into
// nothing — a ranked row's promote/demote, say — overrides it with 0, or every
// row in the upper two-thirds of the page would open upward for room it never
// needs.
const MENU_EXPANSION_HEADROOM = 400

export default class extends Controller {
  static targets = ["button", "menu"]
  static values = {
    headroom: { type: Number, default: MENU_EXPANSION_HEADROOM },
    // "up" for a menu anchored at the bottom edge of its own box (a card's
    // footer), "down" for one anchored on a row in a list.
    placement: { type: String, default: "up" }
  }

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
  // that drops down covers the card below it. A menu anchored on a row in a list
  // has no such edge and reads better downward, which is what `placement: "down"`
  // asks for. Either way the side with room wins over the preference: a card near
  // the top of the viewport opens down, a row near the bottom opens up.
  //
  // Runs while the menu is visible but before anything expands inside it, so the
  // budget is the menu's own height plus headroom for the tallest panel it opens.
  _placeMenu() {
    const anchor = this.buttonTarget.getBoundingClientRect()
    const needed = this.menuTarget.getBoundingClientRect().height + this.headroomValue
    const roomAbove = anchor.top
    const roomBelow = window.innerHeight - anchor.bottom
    const opensUp = this.placementValue === "down"
      ? !(roomBelow >= needed || roomBelow >= roomAbove)
      : roomAbove >= needed || roomAbove > roomBelow

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
