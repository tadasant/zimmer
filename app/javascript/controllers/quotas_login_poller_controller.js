import { Controller } from "@hotwired/stimulus"

// Polls the login_status endpoint for an in-flight RuntimeLoginAttempt and
// applies the returned Turbo Stream, surfacing the verification URL/code and
// status transitions as the worker drives the login CLI.
//
// The controller lives on the non-terminal login-attempt element. Each poll
// replaces that element (or, on success, the whole account card). When the
// replacement is itself terminal it carries no controller, so polling stops
// naturally; disconnect() clears the timer for the element being torn down.
//
// Usage: data-controller="quotas-login-poller"
//        data-quotas-login-poller-url-value="<login_status_path>"
//        data-quotas-login-poller-interval-value="2000"
export default class extends Controller {
  static values = {
    url: String,
    interval: { type: Number, default: 2000 },
    // Milliseconds left before this attempt cannot succeed (the server's
    // expires_at, plus slack for the reaper), measured at render time. A
    // *duration* rather than an absolute instant on purpose: comparing a
    // server-rendered epoch against Date.now() would abandon a perfectly healthy
    // login on any browser whose clock runs fast. 0 disables the deadline.
    remaining: { type: Number, default: 0 }
  }

  // Give up after this many consecutive failed polls (network error or non-2xx)
  // so a persistently-failing endpoint doesn't poll forever in the background.
  static MAX_CONSECUTIVE_ERRORS = 10

  // Consecutive failures back the poll off exponentially rather than retrying at
  // the flat intervalValue cadence. The count above is a budget for "the server is
  // really gone", and at a flat 2s it would be spent in twenty seconds — well
  // inside a deploy, a laptop lid closing, or a wifi handover — abandoning a login
  // that would have completed. Backing off spends the same ten attempts over ~3
  // minutes (2s, 4s, 8s, 16s, then 30s each), which is long enough for a real blip
  // to end and still bounded by the attempt's own expires_at deadline below.
  static BACKOFF_MULTIPLIER = 2
  static MAX_BACKOFF_MS = 30000

  connect() {
    this.stopped = false
    this.errorCount = 0
    // Anchored to this browser's own clock, so only elapsed time matters. Each
    // poll re-renders the panel and re-anchors it against a fresh server value.
    this.deadline = this.remainingValue ? Date.now() + this.remainingValue : 0
    this.scheduleNextPoll()
  }

  disconnect() {
    this.stopped = true
    if (this.timer) {
      clearTimeout(this.timer)
      this.timer = null
    }
  }

  // A self-rescheduling timeout rather than a fixed setInterval, because the gap
  // between polls is no longer constant — it grows with errorCount. It also means
  // a poll can never be scheduled on top of one still in flight.
  scheduleNextPoll() {
    if (this.stopped) return

    // Only ever one timer tracked at a time: an untracked one would survive
    // disconnect() and poll on at a doubled cadence with nothing able to stop it.
    if (this.timer) clearTimeout(this.timer)

    this.timer = setTimeout(() => {
      this.timer = null
      this.poll()
    }, this.delayForNextPoll())
  }

  // The normal cadence while healthy; the backoff curve while failing.
  //
  // Never schedules past the deadline, because the deadline is only ever noticed
  // by a poll waking up: a 30s backoff gap that straddles it would leave the
  // panel claiming to be working for up to 30 seconds after the attempt could
  // still have succeeded. Clamping keeps the give-up message as prompt as it was
  // at a flat cadence.
  delayForNextPoll() {
    const delay =
      this.errorCount === 0
        ? this.intervalValue
        : Math.min(
            this.intervalValue * this.constructor.BACKOFF_MULTIPLIER ** (this.errorCount - 1),
            this.constructor.MAX_BACKOFF_MS
          )

    if (!this.deadline) return delay
    // +1 so a clamped wake-up lands strictly PAST the deadline, which is what
    // the `>` check in poll() tests for.
    return Math.min(delay, Math.max(0, this.deadline - Date.now() + 1))
  }

