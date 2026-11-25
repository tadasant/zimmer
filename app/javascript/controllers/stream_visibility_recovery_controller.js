import { Controller } from "@hotwired/stimulus"
import { Turbo, cable } from "@hotwired/turbo-rails"
import { backfillLiveRegions } from "lib/live_region_backfill"

// Connects to data-controller="stream-visibility-recovery"
//
// Recovers a page that was hidden long enough for its ActionCable socket to die
// — the backgrounded standalone PWA, the locked phone, the bfcache restore.
//
// Two things break in that moment and need different answers:
//
//   1. The socket is dead, so no future update arrives. Reopening the consumer
//      fixes it: ActionCable re-subscribes every subscription on the connection,
//      for the cost of a handshake and no rendering at all.
//   2. Whatever was broadcast while the page was away is gone. Broadcasts are
//      fire-and-forget with no replay, so re-subscribing cannot recover them.
//      Only the server can say what the page should look like now.
//
// (2) is answered with a backfill: fetch the page the server would render and
// reconcile only the regions broadcasts target (see lib/live_region_backfill.js
// and the `data-live-region` markers in the views). Missed timeline items, a
// changed status badge and a stale header land in the document the reader was
// already looking at — same scroll position, same open disclosures, same
// expanded items, no navigation at all.
//
// That matters because iOS suspends a backgrounded standalone PWA, which kills
// the WebSocket: the socket is dead on *every* reopen, so this branch runs every
// time the user switches back to the app. Answering it with a navigation is what
// makes an installed PWA appear to reload on each reopen. Checking `isOpen()`
// first does not help — it only makes the case that never happens free.
//
// A backfill that cannot complete falls back to a replacing visit. A page that
// silently failed to recover is the one outcome worse than a page that lost its
// place.
//
// Triggers:
//   - visibilitychange -> 'visible', after the page was hidden at least
//     `staleAfter`. Shorter hides do not kill the socket.
//   - pageshow with event.persisted === true (bfcache restore).
//   - a stream source that lost its subscription getting it back, however that
//     happened: a deploy replacing the server, a laptop waking, a network blip, a
//     socket ActionCable only later noticed was dead. ActionCable reconnects on its
//     own, so nothing looks wrong; what was broadcast in the gap is still missing.
//     A hidden page waits until it is looked at.
//
// Dispatches `backfilling` before it fetches, then `recovered` or `failed`.
export default class extends Controller {
  static values = {
    // Minimum hidden duration (ms) before the socket is worth checking at all.
    staleAfter: { type: Number, default: 5000 },
    // How long (ms) to let the reopened socket land before backfilling. Doing it
    // in this order means an update broadcast *during* the backfill still has a
    // subscription to arrive on.
    reconnectGrace: { type: Number, default: 1500 },
    // How long (ms) to wait for the backfill's fetch. A phone that came back
    // before its network did would otherwise hold the recovery open with no
    // answer either way; past this the fallback visit takes over.
    fetchTimeout: { type: Number, default: 10000 },
    // How long (ms) to wait, once a dropped subscription is back, for the page's
    // other subscriptions to come back too; and to wait before trying again.
    resubscribeSettle: { type: Number, default: 500 },
    resubscribeRetry: { type: Number, default: 5000 },
    resubscribeAttempts: { type: Number, default: 5 }
  }

  connect() {
    this.hiddenAt = null
    this.isRecovering = false

    this.boundVisibilityChange = this.handleVisibilityChange.bind(this)
    this.boundPageShow = this.handlePageShow.bind(this)

    document.addEventListener("visibilitychange", this.boundVisibilityChange)
    window.addEventListener("pageshow", this.boundPageShow)

    this.dropped = false
    this.failedAttempts = 0
    this.sourceObserver = new MutationObserver((mutations) => this.sourcesChanged(mutations))
    this.sourceObserver.observe(document.body, { subtree: true, attributes: true, attributeFilter: [ "connected" ] })
  }

  disconnect() {
    document.removeEventListener("visibilitychange", this.boundVisibilityChange)
    window.removeEventListener("pageshow", this.boundPageShow)
    clearTimeout(this.recoveryTimer)
    clearTimeout(this.releaseTimer)
    clearTimeout(this.resubscribedTimer)
    this.sourceObserver?.disconnect()
  }

  handleVisibilityChange() {
    if (document.visibilityState === "hidden") {
      this.hiddenAt = Date.now()
      return
    }

    if (document.visibilityState !== "visible") return
    if (this.dropped) this.resubscribedSoon(this.resubscribeSettleValue)

    const hiddenDuration = this.hiddenAt ? Date.now() - this.hiddenAt : 0
    this.hiddenAt = null

    // Brief tab switches don't kill the WebSocket — let it ride.
    if (hiddenDuration < this.staleAfterValue) return

    this.recover()
  }

