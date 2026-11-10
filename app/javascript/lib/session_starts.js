// A session asked for and not yet answered with its id.
//
// The chat bubble's Submit & Open wants the new session's page. A native post
// lands there only when the server redirects — a full page load, with nothing on
// screen in between and the typed prompt lost to any refusal. The iOS app opens
// the session's page the moment the start is asked for, on a placeholder, and
// fills it in when the id comes. This is the web's version of that. (The board's
// own prompt box stays on the board and follows the start in a toast instead —
// see quick_prompt_controller.)
//
// `startSession` fires the request and visits `/sessions/starting` at once. Turbo
// Drive swaps the body and keeps this module alive, so the request keeps running
// and the starting page's controller (`session_start_controller`) subscribes to
// it: on the answer it visits the session; on a refusal it shows why, with Try
// again and Edit. A reload of the starting page loses the module's state, and the
// page then says so and points at the board, where the session will be listed
// if the server had taken the start.

import { Turbo } from "@hotwired/turbo-rails"

export const STARTING_PATH = "/sessions/starting"
// Where Edit leaves the words for the board's prompt box to pick up.
export const DRAFT_KEY = "zimmer.quickPrompt.draft"

let current = null

// Start a session: `request` returns the fetch promise for a JSON answer carrying
// `url` (or `session_url`) on success and `error` on a refusal; `prompt` and
// `title` are what the starting page shows meanwhile.
export function startSession({ prompt, title, request }) {
  current = { prompt, title, request, state: "starting", url: null, error: null, listeners: new Set() }
  run(current)
  Turbo.visit(STARTING_PATH)
  return current
}

export function currentStart() {
  return current
}

export function retryStart() {
  if (current && current.state === "failed") run(current)
}

export function forgetStart() {
  current = null
}

// Called with the start on every change of state, and once for the state it is
// in — after the caller has the way to unsubscribe in hand, since a start already
// answered visits the session from that first call.
export function subscribe(start, listener) {
  start.listeners.add(listener)
  queueMicrotask(() => { if (start.listeners.has(listener)) listener(start) })
  return () => start.listeners.delete(listener)
}

async function run(start) {
  start.state = "starting"
  start.error = null
  notify(start)
  try {
    const response = await start.request()
    const data = await response.json().catch(() => ({}))
    if (!response.ok) {
      throw new Error(data.error || `The server answered ${response.status}.`)
    }
    const url = data.session_url || data.url
    if (!url) throw new Error("The server did not say where the session is.")
    start.state = "started"
    start.url = url
  } catch (error) {
    start.state = "failed"
    start.error = error instanceof TypeError ? "The server could not be reached." : (error.message || "The session did not start.")
  }
  notify(start)
}

function notify(start) {
  start.listeners.forEach((listener) => listener(start))
}
