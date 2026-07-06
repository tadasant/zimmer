import { Controller } from "@hotwired/stimulus"

// Tracks the height of the sticky page header and exposes it as a CSS
// custom property (--page-header-height) on the root element. Sticky
// elements below the header use this variable to pin exactly at its bottom
// edge, regardless of how much the header's height changes when metadata,
// titles, or status badges grow.
export default class extends Controller {
  static targets = ["header"]

  connect() {
    this.resizeObserver = new ResizeObserver(() => this.updateOffset())

    if (this.hasHeaderTarget) {
      this.resizeObserver.observe(this.headerTarget)
    }

    this.updateOffset()
  }

  disconnect() {
    if (this.resizeObserver) {
      this.resizeObserver.disconnect()
    }
    document.documentElement.style.removeProperty("--page-header-height")
  }

  updateOffset() {
    if (!this.hasHeaderTarget) return
    const height = this.headerTarget.offsetHeight
    document.documentElement.style.setProperty("--page-header-height", `${height}px`)
  }
}
