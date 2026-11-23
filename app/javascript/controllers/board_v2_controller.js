import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"
import { csrfHeaders } from "lib/csrf"
import { Departures, admitsUnseen, cardFilterValues, readCardDelivery, stillAdmitted } from "lib/card_delivery"
import { backfillLiveRegions } from "lib/live_region_backfill"
import { isPendingRemoval } from "lib/optimistic_actions"

// How long to gather layout signals before fetching the board, so a burst of
// category changes costs one fetch.
const REFRESH_DELAY_MS = 250
const REFRESH_TIMEOUT_MS = 10000
const REFRESH_RETRY_MS = 3000
const REFRESH_ATTEMPTS = 3
// How long to leave a card that is being worked in before looking again.
const CARD_IN_USE_RETRY_MS = 1000

// Connects to data-controller="board-v2"
//
// Your board: sessions grouped into categories the operator makes by hand.
// This controller owns three drags, one toggle, and keeping the board true to its
// sessions while it is open:
//
//   * a row dragged into another group — writes the session's category
//     (PATCH /sessions/:id/board_category). Within a group a drag does nothing:
//     the order there is most recently touched first, and the row settles back.
//     While a row is in hand the drop bar (`tray`) is shown, pinned to the
//     bottom of the screen with one target (`dropZone`) per group, so a
//     category three screens away is still one short drag away. Snoozed and
//     backlogged categories get a target too: a card dropped there leaves the
//     board with its category. The targets
//     are plain elements, not SortableJS lists: this controller follows the
//     pointer while a row is in hand, lights up the target under it, and on
//     release moves the row into that group's real list. (SortableJS's own
//     touch path never put a row into a list inside the fixed bar.)
//   * a category header dragged — writes the order of every category
//     (PATCH /board_categories/reorder).
//   * a category's chevron — collapses or expands it, and stores that on the
//     category so it survives a reload (PATCH /board_categories/:id).
//
// Each row is a Last Touched card with a drag handle beside it
// (sessions/_board_v2_row). Trash, Snooze and View are the card's own controls,
// exactly as on Last Touched. A row that leaves (Trash, Snooze) or arrives (Undo) is seen
// by each list's MutationObserver, which keeps the counts and the order true.
//
// Following sessions: every session change is broadcast to every dashboard as a
// card delivery (`sessions/_card_delivery`), judged here against this page's own
// filters by the rules in lib/card_delivery, which the card grid shares:
//
//   * no longer admitted            -> the whole row leaves, handle included
//   * admitted, its group is shown  -> the card is redrawn (or inserted), in its
//     own group, where last touched puts it
//   * admitted, its category is tucked away -> the row leaves, and the tucked
//     category's count includes it
//   * its category is one this page has never drawn -> the board is fetched again
//
// The categories themselves changing (made, renamed, reordered, snoozed, woken,
// deleted) arrives as a signal, and the board is fetched again and reconciled.
// While anything is being dragged, or a fetched copy of the board is on its way,
// deliveries wait and are applied after.
//
// Every Sortable forces the pointer-based fallback, for the reason the User
// view's does: native HTML5 drag and drop does not work on a phone.
export default class extends Controller {
  // `row` and `handle` are declared for the row partial, which names them; the
  // controller reads them through selectors.
  static targets = [
    "list", "categories", "category", "total", "error", "row", "handle", "tray", "dropZone",
    "delivery", "signal", "rowTemplate", "tucked", "noMatch", "truncated"
  ]
  static values = {
    ...cardFilterValues,
    // The most rows the board draws, least recently touched dropped first.
    limit: Number,
    assignUrlTemplate: String,
    reorderUrl: String,
    categoryUrlTemplate: String
  }

