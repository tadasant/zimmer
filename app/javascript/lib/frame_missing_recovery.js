// Zimmer never paints Turbo's bare "Content missing".
//
// When a <turbo-frame>'s own fetch comes back with a body that has no matching
// frame in it, Turbo dispatches `turbo:frame-missing`. If nothing cancels that
// event Turbo writes `<strong class="turbo-frame-error">Content missing</strong>`
// into the frame, marks the frame `complete`, and throws. Nothing retries: the two
// words sit there until the whole page is reloaded.
//
// Those two words have been chased four times, and only the last chase (#665) was
// about a body the server really did send wrong — /sessions/:id used to serve two
// structurally different bodies from one URL, and Turbo's URL-keyed prefetch cache
// handed the drawer the wrong one. Disjoint URLs closed that door, and the contract
// test beside this one keeps it closed.
//
// Every other cause is a response that has nothing to do with frames: the 502 a
// reverse proxy returns while the app restarts — which on this deployment happens
// several times a day, against a dashboard that is left open all day — a 500, the
// 404 for a session deleted out of the trash, and a redirect that answers a frame's
// fetch with a whole page. The dashboard fetches three frames on every load
// (`cli_badge`, `notification_badge`, and the drawer's `session_detail`), and any
// of those responses reaching any of those frames prints the same string in the
// same place.
//
// So this handler owns the OUTCOME rather than trying to enumerate the causes. It
// always cancels the placeholder; it follows a redirect through as the whole-page
// visit it plainly is; it retries a server error a few times, because a deploy
// window is measured in seconds and healing itself is what the reader wants; and
// when it gives up it says so and leaves the retry as a button.

// Statuses worth trying again on their own. A restart (502/503/504), a rate limit
// (429) and a server error (500) all pass; a 404 or a 403 answers the same way
// forever, so retrying one only spends a request to print the same message.
const RETRYABLE_STATUSES = new Set([ 429, 500, 502, 503, 504 ])

// Three attempts spread over ~16s. A Kamal deploy swaps containers in well under
// that, so the common case heals before the reader has decided anything is wrong.
const RETRY_DELAYS_MS = [ 1500, 4000, 10000 ]

const FALLBACK_SELECTOR = "[data-frame-missing-fallback]"

// Per-frame retry budget. Keyed on the element, so a frame that leaves the document
// takes its state with it.
const retryState = new WeakMap()

function baseMessage(status) {
  if (status === 404) return "That page is no longer here."
  if (status === 502 || status === 503 || status === 504) return "Zimmer isn't answering right now."
  if (status >= 200 && status < 400) return "The server sent a different page than this panel asked for."
  return `This panel couldn't be loaded (HTTP ${status}).`
}

function messageFor(status, retrying) {
  const base = baseMessage(status)
  if (retrying) return `${base} Retrying…`
  // Only offer the retry where one could plausibly work. Telling someone to retry a
  // 404 is the kind of hedge that makes the rest of the message untrustworthy.
  if (RETRYABLE_STATUSES.has(status)) return `${base} Press Retry once it is back.`
  return base
}

function clearRetryTimer(frame) {
  const state = retryState.get(frame)
  if (state && state.timer) {
    clearTimeout(state.timer)
    state.timer = null
  }
}

// Turbo has already stamped `complete` on the element by the time the event fires,
// which is what stops it from ever trying again. `reload()` clears that and
// re-fetches the frame's own src.
function retryNow(frame, status) {
  if (!frame.isConnected || !frame.getAttribute("src")) return

  // A retry that neither renders nor misses again — a body Turbo declines to parse,
  // a request cancelled by a competing src — resolves here and nowhere else. Without
  // this the panel would sit claiming it was retrying when nothing was.
  Promise.resolve(frame.reload())
    .catch(() => {})
    .then(() => {
      const state = retryState.get(frame)
      if (state && state.timer) return
      if (frame.querySelector(FALLBACK_SELECTOR)) renderFallback(frame, status, false)
    })
}

