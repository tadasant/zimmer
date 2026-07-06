import { Controller } from "@hotwired/stimulus"

// Page-level "Collapse all" / "Expand all" control for the dashboard.
//
// A single button that collapses every category section (each custom category plus the
// "Uncategorized" bucket) or expands them all in one click. It reaches the per-section
// `category-collapse` controllers through the Stimulus outlets API and calls their
// public collapse()/expand() methods, so persistence to localStorage stays owned by
// category_collapse_controller.js (the single source of truth) and never drifts here.
//
// The button is a toggle: while any section is expanded it offers "Collapse all"; once
// every section is collapsed it flips to "Expand all". The outlet connect/disconnect
// callbacks keep the label correct as sections mount (and across turbo broadcasts that
// add/remove sections), and re-sync after a user clicks an individual section chevron.
export default class extends Controller {
  static outlets = ["category-collapse"]
  static targets = ["label"]

  categoryCollapseOutletConnected() {
    this.syncLabel()
  }

  categoryCollapseOutletDisconnected() {
    this.syncLabel()
  }

  toggle() {
    // If everything is already collapsed, the action is to expand; otherwise collapse.
    const expand = this.allCollapsed
    this.categoryCollapseOutlets.forEach((section) => {
      expand ? section.expand() : section.collapse()
    })
    this.syncLabel()
  }

  // True only when there is at least one section and every one of them is collapsed.
  get allCollapsed() {
    const sections = this.categoryCollapseOutlets
    return sections.length > 0 && sections.every((section) => section.collapsed)
  }

  syncLabel() {
    const expand = this.allCollapsed
    const text = expand ? "Expand all" : "Collapse all"
    if (this.hasLabelTarget) this.labelTarget.textContent = text
    this.element.setAttribute("aria-label", `${text} categories`)
    // aria-expanded reflects whether the sections are expanded: false when all collapsed.
    this.element.setAttribute("aria-expanded", String(!expand))
  }
}
