import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"

// Drag-and-drop categorization of session cards on the dashboard.
//
// Every category section — including "Uncategorized" — exposes its card grid as a
// "list" target. All lists share a single Sortable group, so a card can be dragged
// from any section into any other (empty sections included). When a card lands in a
// different section we PATCH the session's category_id so the assignment survives a
// reload. Sortable's touch support (with a long-press delay) makes this work on
// mobile while still allowing the page to scroll.
//
// listTargetConnected fires for sections present at load AND for sections appended
// later by the "+" button, so dynamically created categories become drop targets
// without any extra wiring.
//
// The controller also reorders whole category sections: the #category_sections
// container is the "sections" target, a second Sortable whose draggable unit is each
// <section> (grabbed by its .category-drag-handle). A reorder POSTs the new id order
// to reorderUrl. Both drag handles additionally support right-click (contextmenu):
// a card handle opens a "move to category" menu, a category handle opens a
// "move in stack" menu — sharing the single "menu" target element.
export default class extends Controller {
  static targets = ["list", "sections", "menu"]
  static values = {
    setCategoryUrlTemplate: String,
    createUrl: String,
    reorderUrl: String
  }

  connect() {
    // Bound handlers so the same references can be added and removed.
    this.dismissMenuBound = (event) => this.dismissMenu(event)
    this.menuKeydownBound = (event) => this.menuKeydown(event)
  }

  disconnect() {
    this.closeMenu()
  }

  listTargetConnected(element) {
    // CRITICAL: never spin up a card Sortable while a drag is in flight. When the
    // section Sortable reorders the stack it relocates the dragged <section> within
    // #category_sections; because that <section> nests a .category-grid (this "list"
    // target), Stimulus's MutationObserver reports the relocation as a remove+add and
    // fires listTargetDisconnected→listTargetConnected MID-DRAG. Creating (or
    // destroying) a card Sortable at that moment corrupts SortableJS's module-level
    // drag state — the classic "Cannot read properties of null (reading
    // '_onTouchMove')" flood on every subsequent pointer move that freezes the page.
    // The relocated element keeps its existing instance untouched, so deferring is
    // safe for it. A *genuine* connect during a drag is rare (a real-time Turbo
    // broadcast inserting a new section, or a pagination/collapse frame swap landing
    // mid-drag) — that element would be deferred here and, since Stimulus target
    // callbacks fire only on real connect/disconnect, never revisited. The section
    // Sortable's onEnd runs reconcileCardSortables() to attach any such grid once the
    // drag ends. See dragInProgress below.
    if (this.dragInProgress) return
    this.createCardSortable(element)
  }

  // Tear down the Sortable instance when a section leaves the DOM (e.g. a category
  // is deleted) so it doesn't leak listeners.
  listTargetDisconnected(element) {
    // Mirror of listTargetConnected: a disconnect fired during a drag is a transient
    // relocation, not a real removal. Destroying the card Sortable mid-drag is exactly
    // what corrupts SortableJS's global drag state, so leave it attached — the matching
    // (also-skipped) listTargetConnected keeps the live instance in place. Genuine
    // removals never happen during a drag, so deferring teardown costs nothing.
    if (this.dragInProgress) return
    if (element.sortableInstance) {
      element.sortableInstance.destroy()
      element.sortableInstance = null
    }
  }

  // Build the per-section card Sortable. Idempotent so a redundant connect (or a
  // connect that races a relocation) never stacks two instances on one grid.
  createCardSortable(element) {
    if (element.sortableInstance) return
    element.sortableInstance = Sortable.create(element, {
      group: "sessions",
      animation: 150,
      // Only the grab bar starts a drag, and the draggable unit is the card's
      // <turbo-frame> wrapper — so clicks on the card's own controls never begin a
      // move and partial DOM updates inside a card don't confuse Sortable.
      handle: ".session-drag-handle",
      draggable: "turbo-frame",
      ghostClass: "sortable-ghost",
      chosenClass: "sortable-chosen",
      dragClass: "sortable-drag",
      // Use Sortable's own pointer-based dragging on every device instead of the
      // native HTML5 Drag-and-Drop API. Native DnD does not work on touch devices
      // at all, so forcing the fallback gives one consistent code path that works
      // on both desktop (mouse) and mobile (touch).
      forceFallback: true,
      fallbackTolerance: 3,
      // No fallbackOnBody here (unlike the section Sortable below): a card's
      // draggable unit is its <turbo-frame> wrapper, whose subtree carries no
      // data-category-dnd-target. The forceFallback ghost clone therefore can't
      // re-trigger a Stimulus target callback, so it's safe to leave the ghost in
      // this element. Only the section clone nests a target-bearing .category-grid.
      // Require a long-press before dragging on touch devices so vertical
      // scrolling still works normally.
      delayOnTouchOnly: true,
      delay: 200,
      onEnd: (event) => this.persist(event)
    })
  }

