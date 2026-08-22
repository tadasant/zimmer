import { Controller } from "@hotwired/stimulus"

// Reveals the breakdown behind a bar in the daily-spend chart.
//
// The readout is a fixed strip UNDER the chart rather than a floating card over
// the hovered bar. That is a deliberate trade: a floating tooltip has to be
// positioned, kept inside the viewport, and — at a 375px phone width, where the
// chart already fills the content column — has nowhere to go without covering the
// thing it describes. A strip in normal flow needs no positioning maths and is
// legible on the narrowest screen Zimmer is read on.
//
// Hover is an enhancement, not the mechanism. Every bar is a real <button>, so
// the breakdown opens on tap, on click, and on keyboard focus; pointer devices
// additionally get it on hover. A hover-only affordance is invisible on a phone.
//
// Each day's panel is rendered server-side and merely shown or hidden here. The
// obvious alternative — one tooltip element whose innerHTML is swapped from a
// data attribute — would take a round trip through an attribute value and back
// into HTML, which is exactly the shape that turns an agent root's name into an
// injection. Nothing in this controller writes markup.
export default class extends Controller {
  static targets = ["bar", "panel"]

  connect() {
    // Start on the most recent bar rather than blank, so the strip is always
    // occupied and hovering never makes the page jump by inserting a row.
    if (this.barTargets.length > 0) this.pin(this.barTargets.length - 1)
  }

  // Pointer devices preview on hover; the pinned selection returns on exit.
  preview(event) {
    if (!this.hasPointer) return
    this.show(this.indexOf(event.currentTarget))
  }

  restore() {
    if (!this.hasPointer) return
    this.show(this.pinnedIndex)
  }

  // Tap, click, or keyboard focus pins a bar.
  select(event) {
    this.pin(this.indexOf(event.currentTarget))
  }

  pin(index) {
    this.pinnedIndex = index
    this.show(index)
  }

  show(index) {
    if (index == null || index < 0) return

    this.panelTargets.forEach((panel, i) => panel.classList.toggle("hidden", i !== index))
    this.barTargets.forEach((bar, i) => {
      bar.dataset.active = i === index ? "true" : "false"
      bar.setAttribute("aria-pressed", i === index ? "true" : "false")
    })
  }

  indexOf(element) {
    return this.barTargets.indexOf(element)
  }

  get hasPointer() {
    return window.matchMedia("(hover: hover)").matches
  }
}
