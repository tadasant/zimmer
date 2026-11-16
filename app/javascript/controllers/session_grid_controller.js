import { Controller } from "@hotwired/stimulus"
import { isPendingRemoval } from "lib/optimistic_actions"

// The dashboard's card grid (the Last Touched and Created views), kept true to
// the filters it was rendered with while sessions change underneath it.
//
// The server broadcasts every card update on one stream, to every open
// dashboard, and cannot know which of them is filtered to what. So a card comes
// as an envelope — the session's filterable facts plus the card inside an inert
// <template> (`_card_delivery`) — and this controller judges it:
//
//   * on the page and still admitted  -> replace the card in place
//   * on the page and no longer admitted -> take it away (a session that left
//     `needs_input` leaves a needs-input board; a trashed one leaves a board of
//     live work but stays, reading "Trashed", on one showing the trash)
//   * not on the page, admitted, and this page may insert -> insert it where the
//     server's sort would have put it
//   * anything else -> ignore it
//
// The envelope is consumed and removed either way, so nothing accumulates.
//
// The "N sessions" badge and the empty state are kept in step by watching the
// grid itself rather than every path that changes it, so a card taken away by
// Trash, a snooze, a delivery or a reconnect backfill all move the count.
// How long after someone on this page takes a card away that every delivery for
// it is refused, whatever it says.
const DEPARTURE_GRACE_MS = 5000

export default class extends Controller {
  static targets = ["delivery", "grid", "card", "count", "section", "empty"]
  static values = {
    // The statuses this page is showing. Empty means "every status".
    statusFilter: Array,
    // "spot", "priority", or "" for both.
    priorityClassFilter: String,
    // "on_board" (the default), "off_board", or "all".
    visibilityFilter: String,
    // "", "carplay_ok", "laptop_only", "untagged" or "not_laptop_only".
    carplayFitFilter: String,
    // A genesis key, or "".
    genesisFilter: String,
    // An agent root name, or "".
    agentRootFilter: String,
    // False under a text search, which only the server can evaluate for a
    // session this page has never rendered.
    liveInsert: Boolean,
    // The card data attribute the server sorted on, descending.
    sortKey: String,
    page: Number,
    perPage: Number
  }

  connect() {
    // Cards this controller pushed off the end of a full page to make room for an
    // arrival. They still match — they are on the next page now — so the count
    // must not drop for them.
    this.overflowed = new WeakSet()
    // Cards this controller itself took away or swapped out. Every OTHER removal
    // — the operator's Trash, a snooze, the archive response's stream — is a
    // departure this page asked for, recorded in `departed`.
    this.ownRemovals = new WeakSet()
    // Session ids someone on this page took off the grid, and when. A page
    // showing every status admits a trashed session, so without this the archive
    // broadcast that follows a Trash click would put the card straight back,
    // reading "Trashed". For a few seconds after the departure every delivery is
    // refused, because one rendered before the archive committed can arrive after
    // it; after that only an archived one is, so a session that comes back to
    // life elsewhere may return.
    this.departed = new Map()

    if (this.hasGridTarget) {
      this.gridObserver = new MutationObserver((mutations) => this.gridChanged(mutations))
      this.gridObserver.observe(this.gridTarget, { childList: true })
    }
  }

  disconnect() {
    if (this.gridObserver) this.gridObserver.disconnect()
  }

  // ---- Deliveries -----------------------------------------------------------

  deliveryTargetConnected(element) {
    const envelope = this.readEnvelope(element)
    element.remove()
    if (!envelope || !this.hasGridTarget) return

    this.applyDelivery(envelope)
  }

  readEnvelope(element) {
    const id = element.dataset.sessionId
    if (!id) return null

    const template = element.querySelector("template")
    const source = template ? template.content.firstElementChild : null

    return {
      id: id,
      status: element.dataset.status,
      schedulingClass: element.dataset.schedulingClass,
      // The string "true"/"false" the server rendered.
      onBoard: element.dataset.onBoard !== "false",
      carplayFit: element.dataset.carplayFit,
      genesis: element.dataset.genesis || "",
      agentRoot: element.dataset.agentRoot || "",
      // The Undo reply: the operator putting back a card this page took away.
      restore: element.dataset.restore === "true",
      card: source ? document.importNode(source, true) : null
    }
  }

  applyDelivery(envelope) {
    const existing = this.cardFor(envelope.id)

    if (existing) {
      if (!this.stillAdmitted(envelope)) {
        this.ownRemovals.add(existing)
        existing.remove()
      } else if (envelope.card) {
        this.ownRemovals.add(existing)
        existing.replaceWith(envelope.card)
      }
      return
    }

    if (!this.mayInsert(envelope)) return
    if (!envelope.restore && this.refusedAsDeparted(envelope)) return
    // A card this page took away at the click (Trash, Snooze, Hide), whose
    // request the server has not answered yet: a broadcast queued before it
    // committed must not put it back.
    if (isPendingRemoval("session", envelope.id)) return
    this.insertCard(envelope.card)
  }

