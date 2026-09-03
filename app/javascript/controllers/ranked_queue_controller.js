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
//
// The fourth thing it does is not an interaction at all: it decides what arrives
// over the ranked stream. The server broadcasts one message to every open queue
// and cannot know which of them is filtered to what, so a membership change comes
// as an envelope — the session's filterable facts plus its row inside an inert
// <template> — and this controller judges it against the filters the page was
// rendered with. See `deliveryTargetConnected`.
export default class extends Controller {
  static targets = [
    "priorityList", "spotList", "priorityEmpty", "spotEmpty", "row",
    "precedenceInput", "precedenceReadout", "error",
    "priorityCount", "spotCount", "promoteAction", "demoteAction", "delivery"
  ]
  static values = {
    slotGap: Number,
    // A cap, not a page: the server renders at most this many rows per section
    // and says so, and a live insert must not quietly exceed it.
    sectionLimit: Number,
    // The statuses this page is showing. Empty means "every status".
    statusFilter: Array,
    // "spot", "priority", or "" for both.
    priorityClassFilter: String,
    // Which board this is: "on_board" (the default, which leaves snoozed and
    // hidden rows out), "off_board", or "all". Presentation only — it decides
    // what is drawn and nothing about what runs.
    visibilityFilter: String,
    // False when a search, an agent root or a genesis is narrowing this page.
    // Those three cannot be evaluated client-side for a session the page has
    // never rendered, so it declines to insert rather than guessing.
    liveInsert: Boolean
  }

  connect() {
    // Deliveries that arrive while a row is in hand. Inserting or removing a
    // sibling mid-drag is exactly the disruption the narrow broadcast existed to
    // avoid, so they wait for the drop.
    this.heldDeliveries = []
    this.dragging = false

    this.sortable = Sortable.create(this.spotListTarget, {
      animation: 150,
      // A long press rather than an immediate grab on touch, so the page still
      // scrolls on a phone.
      delay: 200,
      delayOnTouchOnly: true,
      handle: "[data-ranked-queue-target='handle']",
      onStart: () => { this.dragging = true },
      onEnd: (event) => {
        this.dragging = false
        this.persistDrop(event)
        this.flushDeliveries()
      }
    })

    // The section headers and the "nothing here" placeholders are server-rendered
    // from the row count, so they go stale the moment a row arrives or leaves.
    // Watch the lists themselves rather than every path that can change them, so
    // the counts stay true whoever moved a row — a membership delivery, a
    // promote, a demote, or a drag.
    this.listObserver = new MutationObserver(() => this.refreshCounts())
    ;[this.priorityListTarget, this.spotListTarget].forEach((list) => {
      this.listObserver.observe(list, { childList: true })
    })
  }

  disconnect() {
    if (this.sortable) this.sortable.destroy()
    if (this.listObserver) this.listObserver.disconnect()
    this.heldDeliveries = []
  }

  // ---- Membership deliveries ------------------------------------------------

  // A session was created, changed status, or changed scheduling class, and the
  // server has offered this page the news. What to do with it is entirely a
  // question about THIS page's filters:
  //
  //   * a status the filter excludes  -> the row leaves (this is how a trashed
  //     session disappears from a queue of live work, and how it STAYS, reading
  //     "Trashed", on a page whose operator ticked "Archived" to see the trash)
  //   * a scheduling class that no longer matches the section it is in -> move it
  //   * admitted and not on the page yet -> insert it, in precedence order
  //   * anything else -> ignore it
  //
  // The envelope is consumed and removed either way, so nothing accumulates.
  deliveryTargetConnected(element) {
    const envelope = this.readEnvelope(element)
    element.remove()
    if (!envelope) return

    if (this.dragging) {
      this.heldDeliveries.push(envelope)
      return
    }
    this.applyDelivery(envelope)
  }

  readEnvelope(element) {
    const id = element.dataset.sessionId
    if (!id) return null

    // The row lives in a <template>: inert, and its ids are not in the document,
    // so an envelope for a row the page rejects never leaves a duplicate behind.
    const template = element.querySelector("template")
    const source = template ? template.content.firstElementChild : null

    return {
      id: id,
      status: element.dataset.status,
      schedulingClass: element.dataset.schedulingClass,
      precedence: element.dataset.precedence,
      // The string "true"/"false" the server rendered; compared as such below.
      onBoard: element.dataset.onBoard !== "false",
      row: source ? document.importNode(source, true) : null
    }
  }

  flushDeliveries() {
    const held = this.heldDeliveries
    this.heldDeliveries = []
    held.forEach((envelope) => this.applyDelivery(envelope))
  }

  applyDelivery(envelope) {
    const existing = this.rowFor(envelope.id)
    const admitted = this.admits(envelope)

    if (existing) {
      if (!admitted) {
        this.evictRow(existing)
      } else {
        this.reseatRow(existing, envelope)
      }
      return
    }

    if (!admitted || !this.liveInsertValue || !envelope.row) return
    this.insertRow(envelope)
  }

