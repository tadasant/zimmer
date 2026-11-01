// Actions the page shows at the click, before the server has answered.
//
// Most of Zimmer's mutating controls are Turbo form submissions — a `button_to`,
// or a link with `data-turbo-method` — that the server answers with a Turbo
// Stream: remove this card, replace that row, put a toast in `#flash`. This
// module listens to every Turbo submission at the document level, recognises the
// ones whose outcome the page can predict, and applies that outcome at
// `turbo:submit-start`: the card leaves, the row dims, the button says what it is
// doing. The server's stream then lands on a page that already looks right (a
// `remove` for an element that is gone is a no-op; a `replace` finds the row and
// corrects any guess).
//
// When the submission fails — the server refused, or was never reached — the
// change is put back at `turbo:submit-end` and the refusal shows as a toast,
// unless the server's own stream already said so (`respond_with_flash` answers a
// refusal with an alert in `#flash`, and that stream renders whatever the status).
//
// What this deliberately does NOT do is predict an outcome the server decides:
// an Undo (the card's markup is the server's), a Restore (the status the session
// comes back to is the server's), a trigger's Invoke (the session it starts).
// Those keep their immediate `turbo_submits_with` / disabled-button feedback.
//
// `isPendingRemoval` is for the live-update code that inserts rows the page
// does not have (`ranked_queue_controller#insertRow`, the reopen backfill): a
// row this page has just taken away must not come back from a status broadcast
// that was queued before the archive committed.

import { showAlert, showNotice } from "lib/toast"

// Rows this page has taken away and not yet heard back about, as `kind:id`.
const pendingRemovals = new Set()
// Each in-flight submission's change, for the rollback.
const inFlight = new WeakMap()

export function isPendingRemoval(kind, id) {
  return pendingRemovals.has(`${kind}:${id}`)
}

// --- rules -------------------------------------------------------------------
//
// Each rule matches a submission by its path and HTTP method and returns the
// change it made: the elements it detached, the classes it added, the labels it
// changed, and the words for a failure toast. `undo` reverses the parts that
// have no automatic reversal.

const RULES = [
  {
    // Trash. Every Trash affordance — the card's link, the ranked row's menu, the
    // User view's button, the mobile joystick, the detail header's form — posts
    // here. The dashboard shows the session as one of three elements; each leaves.
    test: (path, method) => method === "post" && /^\/sessions\/(\d+)\/archive$/.exec(path),
    apply(match) {
      const id = match[1]
      // The ranked view keeps a trashed row, reading "Trashed", when its filter
      // shows the trash: the row's leaving is the ranked stream's call there.
      const ids = [`session_${id}`, `user_view_row_${id}`]
      if (!rankedShowsTrash()) ids.push(`ranked_row_${id}`)
      return {
        detached: detach(ids),
        removal: `session:${id}`,
        failed: "The session could not be moved to trash."
      }
    }
  },
  {
    // A queued message deleted: its frame leaves the queue.
    test: (path, method) => method === "delete" && /^\/sessions\/\d+\/enqueued_messages\/(\d+)$/.exec(path),
    apply(match) {
      return {
        detached: detach([`enqueued_message_${match[1]}`]),
        removal: `enqueued_message:${match[1]}`,
        failed: "The queued message could not be deleted."
      }
    }
  },
  {
    // A queued message sent now: it leaves the queue and the turn ends. The server
    // may take up to ten seconds here (it waits for a follow-up in flight to land).
    test: (path, method) => method === "post" && /^\/sessions\/\d+\/enqueued_messages\/(\d+)\/interrupt$/.exec(path),
    apply(match) {
      return {
        detached: detach([`enqueued_message_${match[1]}`]),
        removal: `enqueued_message:${match[1]}`,
        notice: "Sending now — the current turn ends.",
        failed: "The queued message could not be sent now."
      }
    }
  },
  {
    // A read notification dismissed: its row leaves.
    test: (path, method) => method === "delete" && /^\/notifications\/(\d+)\/dismiss$/.exec(path),
    apply(match) {
      return {
        detached: detach([`notification_${match[1]}`]),
        removal: `notification:${match[1]}`,
        failed: "The notification could not be dismissed."
      }
    }
  },
  {
    // A notification marked read: the row reads as read — dimmed, its button gone —
    // and the server's replacement then draws it properly.
    test: (path, method) => method === "patch" && /^\/notifications\/(\d+)\/mark_read$/.exec(path),
    apply(match, form) {
      const row = document.getElementById(`notification_${match[1]}`)
      if (!row) return null
      row.classList.add("opacity-60")
      form.classList.add("invisible")
      return {
        undo() {
          row.classList.remove("opacity-60")
          form.classList.remove("invisible")
        },
        failed: "The notification could not be marked read."
      }
    }
  },
  {
    // Pause and Restart from a session's header: the link says what it is doing.
    // Pause can take up to ten seconds (the server waits for a follow-up in flight).
    test: (path, method) => method === "post" && /^\/sessions\/(\d+)\/(pause|restart)$/.exec(path),
    apply(match) {
      const verb = match[2] === "pause" ? "Pausing…" : "Restarting…"
      return {
        undo: busyLinks(`a[href$="/sessions/${match[1]}/${match[2]}"]`, verb),
        failed: match[2] === "pause" ? "The session could not be paused." : "The session could not be restarted."
      }
    }
  },
  {
    // A trigger switched on or off: its button says so until the server's row lands.
    test: (path, method) => method === "post" && /^\/triggers\/(\d+)\/toggle$/.exec(path),
    apply(match, form) {
      const button = form.querySelector("button")
      if (!button) return null
      const was = button.textContent.trim()
      const label = /disable/i.test(was) ? "Turning off…" : "Turning on…"
      return {
        undo: busyButton(button, label),
        failed: "The trigger could not be changed."
      }
    }
  }
]