  initialize() {
    // Here, not in connect(): Stimulus reports the targets already in the markup
    // before it connects the controller.
    this.departures = new Departures()
    // Why deliveries are waiting ("drag", "fetch"), and the deliveries.
    this.holds = new Set()
    this.heldDeliveries = []
    // The newest facts delivered for each session, and when the card on screen was
    // read: the two can arrive out of order.
    this.facts = new Map()
    this.cardReadAt = new Map()
    // Drops this page has sent and not had answered: session id -> category id.
    this.pendingMoves = new Map()
    // Deliveries for sessions whose card on screen is being worked in.
    this.waiting = new Map()
    // Writes of the board's own layout not yet answered (a drop, a category order),
    // and a count of everything done to it by hand: a copy of the board fetched
    // across one of these may not have it.
    this.saves = 0
    this.handChanges = 0
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
        onChoose: () => this.pickUp(),
        onUnchoose: () => this.putDown(),
        onEnd: (event) => this.persistCategoryOrder(event)
      })
      this.categoriesTarget.sortableInstance = this.categorySortable
    }
  }

  disconnect() {
    if (this.categorySortable) this.categorySortable.destroy()
    this.showTray(false)
    clearTimeout(this.refreshTimer)
    clearTimeout(this.waitingTimer)
    this.waiting.clear()
    this.heldDeliveries = []
    this.holds.clear()
    this.element.removeAttribute("data-live-hold")
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
      // A finger drifts a few pixels while it holds; without this the hold
      // is cancelled and the touch becomes a scroll.
      touchStartThreshold: 5,
      handle: "[data-board-v2-target='handle']",
      forceFallback: true,
      fallbackClass: "board-v2-fallback",
      fallbackTolerance: 3,
      fallbackOnBody: true,
      onChoose: (event) => {
        this.pickUp()
        this.rememberGrab(event)
      },
      // Before onEnd when a drag happened, alone when the grip was only pressed.
      onUnchoose: () => this.putDown(),
      onStart: () => {
        this.dragging = true
        this.centreGhost()
        this.showTray(true)
      },
      onEnd: (event) => {
        this.dragging = false
        const drop = { zone: this.hoveredZone, overTray: this.overTray, cancelled: this.dragCancelled }
        this.showTray(false)
        this.persistMove(event, drop)
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

  // ---- The drop bar --------------------------------------------------------

  showTray(shown) {
    if (!this.hasTrayTarget) return
    this.trayTarget.classList.toggle("hidden", !shown)
    if (shown) {
      if (this.trackPointer) return
      this.overTray = false
      this.dragCancelled = false
      this.trackPointer = (event) => this.hover(event)
      this.cancelDrag = () => { this.dragCancelled = true }
      for (const type of ["pointermove", "mousemove", "touchmove"]) {
        document.addEventListener(type, this.trackPointer, { passive: true, capture: true })
      }
      // The system took the touch away (an edge swipe, an alert). SortableJS
      // still ends the drag as a drop; this one must not be saved.
      for (const type of ["pointercancel", "touchcancel"]) {
        document.addEventListener(type, this.cancelDrag, { capture: true })
      }
    } else if (this.trackPointer) {
      for (const type of ["pointermove", "mousemove", "touchmove"]) {
        document.removeEventListener(type, this.trackPointer, { capture: true })
      }
      for (const type of ["pointercancel", "touchcancel"]) {
        document.removeEventListener(type, this.cancelDrag, { capture: true })
      }
      this.trackPointer = null
      this.cancelDrag = null
      this.overTray = false
      this.highlight(null)
    }
  }

  // The target under the pointer, if any, lit up; remembered for the drop,
  // along with whether the pointer is over the bar at all.
  hover(event) {
    const point = event.touches ? event.touches[0] : event
    if (!point) return
    const hit = document.elementFromPoint(point.clientX, point.clientY)
    const zone = hit && hit.closest("[data-board-v2-drop-zone]")
    this.overTray = !!(hit && this.trayTarget.contains(hit))
    this.highlight(zone && this.element.contains(zone) ? zone : null)
  }

  // Where on the card the grip was pressed, for centreGhost.
  rememberGrab(event) {
    const original = event.originalEvent
    const point = original && (original.touches ? original.touches[0] : original)
    this.grab = point ? { y: point.clientY, top: event.item.getBoundingClientRect().top } : null
  }

  // SortableJS draws the card in hand at the card's own top and keeps that
  // offset from the pointer. The grip runs the card's height and the card in
  // hand is a small tab (.board-v2-fallback), so a grab halfway down a tall
  // card would leave the tab floating far above the finger. Move it so the
  // tab sits centred on the grab point. A shift of `top`, not an absolute
  // value: SortableJS positions the tab `fixed` in most browsers and
  // `absolute` on iOS, and the shift is right for both.
  centreGhost() {
    const ghost = Sortable.ghost
    if (!ghost || !this.grab) return
    const shift = this.grab.y - this.grab.top - ghost.offsetHeight / 2
    if (shift > 0) ghost.style.top = `${parseFloat(ghost.style.top || "0") + shift}px`
  }

  highlight(zone) {
    if (zone === this.hoveredZone) return
    this.hoveredZone = zone
    // Swapped in pairs rather than layered, so no two colours compete.
    const pairs = [
      ["border-dashed", "border-solid"],
      ["border-gray-300", "border-indigo-500"],
      ["bg-gray-50", "bg-indigo-50"],
      ["text-gray-700", "text-indigo-800"]
    ]
    this.dropZoneTargets.forEach((target) => {
      const on = target === zone
      for (const [off, lit] of pairs) {
        target.classList.toggle(off, !on)
        target.classList.toggle(lit, on)
      }
    })
  }

  // The row list of a group: a category's, or Uncategorized's for "".
  listFor(categoryId) {
    return this.listTargets.find((list) => (list.dataset.categoryId || "") === (categoryId || ""))
  }

  // ---- Moving a session between groups -------------------------------------

  persistMove(event, drop = {}) {
    const row = event.item
    const from = event.from
    let to = event.to
    // Released over the drop bar: into that group's own list, wherever
    // SortableJS had last put the row behind it. Released over the bar but on
    // no target, or a drag the system cancelled: nobody chose a group, so the
    // row goes back where it came from and nothing is saved — not into
    // whichever list it last passed on the way down.
    if (drop.zone && !drop.cancelled && drop.zone.hasAttribute("data-board-v2-tucked-zone")) {
      this.persistTuckedMove(row, drop.zone)
      return
    }
    const zoneList = drop.zone && this.listFor(drop.zone.dataset.categoryId)
    if (zoneList && !drop.cancelled) {
      zoneList.appendChild(row)
      to = zoneList
    } else if (drop.cancelled || drop.overTray) {
      from.appendChild(row)
      to = from
    }
    if (from === to) {
      // A drag inside one group: put the row back where the order says. The
      // counts too, since on its way the row passed through other lists.
      this.sortList(to)
      this.refreshCounts()
      return
    }

    this.sortList(to)
    this.refreshCounts()
    this.clearError()

    this.saveMove(row.dataset.sessionId, to.dataset.categoryId || "")
      .catch((error) => this.rollback(error))
  }

  // Until the server has answered, a delivery still carrying the old category
  // must not carry the card back to it.
  saveMove(sessionId, categoryId) {
    this.pendingMoves.set(sessionId, categoryId)
    const url = this.assignUrlTemplateValue.replace("__ID__", sessionId)
    return this.saving(this.request("PATCH", url, { board_category_id: categoryId || null }))
      .finally(() => {
        // Not if the card has been dropped somewhere else since.
        if (this.pendingMoves.get(sessionId) === categoryId) this.pendingMoves.delete(sessionId)
      })
  }

  // Dropped on a snoozed or backlogged category: the category is off the board,
  // so the card leaves it too, and the category's count in the strip at the
  // foot of the board goes up by one. The bar was drawn when the page loaded; a
  // snooze that has run out since puts the category back on the board, so that
  // drop is saved and then the board is reloaded to show where the card went.
  persistTuckedMove(row, zone) {
    const categoryId = zone.dataset.categoryId
    const until = zone.dataset.snoozedUntil
    const woken = !!until && Date.parse(until) <= Date.now()
    row.remove()
    this.clearError()
    this.countTucked(row.dataset.sessionId, categoryId)
    this.refreshCounts()

    this.saveMove(row.dataset.sessionId, categoryId)
      .then(() => { if (woken) window.location.reload() })
      .catch((error) => this.rollback(error))
  }

  // ---- Following sessions --------------------------------------------------

  deliveryTargetConnected(element) {
    const delivery = readCardDelivery(element)
    element.remove()
    if (!delivery) return

    if (this.holds.size > 0) this.heldDeliveries.push(delivery)
    else this.applyDelivery(delivery)
  }

  // Deliveries come from several processes and can overtake each other. One that
  // read its session earlier than the facts this page already has is out of date,
  // except that its card may still be the newest one seen: a delivery with no card
  // is quick to render and can arrive ahead of one that has it. The Undo reply is
  // an instruction as well as news, so it is always acted on, with the newer facts.
  applyDelivery(delivery) {
    const { id } = delivery
    const facts = this.facts.get(id)
    if (!facts || delivery.readAt >= facts.readAt) {
      this.facts.set(id, { ...delivery, card: null, restore: false })
      return this.settle({ ...delivery, cardReadAt: delivery.readAt })
    }
    if (!delivery.card || (!delivery.restore && delivery.readAt < (this.cardReadAt.get(id) || 0))) return

    this.settle({ ...facts, card: delivery.card, restore: delivery.restore, cardReadAt: delivery.readAt })
  }

  // Put one session where its facts say it belongs.
  settle(delivery) {
    const { id } = delivery
    const waited = this.waiting.get(id)
    this.waiting.delete(id)
    if (waited?.card && !delivery.card) {
      delivery = { ...delivery, card: waited.card, cardReadAt: waited.cardReadAt }
    }

    const row = this.rowFor(id)
    // A title being typed, or an open menu, is not taken away from the person
    // using it: redrawn, moved or removed when they are done.
    if (row && this.cardInUse(row)) return this.wait(delivery)

    // A session this page is showing, is counting, or has just taken away already
    // matched the filters only the server can evaluate.
    const known = row || this.tuckedTargets.some((target) => this.tuckedIds(target).includes(id)) ||
      (delivery.restore && this.departures.has(id))
    const admitted = known ? stillAdmitted(delivery, this) : admitsUnseen(delivery, this)
    if (!admitted) {
      if (row) row.remove()
      this.countTucked(id, null)
      return this.refreshCounts()
    }

    const categoryId = this.pendingMoves.has(id) ? this.pendingMoves.get(id) : delivery.boardCategoryId
    const list = this.listFor(categoryId)
    if (list) {
      this.countTucked(id, null)
      if (row) this.redraw(row, list, delivery)
      else this.insert(list, delivery)
      return this.refreshCounts()
    }

    // Gone from the board either way; with its category, if that is tucked away.
    const tucked = this.tuckedTargets.find((target) => target.dataset.boardV2TuckedCategory === categoryId)
    if (!tucked || this.snoozeElapsed(tucked)) return this.refreshSoon()
    if (row) row.remove()
    this.departures.forget(id)
    this.countTucked(id, categoryId)
    this.refreshCounts()
  }

  redraw(row, list, delivery) {
    if (delivery.card) {
      row.querySelector(":scope > [data-board-v2-card-slot] > turbo-frame")?.replaceWith(delivery.card)
      this.cardReadAt.set(delivery.id, delivery.cardReadAt)
    }
    row.dataset.lastTouched = String(delivery.lastTouched)
    this.place(row, list)
  }

  wait(delivery) {
    this.waiting.set(delivery.id, delivery)
    clearTimeout(this.waitingTimer)
    this.waitingTimer = setTimeout(() => this.settleWaiting(), CARD_IN_USE_RETRY_MS)
  }

  settleWaiting() {
    if (this.holds.size > 0) {
      this.waitingTimer = setTimeout(() => this.settleWaiting(), CARD_IN_USE_RETRY_MS)
      return
    }
    Array.from(this.waiting.values()).forEach((delivery) => this.settle(delivery))
  }

  cardInUse(row) {
    const active = document.activeElement
    if (row.contains(active) && active.matches("input, textarea, select")) return true
    return row.querySelector("[aria-expanded='true']") !== null
  }

  insert(list, delivery) {
    if (!delivery.card || !this.hasRowTemplateTarget) return
    if (!delivery.restore && this.departures.refuses(delivery)) return
    // A card this page took away at the click (Trash, Snooze), whose request the
    // server has not answered yet.
    if (isPendingRemoval("session", delivery.id)) return

    const row = document.importNode(this.rowTemplateTarget.content.firstElementChild, true)
    row.id = `board_v2_row_${delivery.id}`
    row.dataset.sessionId = delivery.id
    row.dataset.lastTouched = String(delivery.lastTouched)
    if (!this.makeRoomFor(row)) return

    row.querySelector("[data-board-v2-card-slot]").appendChild(delivery.card)
    this.cardReadAt.set(delivery.id, delivery.cardReadAt)
    this.departures.forget(delivery.id)
    this.place(row, list)
  }

  // The server draws the `limit` most recently touched rows and says so when that
  // is not all of them; an arrival on a full board pushes out the least recently
  // touched, or is the one left out.
  makeRoomFor(row) {
    const rows = this.listTargets.flatMap((list) => Array.from(list.children))
    if (!this.limitValue || rows.length < this.limitValue) return true

    if (this.hasTruncatedTarget) this.truncatedTarget.hidden = false
    const last = rows.reduce((least, other) => (this.compareRows(other, least) > 0 ? other : least))
    if (this.compareRows(row, last) > 0) return false
    last.remove()
    return true
  }

  // Into the list at the position last touched gives it, without touching a row
  // that is already there.
  place(row, list) {
    const follower = Array.from(list.children).find((other) => other !== row && this.compareRows(row, other) < 0) || null
    if (row.parentElement === list && row.nextElementSibling === follower) return
    list.insertBefore(row, follower)
  }

  rowFor(sessionId) {
    return this.element.querySelector(`#board_v2_row_${CSS.escape(String(sessionId))}`)
  }

  // Cards someone on this page took off it (Trash, Snooze, Hide): the removals
  // marked pending at the click. A row a delivery or a fetched copy of the board
  // took away is free to come back with the next one.
  noteDepartures(records) {
    records.forEach((record) => {
      record.removedNodes.forEach((node) => {
        const id = node.dataset?.sessionId
        if (id && !node.isConnected && isPendingRemoval("session", id)) this.departures.note(id, node)
      })
      record.addedNodes.forEach((node) => {
        const id = node.dataset?.sessionId
        if (!id || !node.isConnected) return
        // The same row: a refused Trash put back. Any other is from a copy of the
        // board fetched before the server had heard, unless the departure is old.
        if (this.departures.isCopy(id, node)) node.remove()
        else this.departures.forget(id)
      })
    })
  }

  // ---- Tucked-away categories ----------------------------------------------

  tuckedIds(target) {
    return (target.dataset.sessionIds || "").split(" ").filter(Boolean)
  }

  snoozeElapsed(target) {
    const until = target.dataset.snoozedUntil
    return !!until && Date.parse(until) <= Date.now()
  }

  // Count a session in one tucked-away category and no other; null for none.
  countTucked(sessionId, categoryId) {
    this.tuckedTargets.forEach((target) => {
      const before = this.tuckedIds(target)
      const ids = before.filter((id) => id !== sessionId)
      if (target.dataset.boardV2TuckedCategory === categoryId) ids.push(sessionId)
      if (ids.length === before.length) return

      ids.sort((a, b) => Number(a) - Number(b))
      target.dataset.sessionIds = ids.join(" ")
      const count = target.querySelector("[data-board-v2-tucked-count]")
      if (count) count.textContent = `${ids.length} ${ids.length === 1 ? "session" : "sessions"}`
    })
  }

  // ---- Waiting out a drag or a fetch ---------------------------------------

  hold(reason) {
    this.holds.add(reason)
  }

  release(reason) {
    this.holds.delete(reason)
    if (this.holds.size > 0) return

    const held = this.heldDeliveries
    this.heldDeliveries = []
    held.forEach((delivery) => this.applyDelivery(delivery))
  }

  pickUp() {
    this.hold("drag")
    this.handChanged()
  }

  // Until the server has a drop, its copy of the board does not.
  saving(request) {
    this.saves += 1
    this.handChanged()
    return request.finally(() => {
      this.saves -= 1
      this.handChanged()
    })
  }

  handChanged() {
    this.handChanges += 1
    this.element.toggleAttribute("data-live-hold", this.holds.has("drag") || this.saves > 0)
    if (this.refreshAfterHand && !this.element.hasAttribute("data-live-hold")) {
      this.refreshAfterHand = false
      this.refreshSoon()
    }
  }

  // SortableJS reports the drop (`onEnd`) right after this, and the drop decides
  // where the card is; what waited is applied on top of that.
  putDown() {
    queueMicrotask(() => {
      this.release("drag")
      this.handChanged()
    })
  }

  // ---- The board, fetched again --------------------------------------------

  signalTargetConnected(element) {
    element.remove()
    this.refreshSoon()
  }

  refreshSoon(delay = REFRESH_DELAY_MS) {
    clearTimeout(this.refreshTimer)
    this.refreshTimer = setTimeout(() => this.refresh(), delay)
  }

  // Whether a copy of the board asked for then could be missing something done
  // here: since, or still being done.
  changedByHandSince(count) {
    return count !== this.handChanges || this.element.hasAttribute("data-live-hold")
  }

  // Once nothing is in hand or on its way to the server.
  refreshAfterChanges() {
    if (this.element.hasAttribute("data-live-hold")) this.refreshAfterHand = true
    else this.refreshSoon()
  }

  // The regions are reconciled without redrawing the cards: this page's socket is
  // up, so they are current, and only what belongs where has changed.
  async refresh() {
    const frame = this.element.closest("turbo-frame[src]")
    if (!frame) return
    if (this.refreshing) {
      this.refreshAgain = true
      return
    }

    this.refreshing = true
    this.hold("fetch")
    const handChanges = this.handChanges
    try {
      const response = await fetch(frame.src, {
        headers: { Accept: "text/html" },
        credentials: "same-origin",
        cache: "no-store",
        signal: AbortSignal.timeout(REFRESH_TIMEOUT_MS)
      })
      if (!response.ok || response.redirected) throw new Error(`Request failed (${response.status})`)
      const fresh = new DOMParser().parseFromString(await response.text(), "text/html")
      if (this.changedByHandSince(handChanges)) this.refreshAfterChanges()
      else backfillLiveRegions(fresh, { within: this.element, redraw: false })
      this.failedRefreshes = 0
    } catch (error) {
      console.warn("Your board could not be refreshed:", error)
      this.failedRefreshes = (this.failedRefreshes || 0) + 1
      // After that, the next signal or a reload brings it up to date.
      if (this.failedRefreshes < REFRESH_ATTEMPTS) this.refreshSoon(REFRESH_RETRY_MS * this.failedRefreshes)
      else this.failedRefreshes = 0
    } finally {
      this.refreshing = false
      this.release("fetch")
      this.refreshCounts()
      if (this.refreshAgain) {
        this.refreshAgain = false
        this.refreshSoon()
      }
    }
  }

  // The reconnect backfill is about to fetch the board, and has reconciled it.
  // Deliveries that arrive in between are newer than its copy.
  backfilling() {
    this.hold("backfill")
    this.handChangesAtBackfill = this.handChanges
  }

  backfilled() {
    if (this.changedByHandSince(this.handChangesAtBackfill)) this.refreshAfterChanges()
    this.release("backfill")
    this.refreshCounts()
  }

  // ---- Reordering categories -----------------------------------------------

  persistCategoryOrder(event) {
    if (event.oldIndex === event.newIndex) return

    const ids = this.categoryTargets.map((category) => category.dataset.categoryId)
    this.clearError()
    this.saving(this.request("PATCH", this.reorderUrlValue, { category_ids: ids }))
      .catch((error) => this.rollback(error))
  }

  // ---- Collapse ------------------------------------------------------------

  toggle(event) {
    event.preventDefault()
    const button = event.currentTarget
    const category = button.closest("[data-board-v2-target='category']")
    // One write in flight at a time, so a double-click cannot land two PATCHes
    // out of order and leave the saved state disagreeing with the screen.
    if (!category || button.disabled) return

    const body = category.querySelector("[data-board-v2-body]")
    const chevron = category.querySelector("[data-board-v2-chevron]")
    const collapsed = !body.classList.contains("hidden")
    body.classList.toggle("hidden", collapsed)
    if (chevron) chevron.classList.toggle("-rotate-90", collapsed)
    button.setAttribute("aria-expanded", String(!collapsed))

    const url = this.categoryUrlTemplateValue.replace("__ID__", category.dataset.categoryId)
    button.disabled = true
    this.request("PATCH", url, { collapsed })
      .catch((error) => this.rollback(error))
      .finally(() => { button.disabled = false })
  }

  // ---- Order and counts ----------------------------------------------------

  // Most recently touched first, newest id breaking ties — the server's
  // LAST_TOUCHED_ORDER, id desc.
  sortList(list) {
    this.reconciling = true
    // A list already in order is not touched: moving a row disconnects and
    // reconnects everything in its card.
    let slot = list.firstElementChild
    for (const row of Array.from(list.children).sort((a, b) => this.compareRows(a, b))) {
      if (row === slot) slot = slot.nextElementSibling
      else list.insertBefore(row, slot)
    }
    queueMicrotask(() => { this.reconciling = false })
  }

  compareRows(a, b) {
    const delta = Number(b.dataset.lastTouched) - Number(a.dataset.lastTouched)
    if (delta !== 0) return delta
    return Number(b.dataset.sessionId) - Number(a.dataset.sessionId)
  }

  reconcile(list, records) {
    this.noteDepartures(records)
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

    const tucked = this.tuckedTargets.some((target) => this.tuckedIds(target).length > 0)
    this.noMatchTargets.forEach((line) => {
      line.hidden = total > 0 || (line.dataset.boardV2NoMatch === "tucked") !== tucked
    })
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
