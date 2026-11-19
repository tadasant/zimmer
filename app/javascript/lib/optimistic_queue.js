// Queueing a message from a session's composer without stopping the page.
//
// A message queued while a turn is underway shows in the queue at the click, as a
// placeholder row reading "Queueing…", and the composer is the user's again in
// the same click: they can type the next message, queue it too, or follow a link
// in the transcript while the first request is still on its way. The request is
// a plain `fetch` rather than a Turbo form submission, for two reasons. A Turbo
// submission marks the drawer's `turbo-frame#session_detail` busy, and the
// stylesheet dims and disables a busy drawer; and Turbo cancels a form's
// in-flight submission when the form is submitted again, so a second message
// queued quickly would abort the first.
//
// Requests for one session go out one at a time, in the order they were queued,
// so the server gives them positions in the order the user wrote them. The
// server answers a queued message with a stream that redraws the queue and the
// new row's id in `X-Enqueued-Message-Id`; the placeholder leaves once that row
// is on the page.
//
// A Send Now clicked on a placeholder is remembered and carried out the moment
// the id arrives. A message the server refuses, or that never reaches it, is not
// lost: when the composer is still empty the words go back into it (with a toast
// saying so); otherwise — the user has started the next message, or the message
// carried attachments the composer can no longer hold — the placeholder stays as
// a failed row with Retry and Discard.
//
// The state lives here, at module level and keyed by session, rather than on
// the composer's controller: a status broadcast can replace the composer while a
// request is in flight, and the new controller redraws the placeholders with
// `redrawPendingQueue`.

import { csrfToken } from "lib/csrf"
import { clearDraft, followUpDraftKey } from "lib/draft_storage"
import { showAlert, showNotice } from "lib/toast"

const ID_HEADER = "X-Enqueued-Message-Id"
const STREAM_ACCEPT = "text/vnd.turbo-stream.html, text/html, application/xhtml+xml"

// sessionId -> { chain: Promise, entries: Array<Entry> }
const queues = new Map()
let nextKey = 1

// Queue `text` (with the composer's other fields in `formData`) for a session.
export function queueMessage({ sessionId, url, formData, text, hasAttachments = false }) {
  const queue = queueFor(sessionId)
  const entry = { key: nextKey++, sessionId, url, formData, text, hasAttachments, state: "queueing", sendNow: false, error: null }
  queue.entries.push(entry)
  draw(sessionId)
  enqueue(entry)
  return entry
}

// Draw the session's placeholders into its composer. Called when the composer
// (re)connects, since a replaced composer starts with an empty container.
export function redrawPendingQueue(sessionId) {
  if (queues.has(sessionId)) draw(sessionId)
}

// --- requests ----------------------------------------------------------------

function queueFor(sessionId) {
  if (!queues.has(sessionId)) queues.set(sessionId, { chain: Promise.resolve(), entries: [] })
  return queues.get(sessionId)
}

function enqueue(entry) {
  const queue = queueFor(entry.sessionId)
  queue.chain = queue.chain.then(() => send(entry)).catch((error) => console.error("[optimistic_queue]", error))
}

async function send(entry) {
  if (entry.state !== "queueing") return

  let response
  try {
    response = await fetch(entry.url, {
      method: "POST",
      body: entry.formData,
      credentials: "same-origin",
      headers: { "Accept": STREAM_ACCEPT, "X-CSRF-Token": csrfToken() }
    })
  } catch (error) {
    fail(entry, "The server could not be reached.")
    return
  }

  const body = await response.text().catch(() => "")
  const id = response.headers.get(ID_HEADER)
  if (!response.ok || !id) {
    // The server's own reason (an error above the composer) says more than a
    // status code; render it when it sent one.
    if (isStream(response) && body) renderStream(body)
    fail(entry, response.ok ? "The server did not confirm it." : `The server answered ${response.status}.`)
    return
  }

  if (entry.sendNow) {
    await sendNow(entry, id, body)
    return
  }

  forgetDraft(entry.sessionId)
  renderStream(body)
  await settle(entry, id)
}

// The placeholder's Send Now, carried out once the message exists. The queue's
// own row never shows: the interrupt's answer redraws the queue without it.
async function sendNow(entry, id, createBody) {
  forgetDraft(entry.sessionId)
  showNotice("Sending now — the current turn ends.")
  let response
  try {
    response = await fetch(`/sessions/${entry.sessionId}/enqueued_messages/${id}/interrupt`, {
      method: "POST",
      credentials: "same-origin",
      headers: { "Accept": STREAM_ACCEPT, "X-CSRF-Token": csrfToken() }
    })
  } catch (error) {
    response = null
  }

  const body = response ? await response.text().catch(() => "") : ""
  if (response?.ok) {
    if (isStream(response)) renderStream(body)
    remove(entry)
    return
  }

  // Queued, but not sent: show it in the queue, where its own Send Now can be
  // tried again. A refusal streamed by the server carries its own alert.
  renderStream(createBody)
  if (response && isStream(response) && body) {
    renderStream(body)
  } else {
    showAlert(`Your message was queued but could not be sent now. ${response ? `The server answered ${response.status}.` : "The server could not be reached."}`)
  }
  await settle(entry, id)
}

