import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"

// The Ranked view: managing the spot queue in place.
//
// Three interactions, all of which must feel immediate — this is a screen for
// reordering forty rows, and a page reload between each one would make it
// unusable:
//
//   1. Type a precedence and press Enter. The row moves to its new position
//      straight away and the value is PATCHed behind it.
//   2. Drag a row between two others. The server derives the value from the two
//      neighbours it was dropped between (midpoint, nudging them apart when they
//      are adjacent) and returns every value that moved, so the numbers on screen
//      correct themselves without a fetch of the whole list.
//   3. Promote / demote. The row moves between the two sections. A demotion asks
//      the server to place it at the head of the spot queue, since the value it
//      carried while it was priority is almost always the bottom.
//
// Every write is optimistic and every failure rolls back to what the server last
// confirmed, so a rejected edit cannot leave the page showing an order the
// database does not have.
export default class extends Controller {
  static targets = [
    "priorityList", "spotList", "priorityEmpty", "spotEmpty", "row",
    "precedenceInput", "precedenceReadout", "error",
    "priorityCount", "spotCount", "promoteAction", "demoteAction"
  ]
  static values = { slotGap: Number }

  connect() {
    this.sortable = Sortable.create(this.spotListTarget, {
      animation: 150,
      // A long press rather than an immediate grab on touch, so the page still
      // scrolls on a phone.
      delay: 200,
      delayOnTouchOnly: true,
      handle: "[data-ranked-queue-target='handle']",
      onEnd: (event) => this.persistDrop(event)
    })

    // The section headers and the "nothing here" placeholders are server-rendered
    // from the row count, and rows now leave on their own: a trashed session is
    // removed by a Turbo Stream that knows nothing about this controller. Watch
    // the lists rather than trying to intercept the stream, so the counts stay
    // true whoever changed them — a broadcast, a promote, or a demote.
    this.listObserver = new MutationObserver(() => this.refreshCounts())
    ;[this.priorityListTarget, this.spotListTarget].forEach((list) => {
      this.listObserver.observe(list, { childList: true })
    })
  }

  disconnect() {
    if (this.sortable) this.sortable.destroy()
    if (this.listObserver) this.listObserver.disconnect()
  }

  // ---- Inline editing -------------------------------------------------------

  // Enter commits. The row is moved first and reconciled after, so the list is
  // never briefly sorted by a value the user has not seen take effect.
  commitPrecedence(event) {
    event.preventDefault()
    const input = event.target
    const row = input.closest("[data-ranked-queue-target='row']")
    const value = parseInt(input.value, 10)

    if (Number.isNaN(value)) {
      this.revertRow(row)
      return
    }

    this.clearError()
    this.applyPrecedence(row, value)
    this.sortSpotRows()
    input.blur()

    this.patch(`/sessions/${row.dataset.sessionId}/update_precedence`, { precedence: value })
      .then((payload) => this.applyServerValues(payload))
      .catch((error) => this.rollback(error, row))
  }

  // A field left without pressing Enter goes back to the confirmed value, so a
  // half-typed number never lingers next to a row it does not describe.
  revertUncommitted(event) {
    const row = event.target.closest("[data-ranked-queue-target='row']")
    if (row) this.revertRow(row)
  }

  // ---- Drag and drop --------------------------------------------------------

  // The dropped row's new neighbours are whatever now sits above and below it in
  // the DOM. The server turns that into a value; the client does not guess one,
  // so the midpoint rule and its nudge have exactly one implementation.
  persistDrop(event) {
    // SortableJS reports a drop even when the row was released exactly where it
    // was picked up. Writing then would nudge two neighbours and log a move for
    // a grab that changed nothing.
    if (event.oldIndex === event.newIndex) return

    const row = event.item
    const above = row.previousElementSibling
    const below = row.nextElementSibling

    this.clearError()
    this.patch(`/sessions/${row.dataset.sessionId}/reorder_precedence`, {
      above_id: above ? above.dataset.sessionId : null,
      below_id: below ? below.dataset.sessionId : null
    })
      .then((payload) => {
        this.applyServerValues(payload)
        // A nudged neighbour can have moved past the row beyond it, so re-sort
        // rather than trusting the drop position.
        this.sortSpotRows()
      })
      .catch((error) => this.rollback(error, row))
  }

  // ---- Promote / demote -----------------------------------------------------

  demote(event) {
    const row = this.rowFor(event.currentTarget.dataset.sessionId)
    this.clearError()

    this.patch(`/sessions/${row.dataset.sessionId}/update_scheduling_class`, {
      scheduling_class: "spot",
      place: "top_of_spot"
    })
      .then((payload) => {
        this.applyServerValues(payload)
        this.moveToSpot(row)
        this.sortSpotRows()
      })
      .catch((error) => this.rollback(error, row))
  }

  promote(event) {
    const row = this.rowFor(event.currentTarget.dataset.sessionId)
    this.clearError()

    this.patch(`/sessions/${row.dataset.sessionId}/update_scheduling_class`, {
      scheduling_class: "priority"
    })
      .then((payload) => {
        this.applyServerValues(payload)
        this.moveToPriority(row)
        // Promoting a held session starts it. The row's status pill flips to
        // Running over the ranked stream, so a start that worked needs no
        // message here — but one the server refused (a session paused until a
        // chosen time, say) would otherwise look like it had started.
        if (payload && payload.start_outcome === "refused") this.showError(payload.start_message)
      })
      .catch((error) => this.rollback(error, row))
  }

  // ---- DOM plumbing ---------------------------------------------------------

  rowFor(sessionId) {
    return this.rowTargets.find((row) => row.dataset.sessionId === String(sessionId))
  }

