import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"
import { csrfHeaders } from "lib/csrf"

// Connects to data-controller="board-v2"
//
// Your board v2: sessions grouped into categories the operator makes by hand.
// This controller owns three drags and one toggle:
//
//   * a row dragged into another group — writes the session's category
//     (PATCH /sessions/:id/board_category). Within a group a drag does nothing:
//     the order there is most recently touched first, and the row settles back.
//   * a category header dragged — writes the order of every category
//     (PATCH /board_categories/reorder).
//   * a category's chevron — collapses or expands it, and stores that on the
//     category so it survives a reload (PATCH /board_categories/:id).
//
// Trash, Snooze, Merge and CarPlay on a row are the row's own controls, exactly
// as on Your board. A row that leaves (Trash, Snooze) or arrives (Undo) is seen
// by each list's MutationObserver, which keeps the counts and the order true.
//
// Every Sortable forces the pointer-based fallback, for the reason the User
// view's does: native HTML5 drag and drop does not work on a phone.
export default class extends Controller {
  static targets = ["list", "categories", "category", "total", "error"]
  static values = {
    assignUrlTemplate: String,
    reorderUrl: String,
    categoryUrlTemplate: String
  }

  connect() {
    if (this.hasCategoriesTarget) {
      this.categorySortable = Sortable.create(this.categoriesTarget, {
        animation: 150,
        delay: 200,
        delayOnTouchOnly: true,
        handle: "[data-board-v2-category-handle]",
        draggable: "[data-board-v2-target='category']",
        forceFallback: true,
        fallbackTolerance: 3,
        fallbackOnBody: true,
        onEnd: (event) => this.persistCategoryOrder(event)
      })
      this.categoriesTarget.sortableInstance = this.categorySortable
    }
  }

  disconnect() {
    if (this.categorySortable) this.categorySortable.destroy()
  }

  // One Sortable and one observer per group's list, set up as each list
  // connects — so a list Turbo swaps in later is wired the same way.
  listTargetConnected(list) {
    // Already wired: a category dragged to a new place is the same element
    // moved, which Stimulus reports as a disconnect and a connect.
    if (list.sortableInstance) return

    list.sortableInstance = Sortable.create(list, {
      group: "board-v2-sessions",
      // Order inside a group is the server's (last touched); only moving
      // between groups means anything.
      sort: false,
      animation: 150,
      delay: 200,
      delayOnTouchOnly: true,
      handle: "[data-board-v2-target='handle']",
      forceFallback: true,
      fallbackTolerance: 3,
      fallbackOnBody: true,
      onStart: () => { this.dragging = true },
      onEnd: (event) => {
        this.dragging = false
        this.persistMove(event)
      }
    })

    list.boardV2Observer = new MutationObserver((records) => this.reconcile(list, records))
    list.boardV2Observer.observe(list, { childList: true })
  }

  listTargetDisconnected(list) {
    // A list still in the document was only moved (its category was dragged).
    // Destroying its Sortable now would end the category drag in progress:
    // SortableJS's destroy() runs a drop against the shared drag state, so the
    // category would land with no `onEnd` and nothing saved.
    if (list.isConnected) return

    if (list.sortableInstance) list.sortableInstance.destroy()
    delete list.sortableInstance
    if (list.boardV2Observer) list.boardV2Observer.disconnect()
  }

  // ---- Moving a session between groups -------------------------------------

  persistMove(event) {
    const row = event.item
    const from = event.from
    const to = event.to
    if (from === to) {
      // A drag inside one group: put the row back where the order says.
      this.sortList(to)
      return
    }

    this.sortList(to)
    this.refreshCounts()
    this.clearError()

    const url = this.assignUrlTemplateValue.replace("__ID__", row.dataset.sessionId)
    this.request("PATCH", url, { board_category_id: to.dataset.categoryId || null })
      .catch((error) => this.rollback(error))
  }

  // ---- Reordering categories -----------------------------------------------

  persistCategoryOrder(event) {
    if (event.oldIndex === event.newIndex) return

    const ids = this.categoryTargets.map((category) => category.dataset.categoryId)
    this.clearError()
    this.request("PATCH", this.reorderUrlValue, { category_ids: ids })
      .catch((error) => this.rollback(error))
  }

  // ---- Collapse ------------------------------------------------------------

  toggle(event) {
    event.preventDefault()
    const button = event.currentTarget
    const category = button.closest("[data-board-v2-target='category']")
    if (!category) return

    const body = category.querySelector("[data-board-v2-body]")
    const chevron = category.querySelector("[data-board-v2-chevron]")
    const collapsed = !body.classList.contains("hidden")
    body.classList.toggle("hidden", collapsed)
    if (chevron) chevron.classList.toggle("-rotate-90", collapsed)
    button.setAttribute("aria-expanded", String(!collapsed))

    const url = this.categoryUrlTemplateValue.replace("__ID__", category.dataset.categoryId)
    this.request("PATCH", url, { collapsed })
      .catch((error) => this.rollback(error))
  }

  // ---- Order and counts ----------------------------------------------------

  // Most recently touched first, newest id breaking ties — the server's
  // LAST_TOUCHED_ORDER, id desc.
  sortList(list) {
    const rows = Array.from(list.children)
    rows.sort((a, b) => {
      const delta = Number(b.dataset.lastTouched) - Number(a.dataset.lastTouched)
      if (delta !== 0) return delta
      return Number(b.dataset.sessionId) - Number(a.dataset.sessionId)
    })
    this.reconciling = true
    rows.forEach((row) => list.appendChild(row))
    queueMicrotask(() => { this.reconciling = false })
  }

  reconcile(list, records) {
    if (this.dragging || this.reconciling) return
    if (records.some((record) => record.addedNodes.length > 0)) this.sortList(list)
    this.refreshCounts()
  }

  refreshCounts() {
    let total = 0
    this.listTargets.forEach((list) => {
      const count = list.querySelectorAll(":scope > [data-board-v2-target='row']").length
      total += count
      const group = list.closest("[data-board-v2-body]")?.parentElement
      if (!group) return
      const badge = group.querySelector("[data-board-v2-count]")
      if (badge) badge.textContent = String(count)
      const empty = group.querySelector("[data-board-v2-empty]")
      if (empty) empty.classList.toggle("hidden", count > 0)
    })
    if (this.hasTotalTarget) this.totalTarget.textContent = String(total)
  }

  // ---- Requests ------------------------------------------------------------

  request(method, url, body) {
    return fetch(url, {
      method,
      headers: csrfHeaders({ Accept: "application/json" }),
      body: JSON.stringify(body)
    }).then(async (response) => {
      const payload = await response.json().catch(() => null)
      if (!response.ok) throw new Error(payload && payload.error ? payload.error : `Request failed (${response.status})`)
      return payload
    })
  }

  // A write that did not land must not leave the board claiming it did; the
  // server's arrangement is the only one that counts, so reload to it.
  rollback(error) {
    this.showError(`${error.message}. Reloading to show the saved board.`)
    setTimeout(() => window.location.reload(), 2500)
  }

  showError(message) {
    if (!this.hasErrorTarget) return
    this.errorTarget.textContent = message
    this.errorTarget.classList.remove("hidden")
  }

  clearError() {
    if (!this.hasErrorTarget) return
    this.errorTarget.textContent = ""
    this.errorTarget.classList.add("hidden")
  }
}
