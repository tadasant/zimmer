import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"
import { csrfHeaders } from "lib/csrf"

// Connects to data-controller="user-view"
//
// The dashboard's User view: one list of every session the filters match, worked
// top to bottom. This controller owns exactly two things — the drag that moves a
// row, and keeping the list in the order the server would render it.
//
// WHAT IT DELIBERATELY DOES NOT OWN
//
// Trash and Snooze are not here. Trash is a plain form POST to #archive, which
// answers with a turbo stream that removes this row — server-driven because the
// first click over a session with queued messages does NOT archive, it offers an
// "Archive anyway" speed bump, and a row the browser had already taken away would
// have claimed otherwise. Snooze is the shared `visibility` controller, which
// removes any `[data-visibility-unit]` ancestor when a session leaves the board.
// Both were already correct; re-implementing either here would only give the board
// a second opinion about what happened.
//
// ORDERING, AND WHY A DRAG CAN SNAP BACK
//
// The board's order is (priority before spot, then precedence descending, then
// oldest first). A drag names its new neighbours and the server derives a
// precedence from them (Sessions::ReorderPrecedence), so the midpoint rule lives
// in one place and not in this file.
//
// Precedence cannot express "this spot session outranks that priority one" — the
// class is the primary sort key and no integer beats it. So a row dropped outside
// its own class block is reseated into that block: the neighbours sent to the
// server are the nearest rows OF THE SAME CLASS, and `sortRows` then puts the row
// where the real order says it goes. It settles visibly rather than pretending.
export default class extends Controller {
  static targets = ["list", "row", "handle", "count", "empty", "error"]
  static values = {
    // "/sessions/__ID__/reorder_precedence" — the row supplies the id.
    reorderUrlTemplate: String
  }

  connect() {
    this.sortable = Sortable.create(this.listTarget, {
      animation: 150,
      // A long press rather than an immediate grab on touch, so the page still
      // scrolls on a phone.
      delay: 200,
      delayOnTouchOnly: true,
      handle: "[data-user-view-target='handle']",
      // Sortable's own pointer-based dragging on every device, rather than the
      // native HTML5 Drag-and-Drop API. Native DnD does not work on touch devices
      // at all, and this board is read on a phone — so forcing the fallback is one
      // code path that works with a mouse and with a thumb, which is the same call
      // the dashboard's card grid made. It also makes the drag reachable from a
      // WebDriver, which is how test/system/user_view_board_test.rb proves the
      // reorder actually persists rather than proving a drag merely started.
      forceFallback: true,
      fallbackTolerance: 3,
      // The fallback drags a CLONE of the row, and without this it is parked inside
      // the list — a second element carrying the row's id, which the MutationObserver
      // below would then see as a row arriving and try to sort. On the body it is out
      // of the list's way entirely.
      fallbackOnBody: true,
      // While a row is in hand, SortableJS moves it inside the list on every pointer
      // move. The list's MutationObserver would see each of those moves and re-sort
      // the row straight back into precedence order — so the row snaps back, the
      // drop reports the index it started at, and nothing is saved. The flag is what
      // tells `reconcile` to leave a drag alone.
      onStart: () => { this.dragging = true },
      onEnd: (event) => {
        this.dragging = false
        this.persistDrop(event)
      }
    })

    // Hung off the list so a system test can wait for the drag to be armed before
    // it presses the mouse down. Stimulus controllers load asynchronously, so a row
    // can be on the page a beat before the Sortable that makes it draggable is —
    // and a drag started in that beat silently does nothing.
    this.listTarget.sortableInstance = this.sortable

    // A row can arrive or leave without this controller doing it: an Undo
    // prepends one over a turbo stream, Trash removes one, Snooze removes one.
    // Watching the list itself keeps the count and the empty state true whoever
    // moved a row, and re-seats a restored row into its proper place rather than
    // leaving it stranded at the top.
    this.listObserver = new MutationObserver((records) => this.reconcile(records))
    this.listObserver.observe(this.listTarget, { childList: true })
  }

  disconnect() {
    if (this.sortable) this.sortable.destroy()
    delete this.listTarget.sortableInstance
    if (this.listObserver) this.listObserver.disconnect()
  }

  // ---- Drag and drop --------------------------------------------------------