  handlePageShow(event) {
    if (event.persisted) this.recover()
  }

  // turbo-rails sets `connected` on a stream source while it is subscribed and
  // removes it when the subscription drops. A source that left the document with
  // what it was in (a closed drawer) has nothing to catch up on.
  sourcesChanged(mutations) {
    for (const { target } of mutations) {
      if (target.tagName !== "TURBO-CABLE-STREAM-SOURCE" || !target.isConnected) continue
      if (!target.hasAttribute("connected")) this.dropped = true
      else if (this.dropped) this.resubscribedSoon(this.resubscribeSettleValue)
    }
  }

  resubscribedSoon(delay) {
    clearTimeout(this.resubscribedTimer)
    this.resubscribedTimer = setTimeout(() => this.backfillAfterDrop(), delay)
  }

  // Nobody asked for this one, so it never falls back to a visit: a page being
  // read is worth more than the rows it missed. It tries again instead, a few
  // times, with the wait doubling.
  async backfillAfterDrop() {
    if (!this.dropped || document.visibilityState === "hidden") return
    // `recover` is already on its way to the same backfill.
    if (this.isRecovering) return this.resubscribedSoon(this.resubscribeRetryValue)
    if (!this.streamSources.some((source) => source.hasAttribute("connected"))) return

    this.isRecovering = true
    // A source still down has a longer gap than this backfill covers; its coming
    // back is a reason for another.
    this.dropped = !this.subscribed
    try {
      if (await this.backfill({ fallback: false })) {
        this.failedAttempts = 0
      } else if (++this.failedAttempts < this.resubscribeAttemptsValue) {
        this.dropped = true
        this.resubscribedSoon(this.resubscribeRetryValue * 2 ** (this.failedAttempts - 1))
      } else {
        // Given up on this gap; the next drop starts over.
        this.failedAttempts = 0
      }
    } finally {
      this.isRecovering = false
    }
  }

  // Restore live updates, and backfill only if something was missed.
  async recover() {
    if (this.isRecovering) return

    // A page with no stream sources has no live updates to lose.
    if (this.streamSources.length === 0) return

    this.isRecovering = true

    // A consumer that cannot be read says nothing about the socket, so fall
    // through to the backfill. Leaving a possibly-frozen page alone is the one
    // outcome worse than recovering it.
    let connection = null
    try {
      connection = (await cable.getConsumer())?.connection
    } catch (_e) {
      connection = null
    }

    if (connection?.isOpen()) {
      this.isRecovering = false
      this.dispatch("recovered", { detail: { socketWasOpen: true, changed: 0 } })
      return
    }

    try {
      // A socket still completing its handshake is already on its way back;
      // reopening would tear that down and start the delay over.
      if (!connection?.isActive()) connection?.reopen()

      await this.settle(this.reconnectGraceValue)

      // Subscribed again already: this backfill covers the gap, so the one that
      // follows a reconnect is not owed as well.
      if (this.subscribed) this.dropped = false
      await this.backfill()
    } finally {
      // Hold the guard past the backfill rather than releasing it here. A reopen
      // can deliver pageshow and visibilitychange back to back, and each would
      // otherwise stack another fetch onto the one already in flight.
      this.releaseTimer = setTimeout(() => {
        this.isRecovering = false
      }, 2000)
    }
  }

  get streamSources() {
    return Array.from(document.querySelectorAll("turbo-cable-stream-source"))
  }

  get subscribed() {
    return this.streamSources.every((source) => source.hasAttribute("connected"))
  }

  settle(delay) {
    return new Promise((resolve) => {
      this.recoveryTimer = setTimeout(resolve, delay)
    })
  }

