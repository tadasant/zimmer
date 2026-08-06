// Draft storage for un-submitted text.
//
// A phone can take the page away without warning. iOS discards a backgrounded
// standalone PWA's web view under memory pressure, and reopening it performs a
// fresh navigation — and Zimmer reloads the page itself when a session screen
// comes back visible with a dead cable (see
// stream_visibility_recovery_controller.js). Either way the DOM is rebuilt from
// the server, and anything typed but not submitted is gone unless it was
// written down somewhere first.
//
// `localStorage`, not `sessionStorage`: a cold relaunch of a discarded PWA gets
// a brand-new browsing session, so sessionStorage is already empty by the time
// anything reads it. localStorage is what actually survives the case this
// exists for.
//
// Every entry is stamped with a write time and expires, so an abandoned draft
// on a session the user never returns to does not sit in localStorage forever.

const PREFIX = "zimmerDraft:"

// How long a draft is worth restoring. Long enough to survive a phone left
// alone over a weekend, short enough that a draft abandoned two weeks ago
// doesn't reappear as a surprise.
export const DRAFT_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000

// Safari in private mode, and any browser with site data blocked, throws on
// localStorage access rather than returning null. A draft is a nicety — never
// let its absence break the surface it is attached to.
function store() {
  try {
    return window.localStorage
  } catch {
    return null
  }
}

// Build a namespaced key. `scope` isolates one record from another (a session
// id), `field` isolates one input from another within that record — so a draft
// never bleeds from one session's composer into another's.
export function draftKey(scope, field) {
  return `${PREFIX}${scope}:${field}`
}

// Persist `value` under `key`. A blank value clears the entry instead of
// storing an empty string, so "I deleted what I typed" survives a reload as
// faithfully as "I typed something".
export function saveDraft(key, value, now = Date.now()) {
  const storage = store()
  if (!storage) return

  try {
    if (!value || value.trim() === "") {
      storage.removeItem(key)
      return
    }

    // Stamp when the text last *changed*, not when it was last written. The same
    // draft is rewritten on every visibility change, page navigation and stream
    // render, so stamping each write would push the expiry out indefinitely and
    // the 7-day limit would never actually arrive.
    const savedAt = unchangedSince(storage, key, value) ?? now
    storage.setItem(key, JSON.stringify({ value, savedAt }))
  } catch {
    // Quota exceeded, or storage disabled mid-flight. Nothing to do — the
    // user's text is still in the textarea they are looking at.
  }
}

// The timestamp already stored at `key` if it holds this exact text, otherwise
// null. Lets a rewrite of unchanged text keep its original age.
function unchangedSince(storage, key, value) {
  try {
    const existing = JSON.parse(storage.getItem(key))
    if (existing && existing.value === value && typeof existing.savedAt === "number") {
      return existing.savedAt
    }
  } catch {
    // No usable entry — treat this as a first write.
  }
  return null
}

// Read the draft at `key`, or null if there is none, it has expired, or it was
// written by something other than saveDraft. An expired or unreadable entry is
// removed on the way out so it is not re-examined on every page load.
export function loadDraft(key, now = Date.now()) {
  const storage = store()
  if (!storage) return null

  let raw
  try {
    raw = storage.getItem(key)
  } catch {
    return null
  }
  if (!raw) return null

  let parsed
  try {
    parsed = JSON.parse(raw)
  } catch {
    clearDraft(key)
    return null
  }

  if (!parsed || typeof parsed.value !== "string" || typeof parsed.savedAt !== "number") {
    clearDraft(key)
    return null
  }

  if (now - parsed.savedAt > DRAFT_MAX_AGE_MS) {
    clearDraft(key)
    return null
  }

  return parsed.value
}

export function clearDraft(key) {
  const storage = store()
  if (!storage) return

  try {
    storage.removeItem(key)
  } catch {
    // Storage disabled mid-flight; nothing to clear.
  }
}

// Whether this document has already swept. A Stimulus controller connects again
// on every Turbo Stream form replacement, and the sweep reads and parses every
// stored draft — with prompts allowed up to 500k characters that is a
// main-thread cost worth paying once per page, not once per re-render.
let sweptThisDocument = false

// Drop every expired draft, at most once per document. Called on connect so
// drafts for sessions the user stopped visiting are collected by the act of
// visiting any other session, rather than needing a sweep the app has no other
// reason to schedule.
export function pruneExpiredDraftsOnce(now = Date.now()) {
  if (sweptThisDocument) return
  sweptThisDocument = true
  pruneExpiredDrafts(now)
}

export function pruneExpiredDrafts(now = Date.now()) {
  const storage = store()
  if (!storage) return

  let keys
  try {
    keys = Object.keys(storage).filter((key) => key.startsWith(PREFIX))
  } catch {
    return
  }

  // loadDraft removes anything expired or unparseable as a side effect.
  keys.forEach((key) => loadDraft(key, now))
}