  persistDrop(event) {
    // SortableJS reports a drop even when the row was released exactly where it
    // was picked up. Writing then would nudge two neighbours and log a move for a
    // grab that changed nothing.
    if (event.oldIndex === event.newIndex) return

    const row = event.item
    const above = this.nearestSibling(row, "previousElementSibling")
    const below = this.nearestSibling(row, "nextElementSibling")

    this.clearError()
    this.patch(this.reorderUrlTemplateValue.replace("__ID__", row.dataset.sessionId), {
      above_id: above ? above.dataset.sessionId : null,
      below_id: below ? below.dataset.sessionId : null
    })
      .then((payload) => {
        this.applyServerValues(payload)
        // A nudged neighbour can have moved past the row beyond it, and a row
        // dropped outside its class block has to come back to it — so re-sort
        // rather than trusting where the pointer let go.
        this.sortRows()
      })
      .catch((error) => this.rollback(error))
  }

  // The nearest row in `direction` that shares this row's scheduling class.
  //
  // Rows of the other class are skipped rather than sent, because precedence is
  // only comparable within a class: handing the server a priority row as the
  // neighbour of a spot row would derive a value from a number the board does not
  // rank them by.
  nearestSibling(row, direction) {
    let candidate = row[direction]
    while (candidate) {
      if (candidate.dataset.priorityClass === row.dataset.priorityClass) return candidate
      candidate = candidate[direction]
    }
    return null
  }

  applyServerValues(payload) {
    if (!payload) return

    const changes = [payload, ...(payload.changes || [])]
    changes.forEach((change) => {
      const row = this.rowFor(change.id)
      if (row && typeof change.precedence === "number") {
        row.dataset.precedence = String(change.precedence)
        const readout = row.querySelector("[data-user-view-precedence]")
        if (readout) readout.textContent = `#${change.precedence}`
      }
    })
  }

  // ---- Order ----------------------------------------------------------------

  // The server's order, reproduced: priority above spot, then precedence
  // descending, then oldest first (id ascending stands in for created_at — ids are
  // monotonic, and this only ever breaks ties the server broke the same way).
  sortRows() {
    const rows = Array.from(this.listTarget.children)
    rows.sort((a, b) => {
      const classDelta = this.classRank(b) - this.classRank(a)
      if (classDelta !== 0) return classDelta

      const delta = Number(b.dataset.precedence) - Number(a.dataset.precedence)
      if (delta !== 0) return delta

      return Number(a.dataset.sessionId) - Number(b.dataset.sessionId)
    })
    rows.forEach((row) => this.listTarget.appendChild(row))
  }

  classRank(row) {
    return row.dataset.priorityClass === "priority" ? 1 : 0
  }

  // ---- Reconciliation -------------------------------------------------------

  // Runs whenever a row arrives or leaves. Three guards, each load-bearing:
  //
  //   * Never mid-drag — see `onStart`. Re-sorting under SortableJS is what made a
  //     real drag snap back and save nothing.
  //   * Only re-sort when a row ARRIVED (an Undo putting one back). A row leaving —
  //     Trash, Snooze — cannot put the rest out of order, so it only needs the
  //     count refreshed.
  //   * Not against its own writes: a re-sort is a series of appendChild calls,
  //     which the observer would see as more mutations, so the flag stops it looping.
  reconcile(records = []) {
    if (this.dragging || this.reconciling) return
    this.reconciling = true

    try {
      const rowArrived = records.some((record) => record.addedNodes.length > 0)
      if (rowArrived) this.sortRows()
      this.refreshCount()
    } finally {
      // Released after the observer has drained the mutations this made.
      queueMicrotask(() => { this.reconciling = false })
    }
  }

  refreshCount() {
    const count = this.rowTargets.length
    if (this.hasCountTarget) this.countTarget.textContent = String(count)
    if (this.hasEmptyTarget) this.emptyTarget.classList.toggle("hidden", count > 0)
    this.listTarget.classList.toggle("hidden", count === 0)
  }

  rowFor(sessionId) {
    return this.rowTargets.find((row) => row.dataset.sessionId === String(sessionId))
  }

  // ---- Requests -------------------------------------------------------------

  patch(url, body) {
    return fetch(url, {
      method: "PATCH",
      headers: csrfHeaders({ Accept: "application/json" }),
      body: JSON.stringify(body)
    }).then(async (response) => {
      const payload = await response.json().catch(() => null)
      if (!response.ok) throw new Error(payload && payload.error ? payload.error : `Request failed (${response.status})`)
      return payload
    })
  }

  // A write that did not land must not leave the board claiming it did. Reloading
  // is the honest rollback: the server's order is the only one that matters, and a
  // failed reorder may have moved several rows.
  rollback(error) {
    this.showError(`${error.message}. Reloading to show the saved order.`)
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