function scheduleRetry(frame, status) {
  // Keyed on the src the retry would actually re-fetch, not on the URL the response
  // came back from: a redirect makes those two different, and budgeting against a
  // destination that moves would reset the count on every attempt.
  const src = frame.getAttribute("src")
  if (!src || !RETRYABLE_STATUSES.has(status)) return false

  const state = retryState.get(frame) || { src, attempt: 0, timer: null }
  // A frame re-pointed somewhere else (the drawer swapping sessions) starts a fresh
  // budget rather than inheriting the previous URL's failures.
  if (state.src !== src) {
    state.src = src
    state.attempt = 0
  }
  if (state.timer) clearTimeout(state.timer)

  const delay = RETRY_DELAYS_MS[state.attempt]
  if (delay === undefined) {
    state.timer = null
    retryState.set(frame, state)
    return false
  }

  state.attempt += 1
  state.timer = setTimeout(() => {
    state.timer = null
    retryNow(frame, status)
  }, delay)
  retryState.set(frame, state)
  return true
}

function buildFallback(frame, status, retrying) {
  const box = document.createElement("div")
  box.setAttribute("data-frame-missing-fallback", "")
  // The panel a screen reader was waiting on has just failed, so say so. The text is
  // set after the node is in the document, because a live region only announces what
  // changes once it is already in the accessibility tree.
  box.setAttribute("role", "status")
  box.className =
    "inline-flex max-w-full flex-wrap items-center gap-2 rounded-md border border-amber-300 " +
    "bg-amber-50 px-3 py-2 text-sm text-amber-900"

  const text = document.createElement("span")
  box.appendChild(text)

  if (frame.getAttribute("src")) {
    const button = document.createElement("button")
    button.type = "button"
    button.textContent = "Retry"
    button.className =
      "rounded border border-amber-400 bg-white px-2 py-0.5 text-xs font-medium text-amber-900 " +
      "hover:bg-amber-100 focus:outline-none focus:ring-2 focus:ring-amber-400"
    button.addEventListener("click", () => retryNow(frame, status))
    box.appendChild(button)
  }

  return { box, text }
}

function renderFallback(frame, status, retrying) {
  frame.querySelectorAll(FALLBACK_SELECTOR).forEach((node) => node.remove())

  const { box, text } = buildFallback(frame, status, retrying)
  // A frame that still holds content keeps it, with the notice above: a reload that
  // failed is a reason to explain, not a reason to throw away the panel the reader
  // was already reading. An empty frame has nothing to keep.
  if (frame.children.length > 0) frame.prepend(box)
  else frame.replaceChildren(box)

  text.textContent = messageFor(status, retrying)
}

function isFrame(node) {
  return node instanceof Element && node.localName === "turbo-frame"
}

document.addEventListener("turbo:frame-missing", (event) => {
  // Cancelling the event is the load-bearing line: it is what stops Turbo from
  // writing its placeholder and throwing.
  event.preventDefault()

  // Turbo redispatches on <html> when the frame left the document while its fetch
  // was in flight. Painting the fallback there would replace the entire page with
  // it, so an orphaned miss is cancelled and dropped.
  const frame = event.target
  if (!isFrame(frame)) return

  const detail = event.detail || {}
  const response = detail.response
  const status = (response && response.status) || 0

  // A response that followed a redirect is a whole page that happened to be asked
  // for through a frame. Turbo hands us the visit for exactly this case, and taking
  // it lands the reader on the page the server actually meant to send.
  if (response && response.redirected && typeof detail.visit === "function") {
    detail.visit(response)
    return
  }

  const retrying = scheduleRetry(frame, status)
  renderFallback(frame, status, retrying)

  // Turbo's own throw is suppressed above, so this is the only record left that a
  // frame fetch came back frameless.
  console.warn(
    `<turbo-frame id="${frame.id}"> got a response (${status}) from ` +
      `${(response && response.url) || frame.getAttribute("src")} with no matching frame` +
      (retrying ? " — retrying." : " — giving up.")
  )
})

// A frame that loaded gets its retry budget back, so a later failure is not judged
// by an outage that is already over.
document.addEventListener("turbo:frame-load", (event) => {
  if (!isFrame(event.target)) return
  clearRetryTimer(event.target)
  retryState.delete(event.target)
})

// A frame that starts a fetch of its own — the drawer opening a different session —
// must not be yanked back a second later by a retry armed for the URL it just left.
document.addEventListener("turbo:before-fetch-request", (event) => {
  if (isFrame(event.target)) clearRetryTimer(event.target)
})
