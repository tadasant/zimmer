import { Controller } from "@hotwired/stimulus"

// Makes the Issues trend chart readable: a scrubbable crosshair that reports
// every series' value on the day under it, and a legend that hides a series.
//
// The plot itself is server-rendered SVG. This controller never builds markup —
// it moves elements the server already put on the page and writes numbers with
// `textContent`. The values arrive as JSON on a data attribute rather than as
// per-day panels in the DOM, because 180 days x 8 series is 1,440 hidden
// elements to render a strip that shows four numbers at a time.
//
// The scrubber is an opacity-0 <input type="range"> laid over the plot. That one
// element is a mouse hover, a touch drag and a keyboard arrow at once — a chart
// whose only affordance is `mouseover` has no interaction at all on the phone
// Zimmer is mostly read on.
export default class extends Controller {
  static targets = ["plot", "series", "dot", "crosshair", "legend", "value", "readoutDate", "scrub"]
  static values = { values: Object, dates: Array, max: Number }

  connect() {
    this.hidden = new Set()
    // Start on the most recent day: the strip is always occupied, so hovering
    // never makes the page jump by filling an empty row.
    this.show(this.lastIndex)
    this.element.addEventListener("pointermove", this.onPointerMove)
    this.element.addEventListener("pointerleave", this.onPointerLeave)
  }

  disconnect() {
    this.element.removeEventListener("pointermove", this.onPointerMove)
    this.element.removeEventListener("pointerleave", this.onPointerLeave)
  }

  get lastIndex() {
    return Math.max(this.datesValue.length - 1, 0)
  }

  // Dragging the range input, or arrowing it with the keyboard.
  scrub() {
    this.show(Number(this.scrubTarget.value))
  }

  // Pointer devices preview the day under the cursor; leaving restores the most
  // recent day, so the strip never goes blank.
  onPointerMove = (event) => {
    if (!this.hasPlotTarget) return
    const box = this.plotTarget.getBoundingClientRect()
    if (box.width === 0) return
    if (event.clientY < box.top || event.clientY > box.bottom) return

    const ratio = (event.clientX - box.left) / box.width
    const index = Math.round(Math.min(Math.max(ratio, 0), 1) * this.lastIndex)
    this.scrubTarget.value = index
    this.show(index)
  }

  onPointerLeave = () => {
    this.scrubTarget.value = this.lastIndex
    this.show(this.lastIndex)
  }

  // Hide or restore one series: its line, its dot, and its number.
  toggle(event) {
    const button = event.currentTarget
    const key = button.dataset.seriesKey
    const on = this.hidden.has(key)
    on ? this.hidden.delete(key) : this.hidden.add(key)

    button.setAttribute("aria-pressed", on ? "true" : "false")
    button.classList.toggle("opacity-40", !on)
    button.classList.toggle("line-through", !on)
    this.seriesTargets.forEach((group) => {
      if (group.dataset.seriesKey === key) group.classList.toggle("hidden", !on)
    })
    this.show(this.currentIndex)
  }

  show(index) {
    if (this.datesValue.length === 0) return

    this.currentIndex = Math.min(Math.max(index, 0), this.lastIndex)
    if (this.hasReadoutDateTarget) this.readoutDateTarget.textContent = this.datesValue[this.currentIndex]

    this.valueTargets.forEach((span) => {
      const series = this.valuesValue[span.dataset.seriesKey]
      span.textContent = series ? String(series[this.currentIndex]) : "—"
    })

    const x = this.lastIndex === 0 ? 0 : (this.currentIndex / this.lastIndex) * 100
    if (this.hasCrosshairTarget) {
      this.crosshairTarget.classList.remove("hidden")
      this.crosshairTarget.style.left = `${x}%`
    }

    this.dotTargets.forEach((dot) => {
      const key = dot.dataset.seriesKey
      const series = this.valuesValue[key]
      const visible = series !== undefined && !this.hidden.has(key)
      dot.classList.toggle("hidden", !visible)
      if (!visible) return

      dot.style.left = `${x}%`
      dot.style.top = `${this.maxValue === 0 ? 100 : (1 - series[this.currentIndex] / this.maxValue) * 100}%`
    })
  }
}
