import { Controller } from "@hotwired/stimulus"

// Collapse/expand a single category section on the dashboard.
//
// Mounted on each <section> (every category plus the "Uncategorized" bucket). Clicking
// the chevron toggle in the header flips a `category-collapsed` class on the section;
// CSS hides the section's body (the grid + its pagination, wrapped in a turbo-frame)
// and rotates the chevron. The collapsed state is persisted to localStorage keyed by
// the section's stable key (a category id, or the "uncategorized" sentinel) so it
// survives full reloads.
//
// The controller lives on the <section>, which is outside the per-category turbo-frame,
// so per-category pagination (which swaps only the frame's contents) never tears down
// this controller or loses the collapsed state.
export default class extends Controller {
  static values = { key: String }

  connect() {
    // Reflect the persisted state on first paint. The chevron/body default to expanded
    // in the server markup, so we only need to act when the stored state is collapsed.
    if (this.persistedCollapsed) {
      this.element.classList.add("category-collapsed")
    }
    this.syncAria()
    // Announce a restored-collapsed section so the page-level collapse-all toggle derives
    // its label from actual state, not from controller connection ordering. (Restoring
    // collapsed goes through classList.add above, which would otherwise skip a dispatch.)
    if (this.collapsed) {
      this.dispatch("changed", { detail: { collapsed: true }, bubbles: true })
    }
  }

  toggle() {
    this.setCollapsed(!this.collapsed)
  }

  // Public entry points used by the page-level collapse-all controller (via the Stimulus
  // outlets API). They funnel through setCollapsed so persistence + aria stay owned here,
  // the single source of truth — the all-sections controller never touches localStorage.
  collapse() {
    this.setCollapsed(true)
  }

  expand() {
    this.setCollapsed(false)
  }

  get collapsed() {
    return this.element.classList.contains("category-collapsed")
  }

  // Apply a collapsed state, persist it, and sync aria. A no-op when already in the
  // requested state so a "collapse all" over an already-collapsed section writes nothing.
  setCollapsed(collapsed) {
    if (collapsed === this.collapsed) return
    this.element.classList.toggle("category-collapsed", collapsed)
    this.persist(collapsed)
    this.syncAria()
    // Announce the change so the page-level collapse-all toggle can re-derive its label
    // when an individual chevron (not the all-button) flips a section. Bubbles to window.
    this.dispatch("changed", { detail: { collapsed }, bubbles: true })
  }

  get persistedCollapsed() {
    try {
      return window.localStorage.getItem(this.storageKey) === "1"
    } catch {
      // localStorage can throw in private mode / when disabled — degrade to expanded.
      return false
    }
  }

  persist(collapsed) {
    try {
      if (collapsed) {
        window.localStorage.setItem(this.storageKey, "1")
      } else {
        window.localStorage.removeItem(this.storageKey)
      }
    } catch {
      // Ignore persistence failures; the in-page toggle still works for this session.
    }
  }

  // Keep the toggle button's aria-expanded in sync with the visual state for a11y.
  syncAria() {
    const expanded = !this.element.classList.contains("category-collapsed")
    this.element
      .querySelectorAll("[data-category-collapse-toggle]")
      .forEach((button) => button.setAttribute("aria-expanded", String(expanded)))
  }

  get storageKey() {
    return `ao:dashboard:category-collapsed:${this.keyValue}`
  }
}