  // True while ANY SortableJS forceFallback drag (card or section) is in progress.
  // SortableJS adds the floating ghost's drag/fallback classes when the drag starts
  // and strips them on drop, so their presence in the document is a reliable,
  // lifecycle-accurate signal — unlike Sortable.active, which only sets after a real
  // _dragStarted and is therefore unavailable here under synthetic input. Scoped to
  // the floating ghost classes (not ghostClass/chosenClass, which also tag the
  // stationary source element) to read the drag's true in-flight state. The query is
  // document-wide on purpose: the section Sortable uses fallbackOnBody, so its ghost
  // lives on <body> (outside this.element) — scoping to the controller would miss it.
  get dragInProgress() {
    return document.querySelector(".sortable-drag, .sortable-fallback") !== null
  }

  // After a section drag, attach a card Sortable to any list target that connected
  // mid-drag and was deferred by the dragInProgress guard (see listTargetConnected).
  // Idempotent via createCardSortable's own guard, so already-attached grids are
  // skipped — this only revives the rare grid that would otherwise be left without one.
  reconcileCardSortables() {
    this.listTargets.forEach((element) => this.createCardSortable(element))
  }

  // Make the category sections themselves sortable. The draggable unit is each
  // <section> and only its .category-drag-handle starts a drag, so dragging a card
  // (handled by the separate "sessions" group above) never reorders the stack.
  sectionsTargetConnected(element) {
    element.sortableInstance = Sortable.create(element, {
      group: "categories",
      animation: 150,
      handle: ".category-drag-handle",
      draggable: "section",
      ghostClass: "sortable-ghost",
      chosenClass: "sortable-chosen",
      dragClass: "sortable-drag",
      forceFallback: true,
      fallbackTolerance: 3,
      // Append the drag ghost to <body>, not to #category_sections. With
      // forceFallback the ghost is a deep clone of the dragged <section>, which
      // contains a .category-grid carrying data-category-dnd-target="list". If that
      // clone were appended inside this controller's element (the default), Stimulus
      // would fire listTargetConnected for the clone mid-drag and spin up a throwaway
      // Sortable on it — then destroy it when the ghost is removed — corrupting
      // SortableJS's module-level drag state. The symptom was a flood of
      // "Cannot read properties of null (reading '_onTouchMove')" errors on every
      // pointer move and a ghost section left orphaned in the DOM (the page "freeze").
      // Putting the ghost on <body> keeps it outside the controller's scope.
      fallbackOnBody: true,
      delayOnTouchOnly: true,
      delay: 200,
      onEnd: () => {
        this.persistOrder()
        // Re-attach any list target that connected mid-drag while the guard was active.
        this.reconcileCardSortables()
      }
    })
  }

  sectionsTargetDisconnected(element) {
    if (element.sortableInstance) {
      element.sortableInstance.destroy()
      element.sortableInstance = null
    }
  }

