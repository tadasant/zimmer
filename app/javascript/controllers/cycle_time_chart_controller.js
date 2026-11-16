// Hover tooltips for the Cycle Time page: the stacked bars and the Gantt lanes.
//
// One delegated listener on the page rather than one per segment — a busy
// hierarchy draws thousands of segments — and one fixed-position tooltip
// reused for all of them, so it is never clipped by a lane's overflow and
// appears instantly (the native `title` tooltip takes a second).
//
// Every segment carries its description as data attributes, written by
// CycleTimesHelper#cycle_segment_data; this controller only places it.
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["tooltip"]

  connect() {
    this.hide()
  }

  show(event) {
    const segment = event.target.closest("[data-cycle-segment]")
    if (!segment) return

    const tip = this.tooltipTarget
    const set = (role, value) => {
      const el = tip.querySelector(`[data-role='${role}']`)
      el.textContent = value || ""
      el.classList.toggle("hidden", !value)
    }

    set("label", segment.dataset.label)
    set("duration", segment.dataset.duration)
    set("window", segment.dataset.window)
    set("session", segment.dataset.session)
    set("detail", segment.dataset.detail)
    tip.querySelector("[data-role='swatch']").style.cssText = segment.style.background
      ? `background: ${segment.style.background}`
      : ""

    tip.classList.remove("hidden")
    this.position(event)
  }

  move(event) {
    if (this.tooltipTarget.classList.contains("hidden")) return
    if (!event.target.closest("[data-cycle-segment]")) return
    this.position(event)
  }

  hide(event) {
    // mouseout fires when moving between a segment's own children; only hide
    // when the pointer actually left the segment.
    if (event?.relatedTarget?.closest?.("[data-cycle-segment]")) return
    this.tooltipTarget.classList.add("hidden")
  }

  // Keep the tooltip inside the viewport: it flips left near the right edge and
  // above near the bottom, so the last segment of a lane — usually the archive
  // — is as readable as the first.
  position(event) {
    const tip = this.tooltipTarget
    const { offsetWidth: width, offsetHeight: height } = tip
    const margin = 14

    let left = event.clientX + margin
    let top = event.clientY + margin
    if (left + width > window.innerWidth - 8) left = event.clientX - width - margin
    if (top + height > window.innerHeight - 8) top = event.clientY - height - margin

    tip.style.left = `${Math.max(8, left)}px`
    tip.style.top = `${Math.max(8, top)}px`
  }
}
