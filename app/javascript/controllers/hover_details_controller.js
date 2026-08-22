import { Controller } from "@hotwired/stimulus"

// Makes a <details> row open on hover, without taking away tap or keyboard.
//
// The breakdown rows on the Costs page are plain <details> elements: they open on
// click, open on tap, open on Enter, and open with JavaScript off. That is the
// whole mechanism. This controller adds the one thing <details> has no native
// affordance for — opening on hover — and adds it ONLY on devices that have a
// pointer, so nothing about the phone behaviour changes.
//
// The subtlety is what a CLICK means once hover has already opened the row. The
// native toggle would read it as "this is open, so close it", which collapses the
// panel the moment the user reaches for it — they hover, read, click to keep it,
// and it disappears. So a click on a hover-opened row PINS it instead: the default
// toggle is suppressed once, and the row stops belonging to hover. From then on it
// behaves like any other <details>, including closing on the next click.
export default class extends Controller {
  open(event) {
    if (!this.hasPointer) return

    const row = event.currentTarget
    if (row.open) return

    row.open = true
    row.dataset.hoverOpened = "true"
  }

  close(event) {
    if (!this.hasPointer) return

    const row = event.currentTarget
    if (row.dataset.hoverOpened !== "true") return

    row.open = false
    delete row.dataset.hoverOpened
  }

  // Bound to the <summary>, so it never sees clicks on the panel's own contents.
  pin(event) {
    const row = event.currentTarget.parentElement
    if (!row || row.dataset.hoverOpened !== "true") return

    event.preventDefault()
    delete row.dataset.hoverOpened
  }

  get hasPointer() {
    return window.matchMedia("(hover: hover)").matches
  }
}