  // POST the current top-to-bottom order of category ids so the new stacking
  // survives a reload. Reads the live DOM order of the section elements.
  persistOrder() {
    if (!this.hasSectionsTarget || !this.hasReorderUrlValue) return

    const ids = Array.from(
      this.sectionsTarget.querySelectorAll("[data-category-section-id]")
    ).map((section) => section.dataset.categorySectionId)

    fetch(this.reorderUrlValue, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        "X-CSRF-Token": this.csrfToken
      },
      body: JSON.stringify({ ids })
    }).then((response) => {
      if (!response.ok) console.error("Failed to persist category order", response.status)
    }).catch((error) => {
      console.error("Failed to persist category order", error)
    })
  }

  // Right-click a card's drag handle: offer to move it into any other category
  // (including Uncategorized), skipping the one it's already in.
  openCardMenu(event) {
    event.preventDefault()
    const handle = event.currentTarget
    const sessionId = handle.dataset.sessionId
    if (!sessionId) return

    const currentList = handle.closest("[data-category-dnd-target='list']")
    const currentCategoryId = currentList ? (currentList.dataset.categoryId || "") : ""

    const items = this.categoryOptions()
      .filter((option) => option.id !== currentCategoryId)
      .map((option) => ({
        label: `Move to ${option.name}`,
        action: () => this.moveCardTo(sessionId, option.id)
      }))

    if (items.length === 0) return
    this.showMenu(event, items)
  }

  // Right-click a category's drag handle: offer stack-position moves relative to the
  // category's current spot. Top/Up/Down/Bottom are only shown when meaningful.
  openCategoryMenu(event) {
    event.preventDefault()
    const handle = event.currentTarget
    const categoryId = handle.dataset.categoryId
    if (!categoryId || !this.hasSectionsTarget) return

    const sections = Array.from(
      this.sectionsTarget.querySelectorAll("[data-category-section-id]")
    )
    const index = sections.findIndex((section) => section.dataset.categorySectionId === String(categoryId))
    if (index === -1) return

    const items = []
    if (index > 0) {
      items.push({ label: "Move to top", action: () => this.moveCategory(categoryId, "top") })
      items.push({ label: "Move up", action: () => this.moveCategory(categoryId, "up") })
    }
    if (index < sections.length - 1) {
      items.push({ label: "Move down", action: () => this.moveCategory(categoryId, "down") })
      items.push({ label: "Move to bottom", action: () => this.moveCategory(categoryId, "bottom") })
    }

    if (items.length === 0) return
    this.showMenu(event, items)
  }

  // Move a card into a category via the menu: persist the assignment, then relocate
  // its <turbo-frame> into the destination grid so the UI matches without a reload.
  moveCardTo(sessionId, categoryId) {
    const url = this.setCategoryUrlTemplateValue.replace("__SESSION_ID__", sessionId)

    fetch(url, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        "X-CSRF-Token": this.csrfToken
      },
      body: JSON.stringify({ category_id: categoryId })
    })
      .then((response) => {
        if (!response.ok) {
          console.error("Failed to move card", response.status)
          return
        }
        const frame = document.getElementById(`session_${sessionId}`)
        const destination = this.listTargets.find((list) => (list.dataset.categoryId || "") === categoryId)
        if (frame && destination) destination.appendChild(frame)
      })
      .catch((error) => console.error("Failed to move card", error))
  }

  // Reposition a category in the stack via the menu, then persist the new order.
  moveCategory(categoryId, action) {
    if (!this.hasSectionsTarget) return
    const container = this.sectionsTarget
    const section = container.querySelector(`[data-category-section-id='${categoryId}']`)
    if (!section) return

    let moved = false
    switch (action) {
      case "top":
        if (section.previousElementSibling) { container.prepend(section); moved = true }
        break
      case "bottom":
        if (section.nextElementSibling) { container.append(section); moved = true }
        break
      case "up":
        if (section.previousElementSibling) {
          container.insertBefore(section, section.previousElementSibling)
          moved = true
        }
        break
      case "down":
        if (section.nextElementSibling) {
          container.insertBefore(section.nextElementSibling, section)
          moved = true
        }
        break
    }

    // Only persist when the stack actually changed — avoids a no-op POST.
    if (moved) this.persistOrder()
  }

  // The category targets available as move destinations: Uncategorized plus every
  // real category, read from the live "list" grids so newly created sections appear.
  categoryOptions() {
    return this.listTargets.map((list) => {
      const id = list.dataset.categoryId || ""
      const section = list.closest("section")
      const heading = section ? section.querySelector("h2") : null
      const name = heading ? heading.textContent.trim() : "Uncategorized"
      return { id, name }
    })
  }

  // Populate, position, and reveal the shared menu at the cursor.
  showMenu(event, items) {
    if (!this.hasMenuTarget) return
    // Tear down any menu still open (and its deferred document listeners) before
    // re-registering, so listeners can never accumulate.
    this.closeMenu()
    const menu = this.menuTarget
    menu.innerHTML = ""

    items.forEach((item) => {
      const button = document.createElement("button")
      button.type = "button"
      button.role = "menuitem"
      button.className = "block w-full text-left px-3 py-1.5 text-gray-700 hover:bg-indigo-50 hover:text-indigo-700"
      button.textContent = item.label
      button.addEventListener("click", () => {
        this.closeMenu()
        item.action()
      })
      menu.appendChild(button)
    })

    menu.classList.remove("hidden")

    // Position at the cursor, clamped into the viewport so it never overflows.
    const { innerWidth, innerHeight } = window
    const rect = menu.getBoundingClientRect()
    const left = Math.min(event.clientX, innerWidth - rect.width - 8)
    const top = Math.min(event.clientY, innerHeight - rect.height - 8)
    menu.style.left = `${Math.max(8, left)}px`
    menu.style.top = `${Math.max(8, top)}px`

    // Defer so the click that opened the menu doesn't immediately dismiss it.
    setTimeout(() => {
      document.addEventListener("click", this.dismissMenuBound)
      document.addEventListener("contextmenu", this.dismissMenuBound)
      document.addEventListener("keydown", this.menuKeydownBound)
    }, 0)
  }

  // Dismiss on any click/right-click outside the menu itself.
  dismissMenu(event) {
    if (this.hasMenuTarget && this.menuTarget.contains(event.target)) return
    this.closeMenu()
  }

  menuKeydown(event) {
    if (event.key === "Escape") this.closeMenu()
  }

  closeMenu() {
    if (this.hasMenuTarget) {
      this.menuTarget.classList.add("hidden")
      this.menuTarget.innerHTML = ""
    }
    document.removeEventListener("click", this.dismissMenuBound)
    document.removeEventListener("contextmenu", this.dismissMenuBound)
    document.removeEventListener("keydown", this.menuKeydownBound)
  }

  // Persist a card that moved into a different category section.
  persist(event) {
    // Reordering within the same section is not meaningful — only cross-section
    // moves change a session's category.
    if (event.from === event.to) return

    const sessionId = this.sessionIdFor(event.item)
    if (!sessionId) return

    const categoryId = event.to.dataset.categoryId || ""
    const url = this.setCategoryUrlTemplateValue.replace("__SESSION_ID__", sessionId)

    fetch(url, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        "X-CSRF-Token": this.csrfToken
      },
      body: JSON.stringify({ category_id: categoryId })
    })
      .then((response) => {
        if (!response.ok) {
          console.error("Failed to persist category assignment", response.status)
          this.revert(event)
        }
      })
      .catch((error) => {
        console.error("Failed to persist category assignment", error)
        this.revert(event)
      })
  }

  // Put a card back in the section it came from when the server rejects the move,
  // so the UI never shows an assignment that wasn't actually saved.
  revert(event) {
    const reference = event.from.children[event.oldIndex] || null
    event.from.insertBefore(event.item, reference)
  }

  // Prompt for a name and create a new category. The server responds with a Turbo
  // Stream that appends the new (empty) section, which becomes a drop target via
  // listTargetConnected.
  addCategory(event) {
    event.preventDefault()
    const name = window.prompt("New category name:")
    if (!name || !name.trim()) return

    fetch(this.createUrlValue, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "text/vnd.turbo-stream.html",
        "X-CSRF-Token": this.csrfToken
      },
      body: JSON.stringify({ name: name.trim() })
    })
      .then((response) => {
        if (!response.ok) {
          return response.json().then((data) => {
            throw new Error(data.error || `HTTP ${response.status}`)
          })
        }
        return response.text()
      })
      .then((html) => {
        if (html) window.Turbo.renderStreamMessage(html)
      })
      .catch((error) => {
        console.error("Failed to create category", error)
        window.alert(`Could not create category: ${error.message}`)
      })
  }

  // The draggable item is the <turbo-frame id="session_123"> wrapping a card.
  sessionIdFor(item) {
    const match = (item.id || "").match(/session_(\d+)/)
    return match ? match[1] : null
  }

  get csrfToken() {
    const meta = document.querySelector('meta[name="csrf-token"]')
    return meta ? meta.content : ""
  }
}
