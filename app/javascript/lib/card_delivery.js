// How an open dashboard judges a card delivery (`sessions/_card_delivery`).
//
// The server broadcasts every session change on one stream, to every open
// dashboard, and cannot know which of them is filtered to what. So it sends an
// envelope — the session's filterable facts and its card — and the page decides.
// The card grid (`session-grid`) and Your board (`board-v2`) place cards
// differently but must agree about which sessions belong, so the filter rules
// live here and both controllers use them.
//
// Both spread `cardFilterValues` into their Stimulus values, and the server
// renders those values with SessionsHelper#dashboard_card_filter_data.

// How long after someone on this page takes a card away that every delivery for
// it is refused, whatever it says.
const DEPARTURE_GRACE_MS = 5000

export const cardFilterValues = {
  // The statuses this page is showing. Empty means "every status".
  statusFilter: Array,
  // "spot", "priority", or "" for both.
  priorityClassFilter: String,
  // "on_board" (the default), "off_board", "backlogged", or "all".
  visibilityFilter: String,
  // "", "carplay_ok", "laptop_only", "untagged" or "not_laptop_only".
  carplayFitFilter: String,
  // A genesis key, or "".
  genesisFilter: String,
  // An agent root name, or "".
  agentRootFilter: String,
  // False under a text search, which only the server can evaluate for a
  // session this page has never rendered.
  liveInsert: Boolean
}

export function readCardDelivery(element) {
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
    backlogged: element.dataset.backlogged === "true",
    carplayFit: element.dataset.carplayFit,
    genesis: element.dataset.genesis || "",
    agentRoot: element.dataset.agentRoot || "",
    // Your board's category, or "" for Uncategorized.
    boardCategoryId: element.dataset.boardCategoryId || "",
    lastTouched: Number(element.dataset.lastTouched) || 0,
    // When the server read the row this was rendered from, in epoch ms.
    readAt: Number(element.dataset.readAt) || 0,
    // The Undo reply: the operator putting back a card this page took away.
    restore: element.dataset.restore === "true",
    // Null for a delivery that only says the session was looked at.
    card: source ? document.importNode(source, true) : null
  }
}

// The filters a live update can move a session across. A card already on the
// page matched the rest (search, genesis, agent root) when it was rendered, and
// none of those three change under it.
export function stillAdmitted(delivery, page) {
  if (page.statusFilterValue.length > 0 && !page.statusFilterValue.includes(delivery.status)) return false
  if (page.priorityClassFilterValue && page.priorityClassFilterValue !== delivery.schedulingClass) return false
  if (page.visibilityFilterValue === "on_board" && !delivery.onBoard) return false
  // "off_board" is snoozed and hidden; the backlog is its own bucket, as in
  // SessionVisibility's scopes.
  if (page.visibilityFilterValue === "off_board" && (delivery.onBoard || delivery.backlogged)) return false
  if (page.visibilityFilterValue === "backlogged" && !delivery.backlogged) return false
  return carplayFitAdmits(page.carplayFitFilterValue, delivery.carplayFit)
}

// Every filter, for a session this page has never rendered.
export function admitsUnseen(delivery, page) {
  if (!page.liveInsertValue) return false
  if (!stillAdmitted(delivery, page)) return false
  if (page.genesisFilterValue && page.genesisFilterValue !== delivery.genesis) return false
  if (page.agentRootFilterValue && page.agentRootFilterValue !== delivery.agentRoot) return false
  return true
}

// Mirrors SessionCarplayFit's `carplay_fit_filter` scope over the bucket the
// envelope carries (`carplay_ok`, `laptop_only` or `untagged`).
function carplayFitAdmits(filter, bucket) {
  switch (filter) {
    case "carplay_ok": return bucket === "carplay_ok"
    case "laptop_only": return bucket === "laptop_only"
    case "untagged": return bucket === "untagged"
    case "not_laptop_only": return bucket !== "laptop_only"
    default: return true
  }
}

// Session ids someone on this page took off it, and when.
//
// A page showing every status admits a trashed session, so without this the
// archive broadcast that follows a Trash click would put the card straight back,
// reading "Trashed". For a few seconds after the departure every delivery is
// refused, because one rendered before the archive committed can arrive after
// it; after that only an archived one is, so a session that comes back to life
// elsewhere may return.
export class Departures {
  constructor() {
    this.times = new Map()
    this.elements = new Map()
  }

  // `element` is what left, where the caller needs to tell it from a copy of it.
  note(id, element = null) {
    this.times.set(String(id), Date.now())
    this.elements.set(String(id), element)
  }

  forget(id) {
    this.times.delete(String(id))
    this.elements.delete(String(id))
  }

  // Whether `element` is another copy of something that has only just left.
  isCopy(id, element) {
    if (!this.has(id) || this.elements.get(String(id)) === element) return false
    return Date.now() - this.times.get(String(id)) < DEPARTURE_GRACE_MS
  }

  has(id) {
    return this.times.has(String(id))
  }

  refuses(delivery) {
    if (!this.has(delivery.id)) return false
    if (delivery.status === "archived") return true
    return Date.now() - this.times.get(delivery.id) < DEPARTURE_GRACE_MS
  }
}
