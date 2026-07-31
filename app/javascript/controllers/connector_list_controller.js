import { Controller } from "@hotwired/stimulus"

// Fills in the Connectors list after first paint, and then leads with the rows
// that need attention.
//
// The page renders ~100 rows from the catalog alone and defers every probe to a
// Turbo Frame. Two things follow, and this controller is both of them.
//
// **1. The frames must not wait for a scroll.** They ship as `loading="lazy"`,
// which is the floor: until this controller connects — and if it throws, or its
// bundle fails to load — the frames still resolve the way they always did, on
// appearance. That is a floor and not a fallback for a browser with JavaScript
// switched off: Turbo's lazy loading is itself JavaScript, so with none the rows
// never resolve either way. What lazy costs when the controller IS present is
// exactly the reported symptom: a badge below the fold stays blank until you
// scroll to it. So this promotes the frames to `eager`. It does NOT promote them
// all at once: ~100 simultaneous requests is a self-inflicted thundering herd
// against a Puma pool of a handful of threads, which makes the *first* badge
// slower than it was before. It keeps a small window open instead, so the rows
// nearest the top resolve immediately and the rest stream in behind them.
//
// **2. The order can only be fixed here.** Which servers have problems is
// computed inside each frame, so the controller that rendered the list did not
// know it. Sorting server-side would mean probing all ~100 up front and holding
// the whole page on the slowest one, which is the thing point 1 exists to avoid.
// So the sort happens in the browser, once the frames have settled.
//
// Severity is NOT decided here. Each resolved row carries a `data-connector-rank`
// from ConnectorsHelper::SEVERITY_RANKS, and the threshold for "needs attention"
// arrives as a value; this only compares numbers.
export default class extends Controller {
  static targets = ["list", "frame", "attention"]
  static values = {
    // Concurrent in-flight probes. Six is the classic per-origin connection cap,
    // so over HTTP/1.1 the browser would enforce something like it anyway; over
    // HTTP/2 it is us protecting the server rather than the browser protecting
    // itself.
    concurrency: { type: Number, default: 6 },
    // A frame that never reports back must not hold its slot forever, or one bad
    // row stalls every row behind it. Turbo dispatches `turbo:frame-load` on
    // success and `turbo:frame-missing` when the response carried no matching
    // frame, but an unhandled shape would otherwise wait on this.
    timeout: { type: Number, default: 15000 },
    // Where a row sorts when its frame never resolved, and the rank at which a
    // row stops counting as a problem. Server-supplied so the two definitions
    // cannot drift; the default matches ConnectorsHelper's `ready`.
    unresolvedRank: { type: Number, default: 6 }
  }

  connect() {
    this.inFlight = 0
    this.started = new Set()
    this.settled = new WeakSet()
    this.timers = new Map()
    this.sorted = false
    this.resolvedCount = -1
    this.listeners = new AbortController()

    const frames = this.frameTargets
    // Captured before anything moves, so the sort can fall back to the
    // alphabetical order the server rendered rather than to whatever order the
    // network happened to answer in.
    this.initialOrder = new Map(frames.map((frame, index) => [frame, index]))

    // Anything already carrying content is done before we start. Turbo Drive's
    // page cache restores this list *as this controller left it* — resolved
    // bodies, and the `loading="eager"` this controller wrote — so a
    // back-navigation onto a half-loaded page would otherwise have the sweep
    // below "release" rows that this instance never started, driving the
    // in-flight count negative: the window blows open and the terminal
    // `inFlight === 0` is never true again, so the list never sorts.
    frames.forEach((frame) => { if (this.resolved(frame)) this.settled.add(frame) })
    this.queue = frames.filter((frame) => !this.settled.has(frame))

    // A frame that has swapped in its content is done, whether or not its event
    // reached us. Turbo fires one in the ordinary case and this sweep is then
    // redundant — but a frame that renders without one (a cold first request
    // racing page load will do it) would otherwise hold its slot until the
    // watchdog, and the sort waits on the last slot.
    this.sweep = setInterval(() => this.reconcile(), 250)

    this.pump()
  }

  disconnect() {
    this.listeners.abort()
    this.timers.forEach((timer) => clearTimeout(timer))
    this.timers.clear()
    this.started.clear()
    clearInterval(this.sweep)
  }