  // Both rank cells are rendered on every row and one of them is hidden, so both
  // are written: whichever is showing now, and whichever a later promote or
  // demote reveals. Writing only the visible one would leave a demoted row at the
  // top of the queue still displaying the rank it carried while it was priority.
  applyPrecedence(row, value) {
    row.dataset.precedence = String(value)
    const input = row.querySelector("[data-ranked-queue-target='precedenceInput']")
    if (input) input.value = String(value)
    const readout = row.querySelector("[data-ranked-queue-target='precedenceReadout']")
    if (readout) readout.textContent = String(value)
  }

  // Apply whatever the server confirmed: the edited row, plus any neighbour it
  // nudged aside.
  applyServerValues(payload) {
    if (!payload) return

    const rows = [payload, ...(payload.changes || [])]
    rows.forEach((change) => {
      const row = this.rowFor(change.id)
      if (row && typeof change.precedence === "number") this.applyPrecedence(row, change.precedence)
    })
  }

  revertRow(row) {
    const input = row.querySelector("[data-ranked-queue-target='precedenceInput']")
    if (input) input.value = row.dataset.precedence
  }

  // Sort the spot list by precedence descending, ties oldest-first — the same
  // order `Session.ranked` produces, so the page agrees with the queue.
  sortSpotRows() {
    const rows = Array.from(this.spotListTarget.children)
    rows.sort((a, b) => {
      const delta = Number(b.dataset.precedence) - Number(a.dataset.precedence)
      if (delta !== 0) return delta
      return Number(a.dataset.sessionId) - Number(b.dataset.sessionId)
    })
    rows.forEach((row) => this.spotListTarget.appendChild(row))
  }

  // Moving between sections swaps the row's controls, because the two sections
  // offer different ones: a spot row drags and edits, a priority row does not.
  moveToSpot(row) {
    this.spotListTarget.appendChild(row)
    this.setRowMode(row, true)
    this.refreshCounts()
  }

  moveToPriority(row) {
    this.priorityListTarget.appendChild(row)
    this.setRowMode(row, false)
    this.refreshCounts()
  }

  // Rebuild a row's rank cell and its button for the section it now lives in.
  //
  // The two sections offer different controls, and a row that moves between them
  // has to gain or lose them: a spot row drags and edits its rank, a priority row
  // shows it as static text. Both cells are rendered on every row and one of them
  // is hidden, so this is a toggle rather than a re-render — a row that has just
  // been demoted is immediately draggable and editable, without a reload.
  setRowMode(row, spot) {
    const handle = row.querySelector("[data-ranked-queue-target='handle']")
    if (handle) handle.classList.toggle("hidden", !spot)
    row.classList.toggle("cursor-grab", spot)

    const input = row.querySelector("[data-ranked-queue-target='precedenceInput']")
    const readout = row.querySelector("[data-ranked-queue-target='precedenceReadout']")
    if (input) {
      input.classList.toggle("hidden", !spot)
      input.disabled = !spot
      input.value = row.dataset.precedence
    }
    if (readout) {
      readout.classList.toggle("hidden", spot)
      readout.textContent = row.dataset.precedence
    }

    // Both entries live in the row's overflow menu and one of them is hidden, the
    // same shape as the two rank cells above. Swapping visibility rather than
    // rewriting one button's action keeps the menu's markup static, so a row that
    // moves sections does not need its Stimulus actions re-registered.
    const promote = row.querySelector("[data-ranked-queue-target='promoteAction']")
    const demote = row.querySelector("[data-ranked-queue-target='demoteAction']")
    if (promote) promote.classList.toggle("hidden", !spot)
    if (demote) demote.classList.toggle("hidden", spot)
  }

  // The header badges count rows, so they have to be recounted whenever the lists
  // change — including when a Turbo Stream removes a trashed row out from under
  // the page.
  refreshCounts() {
    this.refreshEmptyStates()
    const pairs = [
      [this.priorityListTarget, this.hasPriorityCountTarget ? this.priorityCountTarget : null],
      [this.spotListTarget, this.hasSpotCountTarget ? this.spotCountTarget : null]
    ]
    pairs.forEach(([list, badge]) => {
      if (badge) badge.textContent = String(list.children.length)
    })
  }

  // The "nothing here" placeholders are server-rendered, so a section that has
  // just gained or lost its only row would otherwise show both a row and the
  // empty state.
  refreshEmptyStates() {
    const pairs = [
      [this.priorityListTarget, this.hasPriorityEmptyTarget ? this.priorityEmptyTarget : null],
      [this.spotListTarget, this.hasSpotEmptyTarget ? this.spotEmptyTarget : null]
    ]
    pairs.forEach(([list, placeholder]) => {
      const empty = list.children.length === 0
      list.classList.toggle("hidden", empty)
      if (placeholder) placeholder.classList.toggle("hidden", !empty)
    })
  }

  // ---- Requests -------------------------------------------------------------

  patch(url, body) {
    return fetch(url, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        "X-CSRF-Token": this.csrfToken
      },
      body: JSON.stringify(body)
    }).then(async (response) => {
      const payload = await response.json().catch(() => null)
      if (!response.ok) throw new Error(payload && payload.error ? payload.error : `Request failed (${response.status})`)
      return payload
    })
  }

  // A write that did not land must not leave the page claiming it did. Reloading
  // is the honest rollback: the server's order is the only one that matters, and
  // a failed reorder may have moved several rows.
  rollback(error, row) {
    if (row) this.revertRow(row)
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

  get csrfToken() {
    const meta = document.querySelector('meta[name="csrf-token"]')
    return meta ? meta.content : ""
  }
}