  // Pick up what was broadcast while the page was away, in place. Reached only
  // for a socket that reported itself closed.
  //
  // Every failure inside this method — a fetch that never answers, HTML that
  // will not parse, a reconcile that throws part-way through — ends in the
  // fallback visit, because a page left half-recovered and quiet is worse than
  // one that lost its scroll position. With `fallback: false` it ends in a false
  // return instead, for a caller that tries again.
  async backfill({ fallback = true } = {}) {
    this.dispatch("backfilling")
    try {
      const response = await fetch(window.location.href, {
        // A reopen is a person coming back; a reconnect happens to a page nobody may
        // be looking at, and must not read as one (SessionsController#
        // human_initiated_view?). Neither is somebody choosing a view or filters
        // (#remember_dashboard_choice?).
        headers: {
          Accept: "text/html",
          "X-Zimmer-Backfill": "1",
          ...(fallback ? {} : { "X-Zimmer-Reconnect": "1" })
        },
        credentials: "same-origin",
        cache: "no-store",
        signal: AbortSignal.timeout(this.fetchTimeoutValue)
      })

      // A redirect means this URL is no longer the page it was — signed out, or
      // the record is gone. Let the browser follow it properly.
      if (response.redirected || !response.ok) return this.backfillFailed(fallback)

      const fresh = new DOMParser().parseFromString(await response.text(), "text/html")
      let changed = backfillLiveRegions(fresh)
      changed += await this.backfillDeferredPanels()
      this.dispatch("recovered", { detail: { socketWasOpen: false, changed } })
      return true
    } catch (_e) {
      return this.backfillFailed(fallback)
    }
  }

  backfillFailed(fallback) {
    this.dispatch("failed")
    if (fallback) this.reload()
    return false
  }

  // The live regions inside a deferred panel are not in the page just fetched.
  // That copy's deferred <turbo-frame>s are unloaded — each holds a
  // skeleton, which carries no ids on purpose — so backfillLiveRegions finds no
  // source for them and leaves them alone. Their source is the panel's own URL.
  //
  // Fetched and reconciled the same way rather than reloaded, because reloading
  // the frame would throw away what the reader accumulated inside it: the older
  // pages infinite scroll pulled in, and their place among them. Reconciling
  // appends what is missing and touches nothing else, exactly as it does for the
  // regions on the page.
  //
  // Only frames that have loaded are fetched — an unloaded frame has nothing on
  // screen to bring up to date. A panel that will not come back is
  // skipped rather than escalated to a full reload: by this point the socket is
  // open again, so the next broadcast reaches it anyway.
  async backfillDeferredPanels() {
    const loaded = Array.from(document.querySelectorAll("turbo-frame[data-deferred-panel][src]")).filter(
      (frame) => frame.complete
    )

    let changed = 0

    for (const frame of loaded) {
      try {
        // A frame may name a wider address for this than its own src: the
        // transcript's src is a ten-row tail, and a reader away for a while can
        // have missed more than ten rows.
        const response = await fetch(frame.dataset.backfillSrc || frame.src, {
          headers: { Accept: "text/html" },
          credentials: "same-origin",
          cache: "no-store",
          signal: AbortSignal.timeout(this.fetchTimeoutValue)
        })
        if (response.redirected || !response.ok) continue

        const panel = new DOMParser().parseFromString(await response.text(), "text/html")
        this.graftAppendTargets(panel)
        changed += backfillLiveRegions(panel)
        changed += this.dropStaleTransients(frame, panel)
      } catch (_e) {
        // Skip this panel; the reopened socket carries its next update.
      }
    }

    return changed
  }

  // Give a panel's batch container the id of the live region on the page it is
  // the server's answer for.
  //
  // The transcript's rows arrive in the frame, but broadcasts append them to
  // #session_<id>_timeline on the page — one id, two places, so the panel's copy
  // cannot carry it in the markup. Renaming it here is what lets the reconcile
  // append a recovered row into the SAME container as one that arrived over the
  // socket, and therefore in the right order relative to it.
  graftAppendTargets(panelDocument) {
    for (const container of panelDocument.querySelectorAll("[data-live-append-into]")) {
      const id = container.dataset.liveAppendInto
      // Never overwrite an id the panel already renders under that name.
      if (!id || panelDocument.getElementById(id)) continue

      // The id is the whole of it: backfillLiveRegions reads the STRATEGY off
      // the live element it is reconciling, never off the source, so setting
      // data-live-region here would be a line that looks load-bearing and is not.

      container.id = id
    }
  }

  // Drop a placeholder inside the frame that the server has stopped rendering.
  //
  // backfillLiveRegions sweeps `data-live-transient` children of the region it
  // reconciles, and the transcript's empty state ("No activity yet") is not one:
  // it sits inside the frame, a sibling of the append target rather than a child.
  // Left alone it would stay above the rows the backfill just recovered — which
  // is exactly what a broadcast removes it for.
  dropStaleTransients(frame, panelDocument) {
    let changed = 0

    for (const transient of Array.from(frame.querySelectorAll("[data-live-transient][id]"))) {
      if (panelDocument.getElementById(transient.id)) continue

      transient.remove()
      changed += 1
    }

    return changed
  }

  // Recovers everything and costs the reader their place, so it is reached only
  // when the backfill could not run to completion.
  reload() {
    Turbo.visit(window.location.href, { action: "replace" })
  }
}