  // The three filter dimensions a page can evaluate for a session it has never
  // rendered. The other three — search, agent root, genesis — are the server's
  // to judge, which is why `liveInsert` turns inserts off when one is in force.
  // Removal stays sound under all six: a row on screen already matched them, and
  // none of status, class or board visibility can alter that.
  admits(envelope) {
    if (this.hasStatusFilterValue && this.statusFilterValue.length > 0 &&
        !this.statusFilterValue.includes(envelope.status)) {
      return false
    }
    if (this.priorityClassFilterValue && this.priorityClassFilterValue !== envelope.schedulingClass) {
      return false
    }
    // Board visibility. Without this a session the operator snoozed would be
    // pushed back onto their queue by its next status change — the one way a
    // presentation-only axis could look like it was not working.
    if (this.visibilityFilterValue === "on_board" && !envelope.onBoard) return false
    if (this.visibilityFilterValue === "off_board" && envelope.onBoard) return false
    return true
  }

  evictRow(row) {
    if (this.inUse(row)) return
    row.remove()
    this.refreshCounts()
  }

  reseatRow(row, envelope) {
    const spot = envelope.schedulingClass === "spot"
    const list = spot ? this.spotListTarget : this.priorityListTarget
    // Already where it belongs. A status change does not re-sort the queue, so
    // there is nothing else to do to a row that is seated correctly.
    if (row.parentElement === list) return
    if (this.inUse(row)) return

    row.dataset.precedence = envelope.precedence
    this.setRowMode(row, spot)
    this.insertInOrder(list, row)
    this.refreshCounts()
  }

  insertRow(envelope) {
    const spot = envelope.schedulingClass === "spot"
    const list = spot ? this.spotListTarget : this.priorityListTarget
    // The server truncates at the same number and says it has. Growing past it
    // live would make the "showing the first N" note a lie.
    if (this.hasSectionLimitValue && list.children.length >= this.sectionLimitValue) return

    this.insertInOrder(list, envelope.row)
    this.refreshCounts()
  }

  // A row someone is TYPING IN is never moved or taken away — the same bargain the
  // reconnect backfill strikes (see live_region_backfill.js). Losing an update is
  // recoverable; losing a half-typed rank is not.
  //
  // "Typing in" is narrower than "holds focus", and the difference is not
  // academic: the row's own ⋮ menu is inside the row, so a click on its Trash
  // entry leaves focus on a link in the row that click just archived. The broad
  // rule read that as an edit in progress and refused to remove the row — the
  // exact staleness this whole change exists to fix, reintroduced by its own
  // safety net. Only a focused text field counts.
  inUse(row) {
    const fields = Array.from(row.querySelectorAll("input, textarea"))
    if (fields.includes(document.activeElement)) return true

    return fields.some((field) => {
      return String(field.value).trim() !== "" && field.value !== field.defaultValue
    })
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

  // Queried rather than read off `rowTargets`, because a row this controller has
  // just inserted is not registered as a target yet — Stimulus notices it on the
  // next microtask, and a delivery acts now.
  rowFor(sessionId) {
    return this.element.querySelector(
      `[data-ranked-queue-target='row'][data-session-id='${CSS.escape(String(sessionId))}']`
    )
  }

  // Put a row where `Session.ranked` would put it: precedence descending, ties
  // broken oldest-first. Ids are monotonic, so id ascending is the same order as
  // created_at ascending — the same comparator `sortSpotRows` already uses.
  insertInOrder(list, row) {
    const follower = Array.from(list.children).find((sibling) => {
      if (sibling === row) return false
      const delta = Number(row.dataset.precedence) - Number(sibling.dataset.precedence)
      if (delta !== 0) return delta > 0
      return Number(row.dataset.sessionId) < Number(sibling.dataset.sessionId)
    })
    list.insertBefore(row, follower || null)
  }

  // Both rank cells are rendered on every row and one of them is hidden, so both
  // are written: whichever is showing now, and whichever a later promote or
  // demote reveals. Writing only the visible one would leave a demoted row at the
  // top of the queue still displaying the rank it carried while it was priority.
  applyPrecedence(row, value) {
    row.dataset.precedence = String(value)
    const input = row.querySelector("[data-ranked-queue-target='precedenceInput']")
    if (input) {
      input.value = String(value)
      // The committed value becomes the field's baseline, so "is someone
      // mid-edit here" stays a question about what is typed rather than about
      // what was typed an hour ago. Both `inUse` above and the reconnect
      // backfill's `isDirty` read `defaultValue`, and a row that never reset it
      // would be pinned as in-use for the rest of the page's life — never
      // reseated, never removed.
      input.defaultValue = String(value)
    }
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
      input.defaultValue = row.dataset.precedence
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
  // change — including when a membership delivery adds or takes away a row out
  // from under the page.
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