  async poll() {
    if (this.stopped) return

    // Client-side backstop. The server drives every attempt to a terminal state
    // (RuntimeLoginAttempt#fail_orphaned!, applied lazily on this very endpoint),
    // so reaching this deadline means we are not getting truthful answers at all
    // — the panel must still stop lying rather than spin on.
    if (this.deadline && Date.now() > this.deadline) {
      this.giveUp(
        "This login didn't finish in time and has been abandoned. Reload the page and authenticate again."
      )
      return
    }

    try {
      const response = await fetch(this.urlValue, {
        headers: { Accept: "text/vnd.turbo-stream.html" },
        credentials: "same-origin"
      })
      if (!response.ok) {
        this.recordError()
        return
      }
      const stream = await response.text()
      // The element may have been disconnected while awaiting the response.
      if (this.stopped) return
      this.errorCount = 0
      this.applyStream(stream)
    } catch (_e) {
      // Transient network error — the next tick retries, up to the error cap.
      this.recordError()
    } finally {
      // A no-op once giveUp() has stopped us, so the give-up paths stay terminal.
      // A Turbo swap is different: Stimulus delivers disconnect() on a later
      // microtask, so this still schedules a timer — disconnect()'s clearTimeout is
      // what tears it down, which is why the handle must stay tracked.
      this.scheduleNextPoll()
    }
  }

  // The poll response replaces the whole login panel — including, in the
  // awaiting_code state, the authorization-code <form> the user pastes into and
  // clicks Submit on. Applying it on every tick (every intervalValue ms) tears
  // that form out and rebuilds it from scratch, which breaks the submit in two
  // ways: a click landing on the old Submit button after the swap hits a node
  // that is no longer in the document (no submit fires), and a click landing in
  // the brief window before the rebuilt field is repopulated submits an empty
  // code (which the controller silently drops). Either way "pasting the code
  // does nothing".
  //
  // While awaiting_code the verification URL and the panel are static — a poll
  // that still reports awaiting_code carries no new information, so there is
  // nothing to render. Apply the stream only when the status actually changes
  // (into awaiting_code, or onward to completing/succeeded/failed/...); skip the
  // redundant same-status re-renders so the form the user is interacting with
  // stays put: same node, same value, same focus. This keeps the Submit path
  // intact across the entire awaiting_code window without any snapshot/restore.
  applyStream(stream) {
    const current = this.element.dataset.loginStatus
    const next = this.parseLoginStatus(stream)
    if (current === "awaiting_code" && next === "awaiting_code") return
    window.Turbo.renderStreamMessage(stream)
  }

  // Read the attempt's status out of a login_status Turbo Stream payload. The
  // streamed panel carries it as data-login-status on the login-attempt element.
  // Returns null when the stream has no such marker (e.g. the success response
  // swaps in the whole account card), in which case the caller applies it — the
  // skip only ever suppresses a redundant awaiting_code → awaiting_code render.
  parseLoginStatus(stream) {
    try {
      const doc = new DOMParser().parseFromString(stream, "text/html")
      // Turbo Stream content lives inside <turbo-stream><template>…; <template>
      // contents parse into .content rather than the main tree, so reach in.
      const template = doc.querySelector("turbo-stream template")
      const el = template ? template.content.querySelector("[data-login-status]") : null
      return el ? el.dataset.loginStatus : null
    } catch (_e) {
      return null
    }
  }

  recordError() {
    this.errorCount += 1
    if (this.errorCount >= this.constructor.MAX_CONSECUTIVE_ERRORS) {
      this.giveUp(
        "Lost contact with the server while finishing sign-in, so this login's outcome is unknown. " +
        "Reload the page to see the account's current state."
      )
    }
  }

  // Stop polling AND say so on screen.
  //
  // Stopping the timer alone is what made this panel hang: the last frame the
  // poller rendered — typically "Finishing sign-in and capturing credentials…" —
  // stayed on screen verbatim, with nothing left running to ever replace it. A
  // spinner that has stopped spinning toward anything is indistinguishable from
  // one that is still working, so the user waits forever on a dead panel. Every
  // give-up path must repaint the element with what went wrong.
  giveUp(message) {
    this.disconnect()

    const notice = document.createElement("div")
    notice.className = "rounded-md bg-amber-50 border border-amber-200 p-3"
    const text = document.createElement("p")
    text.className = "text-xs text-amber-800"
    text.textContent = message
    notice.appendChild(text)

    this.element.replaceChildren(notice)
    // Drop the status marker so a later poll response (or a Turbo cache restore)
    // can't mistake this for a live attempt still sitting in its old state.
    delete this.element.dataset.loginStatus
  }
}
