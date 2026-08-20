// Hover tooltips and cell↔row linking for the Outcomes flamegraph.
//
// One delegated listener on the container rather than a listener per cell: a
// deep analysis is several hundred cells, and per-cell listeners make the
// initial render the slow part of a page whose whole point is fast scanning.
//
// The tooltip is a single fixed-position element reused for every cell. Nesting
// a tooltip inside each cell would be clipped by the cells' own overflow, and
// the browser's native `title` tooltip takes a second to appear — too slow to
// sweep a graph with.
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["tooltip", "graph"]

  connect() {
    this.hide()
  }

  // --- Hover ---------------------------------------------------------------

  show(event) {
    const cell = event.target.closest("[data-segment-id]")
    if (!cell) return

    this.tooltipTarget.querySelector("[data-role='id']").textContent = cell.dataset.segmentId
    this.tooltipTarget.querySelector("[data-role='goal']").textContent = cell.dataset.goal
    this.tooltipTarget.querySelector("[data-role='explanation']").textContent = cell.dataset.explanation
    this.tooltipTarget.querySelector("[data-role='meta']").textContent = cell.dataset.meta

    const badge = this.tooltipTarget.querySelector("[data-role='outcome']")
    const failure = cell.dataset.outcome === "Failure"
    badge.textContent = cell.dataset.outcome
    badge.className = failure
      ? "px-1.5 py-0.5 rounded text-[10px] font-bold bg-red-500 text-white"
      : "px-1.5 py-0.5 rounded text-[10px] font-bold bg-emerald-500 text-white"

    this.tooltipTarget.classList.remove("hidden")
    this.position(event)
  }

  move(event) {
    if (this.tooltipTarget.classList.contains("hidden")) return
    this.position(event)
  }

  hide() {
    this.tooltipTarget.classList.add("hidden")
  }

  // Keep the tooltip inside the viewport: near the right edge it flips to the
  // left of the cursor, near the bottom it flips above. Without this the tooltip
  // for a rightmost cell — often the most interesting one, since that is where a
  // transcript ends — is the one you cannot read.
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

  // --- Cell ↔ table row linking --------------------------------------------

  // Clicking a cell scrolls its row in the segment table into view and flashes
  // it. The flamegraph is for spotting shape; the table is for reading detail,
  // and this is the bridge between them.
  select(event) {
    const cell = event.target.closest("[data-segment-id]")
    if (!cell) return

    const row = document.getElementById(`segment-row-${cell.dataset.segmentId}`)
    if (!row) return

    this.element.querySelectorAll("[data-selected='true']").forEach((el) => {
      el.dataset.selected = "false"
      el.classList.remove("ring-2", "ring-indigo-500", "bg-indigo-50")
    })

    cell.dataset.selected = "true"
    cell.classList.add("ring-2", "ring-indigo-500")
    row.dataset.selected = "true"
    row.classList.add("bg-indigo-50")
    row.scrollIntoView({ block: "center", behavior: "smooth" })
  }
}