  reconcile() {
    // Snapshot: release() mutates `started`, and pump() can add to it.
    Array.from(this.started).forEach((frame) => { if (this.resolved(frame)) this.release(frame) })
    if (this.inFlight > 0 || this.queue.length > 0) return

    // Two reasons to sort from here. A first sort that stood down because the
    // reader had focus in the list has to be retried; and a frame released by
    // the watchdog can resolve *after* the sort, where it would otherwise keep
    // the position it held while unranked. Both are gated on something actually
    // having changed, so this settles rather than shuffling the page on a timer.
    if (!this.sorted || this.countResolved() !== this.resolvedCount) this.sort()
    if (this.sorted && this.resolvedCount === this.frameTargets.length) clearInterval(this.sweep)
  }

  // Open the window up to `concurrency`, and sort once it has drained.
  pump() {
    if (this.listeners.signal.aborted) return

    const limit = Math.max(1, this.concurrencyValue)
    while (this.inFlight < limit && this.queue.length > 0) {
      this.load(this.queue.shift())
    }

    if (this.inFlight <= 0 && this.queue.length === 0) this.sort()
  }

  load(frame) {
    this.started.add(frame)
    this.inFlight += 1

    const release = () => this.release(frame)
    const options = { once: true, signal: this.listeners.signal }
    // frame-load is the success path; frame-missing is what Turbo dispatches for
    // a 404 or an error page, where no matching <turbo-frame> came back and no
    // frame-load ever fires; fetch-request-error is the network-level failure.
    frame.addEventListener("turbo:frame-load", release, options)
    frame.addEventListener("turbo:frame-missing", release, options)
    frame.addEventListener("turbo:fetch-request-error", release, options)
    this.timers.set(frame, setTimeout(release, this.timeoutValue))

    // Turbo observes this attribute: switching a frame with a `src` to eager
    // starts the request.
    frame.setAttribute("loading", "eager")
  }

  // Give a frame's slot back. Only frames this instance started hold one, so a
  // frame released twice — or released because a restored page already had its
  // content — costs nothing.
  release(frame) {
    clearTimeout(this.timers.get(frame))
    this.timers.delete(frame)
    this.settled.add(frame)
    if (!this.started.delete(frame)) return

    this.inFlight -= 1
    this.pump()
  }

  // Reorder the rows by severity, most urgent first, stable within a rank.
  //
  // Runs after the frames settle rather than on every arrival: reordering while
  // rows are still filling in moves content under the reader's cursor for the
  // whole load, which costs more than the ordering is worth.
  sort() {
    if (!this.hasListTarget) return

    const current = this.frameTargets
    const ranked = current
      .map((frame) => ({ frame, rank: this.rankOf(frame), index: this.initialOrder.get(frame) ?? 0 }))
      .sort((a, b) => a.rank - b.rank || a.index - b.index)

    // Moving a frame disconnects and reconnects it, which cancels any request it
    // still has open and drops focus to <body>. The first is unavoidable and
    // self-healing (Turbo re-fetches an incomplete frame on reconnect); the
    // second is not, so a reorder waits rather than yanking the control someone
    // is using out from under them.
    const moved = ranked.some((entry, position) => entry.frame !== current[position])
    if (moved && this.listTarget.contains(document.activeElement)) return
    if (moved) ranked.forEach((entry) => this.listTarget.appendChild(entry.frame))

    this.sorted = true
    this.resolvedCount = this.countResolved()
    this.element.setAttribute("data-connector-list-sorted", "true")
    this.countAttention(ranked)
  }

  resolved(frame) {
    return !!frame.querySelector("[data-connector-rank]")
  }

  countResolved() {
    return this.frameTargets.filter((frame) => this.resolved(frame)).length
  }

  rankOf(frame) {
    const resolved = frame.querySelector("[data-connector-rank]")
    if (!resolved) return this.unresolvedRankValue

    const rank = Number.parseInt(resolved.getAttribute("data-connector-rank"), 10)
    return Number.isInteger(rank) && rank >= 0 ? rank : this.unresolvedRankValue
  }

  countAttention(ranked) {
    if (!this.hasAttentionTarget) return

    const count = ranked.filter((entry) => entry.rank < this.unresolvedRankValue).length
    this.attentionTarget.textContent =
      count === 0 ? "Everything is configured" : `${count} need${count === 1 ? "s" : ""} attention, listed first`
    this.attentionTarget.setAttribute("data-attention-count", String(count))
  }
}