// --- events ------------------------------------------------------------------

document.addEventListener("turbo:submit-start", (event) => {
  const form = event.target
  const submission = event.detail?.formSubmission
  if (!(form instanceof HTMLFormElement) || !submission) return

  // The submission's own location, which honours a submitter's `formaction`;
  // `form.action` would be a control, not a string, on a form with a field
  // named "action".
  const location = submission.location instanceof URL ? submission.location : new URL(form.getAttribute("action") || "", document.baseURI)
  if (location.origin !== window.location.origin) return
  const method = requestMethod(form)

  for (const rule of RULES) {
    const match = rule.test(location.pathname, method)
    if (!match) continue
    const change = rule.apply(match, form)
    if (!change) return
    if (change.removal) pendingRemovals.add(change.removal)
    if (change.notice) showNotice(change.notice)
    inFlight.set(submission, change)
    return
  }
})

document.addEventListener("turbo:submit-end", (event) => {
  const submission = event.detail?.formSubmission
  const change = submission && inFlight.get(submission)
  if (!change) return
  inFlight.delete(submission)
  if (change.removal) pendingRemovals.delete(change.removal)

  const response = event.detail.fetchResponse
  if (event.detail.success) {
    // A stream answer replaces or removes what was changed, so the change stays
    // until it lands — this event fires before the stream has rendered, and an
    // undo here would flicker the old label back for a frame. A redirect (the
    // trigger page's toggle) replaces nothing, so the label is put back.
    if (!(response && isStream(response))) change.undo?.()
    return
  }

  const restored = rollback(change)
  // The server's own refusal — an alert streamed into #flash — says more than a
  // status code would; a toast on top of it would say the same thing twice.
  if (response && isStream(response)) return
  const reason = response ? `The server answered ${response.statusCode}.` : "The server could not be reached."
  showAlert(`${change.failed} ${reason} ${restored ? "Nothing changed." : "Nothing changed; reload to see it."}`)
})

// --- helpers -----------------------------------------------------------------

// `button_to` posts with a `_method` override; a `data-turbo-method` link's form
// carries the method itself.
function requestMethod(form) {
  const override = form.elements.namedItem("_method")
  const method = (override && override.value) || form.getAttribute("method") || "get"
  return method.toLowerCase()
}

function isStream(fetchResponse) {
  return (fetchResponse.contentType || "").includes("turbo-stream")
}

// Whether the ranked view on this page lists trashed sessions: its status filter
// is empty (every status) or names the trash.
function rankedShowsTrash() {
  const ranked = document.querySelector("[data-controller~='ranked-queue']")
  if (!ranked) return false
  try {
    const statuses = JSON.parse(ranked.dataset.rankedQueueStatusFilterValue || "[]")
    return statuses.length === 0 || statuses.includes("archived")
  } catch (error) {
    return false
  }
}

// Take the elements with these ids out of the document, remembering where each
// was so a refusal can put it back. Missing ids are skipped: the server does not
// know which of a session's elements this page shows, and neither does this.
function detach(ids) {
  const detached = []
  for (const id of ids) {
    const element = document.getElementById(id)
    if (!element) continue
    const parent = element.parentNode
    detached.push({ element, parent, parentId: parent?.id, next: element.nextSibling })
    element.remove()
  }
  return detached
}

// Put a change back. True when everything detached found its place again: in
// front of the sibling it had, at the end of its container, or at the top of the
// container's replacement when a broadcast swapped the container meanwhile.
function rollback(change) {
  change.undo?.()
  let restored = true
  for (const { element, parent, parentId, next } of change.detached || []) {
    if (parent && parent.isConnected) {
      parent.insertBefore(element, next && next.parentNode === parent ? next : null)
    } else if (parentId && document.getElementById(parentId)) {
      document.getElementById(parentId).prepend(element)
    } else {
      restored = false
    }
  }
  return restored
}

// A link's text swapped for what it is doing, with the way back.
function busyLinks(selector, label) {
  const restores = []
  document.querySelectorAll(selector).forEach((link) => {
    const span = link.querySelector("span") || link
    restores.push({ node: span, text: span.textContent })
    span.textContent = label
    link.setAttribute("aria-busy", "true")
    link.classList.add("opacity-70", "pointer-events-none")
  })
  return () => restores.forEach(({ node, text }) => {
    node.textContent = text
    const link = node.closest("a") || node
    link.removeAttribute("aria-busy")
    link.classList.remove("opacity-70", "pointer-events-none")
  })
}

function busyButton(button, label) {
  const children = Array.from(button.childNodes)
  button.textContent = label
  button.setAttribute("aria-busy", "true")
  return () => {
    button.replaceChildren(...children)
    button.removeAttribute("aria-busy")
  }
}