  // The filters a live update can move a session across. A card already on the
  // page matched the rest (search, genesis, agent root) when it was rendered,
  // and none of those three change under it.
  stillAdmitted(envelope) {
    if (this.statusFilterValue.length > 0 && !this.statusFilterValue.includes(envelope.status)) {
      return false
    }
    if (this.priorityClassFilterValue && this.priorityClassFilterValue !== envelope.schedulingClass) {
      return false
    }
    if (this.visibilityFilterValue === "on_board" && !envelope.onBoard) return false
    if (this.visibilityFilterValue === "off_board" && envelope.onBoard) return false
    if (!this.carplayFitAdmits(envelope.carplayFit)) return false
    return true
  }

  // Every filter, for a session this page has never rendered. Only the first
  // page inserts: a later page cannot tell an arrival that belongs on it from
  // one that belongs on an earlier page.
  mayInsert(envelope) {
    if (!envelope.card || !this.liveInsertValue) return false
    if (this.pageValue > 1 && !envelope.restore) return false
    if (!this.stillAdmitted(envelope)) return false
    if (this.genesisFilterValue && this.genesisFilterValue !== envelope.genesis) return false
    if (this.agentRootFilterValue && this.agentRootFilterValue !== envelope.agentRoot) return false
    return true
  }

  refusedAsDeparted(envelope) {
    if (!this.departed.has(envelope.id)) return false
    if (envelope.status === "archived") return true
    return Date.now() - this.departed.get(envelope.id) < DEPARTURE_GRACE_MS
  }

  // Mirrors SessionCarplayFit's `carplay_fit_filter` scope over the bucket the
  // envelope carries (`carplay_ok`, `laptop_only` or `untagged`).
  carplayFitAdmits(bucket) {
    switch (this.carplayFitFilterValue) {
      case "carplay_ok": return bucket === "carplay_ok"
      case "laptop_only": return bucket === "laptop_only"
      case "untagged": return bucket === "untagged"
      case "not_laptop_only": return bucket !== "laptop_only"
      default: return true
    }
  }

  // Where the server's ORDER BY would put it: the sort key descending, ties to
  // the newer id. A card that would sort after the last one on a full page
  // belongs on a later page, so it is not inserted here; one that lands inside a
  // full page pushes the last card on to the next.
  insertCard(card) {
    const grid = this.gridTarget
    const cards = this.cardsIn(grid)
    const follower = cards.find((other) => this.sortsBefore(card, other))

    if (!follower && this.hasPerPageValue && cards.length >= this.perPageValue) return

    grid.insertBefore(card, follower || null)

    if (this.hasPerPageValue && cards.length + 1 > this.perPageValue) {
      const last = this.cardsIn(grid).pop()
      if (last && last !== card) {
        this.overflowed.add(last)
        this.ownRemovals.add(last)
        last.remove()
      }
    }
  }

  sortsBefore(card, other) {
    const key = this.sortKeyValue || "lastTouchedAt"
    const delta = Number(card.dataset[key]) - Number(other.dataset[key])
    if (delta !== 0) return delta > 0
    return Number(card.dataset.sessionId) > Number(other.dataset.sessionId)
  }

  // ---- Count and empty state ------------------------------------------------

  gridChanged(mutations) {
    let delta = 0
    mutations.forEach((mutation) => {
      // Removals first: a replace is one record carrying both, and the card it
      // adds is the one that should count as present.
      mutation.removedNodes.forEach((node) => {
        if (!this.isCard(node)) return
        if (this.ownRemovals.has(node)) {
          this.ownRemovals.delete(node)
        } else {
          this.departed.set(node.dataset.sessionId, Date.now())
        }
        if (this.overflowed.has(node)) {
          this.overflowed.delete(node)
          return
        }
        delta -= 1
      })
      mutation.addedNodes.forEach((node) => {
        if (!this.isCard(node)) return
        this.departed.delete(node.dataset.sessionId)
        delta += 1
      })
    })
    if (delta !== 0) this.adjustCount(delta)
    this.refreshEmptyState()
  }

  adjustCount(delta) {
    if (!this.hasCountTarget) return

    const badge = this.countTarget
    const next = Math.max(0, (Number(badge.dataset.count) || 0) + delta)
    badge.dataset.count = String(next)
    badge.textContent = String(next)
    badge.title = `${next} ${next === 1 ? "session" : "sessions"}`
  }

  refreshEmptyState() {
    const empty = this.cardsIn(this.gridTarget).length === 0
    if (this.hasSectionTarget) this.sectionTarget.hidden = empty
    if (this.hasEmptyTarget) this.emptyTarget.hidden = !empty
  }

  // ---- DOM plumbing ---------------------------------------------------------

  // Queried rather than read off `cardTargets`: a card this controller has just
  // inserted is not registered as a target until the next microtask.
  cardFor(sessionId) {
    if (!this.hasGridTarget) return null
    return this.gridTarget.querySelector(
      `:scope > turbo-frame[data-session-id='${CSS.escape(String(sessionId))}']`
    )
  }

  cardsIn(grid) {
    return Array.from(grid.children).filter((node) => this.isCard(node))
  }

  isCard(node) {
    return node.nodeType === Node.ELEMENT_NODE && node.tagName === "TURBO-FRAME" && node.dataset.sessionId
  }
}