// Take the placeholder down once the server's row for it is on the page, so the
// queue never shows the message twice or not at all. A stream renders on the next
// frame, not synchronously; give it a moment, then stand down regardless.
async function settle(entry, id) {
  const deadline = Date.now() + 2000
  while (!document.getElementById(`enqueued_message_${id}`) && Date.now() < deadline) {
    await new Promise((resolve) => requestAnimationFrame(resolve))
  }
  remove(entry)
}

function fail(entry, reason) {
  entry.error = reason
  if (!entry.hasAttachments && restoreToComposer(entry)) {
    remove(entry)
    showAlert(`Your message was not queued. ${reason} It is back in the composer.`)
    return
  }
  entry.state = "failed"
  draw(entry.sessionId)
  showAlert(`Your message was not queued. ${reason}`)
}

function retry(entry) {
  entry.state = "queueing"
  entry.error = null
  entry.sendNow = false
  // To the back of the line: it is queued after anything sent since it failed.
  const queue = queueFor(entry.sessionId)
  queue.entries = queue.entries.filter((other) => other !== entry).concat(entry)
  draw(entry.sessionId)
  enqueue(entry)
}

function remove(entry) {
  const queue = queues.get(entry.sessionId)
  if (!queue) return
  queue.entries = queue.entries.filter((other) => other !== entry)
  draw(entry.sessionId)
}

// Put the words back where the user typed them, but only into an empty composer:
// anything already there is the next message, and is theirs. An `input` event
// lets the composer mirror the text to its other textarea and save the draft.
function restoreToComposer(entry) {
  const textareas = composerTextareas(entry.sessionId)
  if (textareas.length === 0 || textareas.some((textarea) => textarea.value.trim() !== "")) return false

  textareas.forEach((textarea) => { textarea.value = entry.text })
  textareas[0].dispatchEvent(new Event("input", { bubbles: true }))
  return true
}

// The composer left its stored draft on disk while the message was in flight.
// Now that the server has it, the draft goes — unless the user has started the
// next message, which the composer saves as the draft itself.
function forgetDraft(sessionId) {
  const textareas = composerTextareas(sessionId)
  if (textareas.some((textarea) => textarea.value.trim() !== "")) return
  clearDraft(followUpDraftKey(sessionId))
}

function composerTextareas(sessionId) {
  return [
    document.getElementById(`session_${sessionId}_follow_up_textarea`),
    document.getElementById(`session_${sessionId}_follow_up_textarea_mobile`)
  ].filter(Boolean)
}

function renderStream(html) {
  if (html) window.Turbo?.renderStreamMessage(html)
}

function isStream(response) {
  return (response.headers.get("Content-Type") || "").includes("turbo-stream")
}

// --- drawing -----------------------------------------------------------------

function draw(sessionId) {
  const container = document.getElementById(`session_${sessionId}_pending_enqueued`)
  if (!container) return
  const entries = queues.get(sessionId)?.entries || []
  container.replaceChildren(...entries.map(row))
}

function row(entry) {
  const failed = entry.state === "failed"
  const element = document.createElement("div")
  element.dataset.pendingEnqueuedMessage = entry.state
  element.className = `flex items-start gap-3 p-3 mb-2 rounded-md border ${failed ? "border-red-200 bg-red-50" : "border-dashed border-indigo-200 bg-indigo-50/50"}`

  const body = document.createElement("div")
  body.className = "flex-1 min-w-0"
  const status = document.createElement("p")
  status.className = `text-xs font-medium ${failed ? "text-red-700" : "text-indigo-600"}`
  status.dataset.pendingEnqueuedStatus = ""
  status.textContent = failed ? `Not queued. ${entry.error}` : entry.sendNow ? "Queueing — sends as soon as it is queued…" : "Queueing…"
  const text = document.createElement("p")
  text.className = "text-sm text-gray-700 truncate"
  text.textContent = entry.text.length > 200 ? `${entry.text.slice(0, 200)}…` : entry.text
  body.append(status, text)

  const actions = document.createElement("div")
  actions.className = "flex items-start gap-2 flex-shrink-0"
  if (failed) {
    actions.append(
      button("Retry", "border-transparent text-white bg-indigo-600 hover:bg-indigo-700", () => retry(entry)),
      button("Discard", "border-gray-300 text-gray-700 bg-white hover:bg-gray-100", () => remove(entry))
    )
  } else {
    const sendNow = button("Send Now", "border-transparent text-white bg-indigo-600 hover:bg-indigo-700", () => {
      entry.sendNow = true
      draw(entry.sessionId)
    })
    sendNow.title = "Send this message now (pauses agent)"
    if (entry.sendNow) {
      sendNow.disabled = true
      sendNow.classList.add("opacity-60", "cursor-wait")
    }
    actions.append(sendNow)
  }

  element.append(body, actions)
  return element
}

function button(label, classes, onClick) {
  const element = document.createElement("button")
  element.type = "button"
  element.className = `inline-flex items-center px-2.5 py-1.5 border text-xs font-medium rounded focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500 ${classes}`
  element.textContent = label
  element.addEventListener("click", onClick)
  return element
}
