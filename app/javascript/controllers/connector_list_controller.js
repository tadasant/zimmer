import { Controller } from "@hotwired/stimulus"

// Fills in the Connectors list after first paint, and then leads with the rows
// that need attention.
//
// The page renders ~100 rows from the catalog alone and defers every probe to a
// Turbo Frame. Two things follow, and this controller is both of them.
//
// **1. The frames must not wait for a scroll.** They ship as `loading="lazy"`,
// which is what makes them work with JavaScript off — and, with JavaScript on,
// is exactly the symptom: a badge below the fold stays blank until you scroll to
// it. This controller promotes them to `eager` itself. It does NOT promote them
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
// from ConnectorsHelper::SEVERITY_RANKS; this only compares the numbers.
export default class extends Controller {
  static targets = ["list", "frame", "attention"]
  static values = {
    // Concurrent in-flight probes. Six is the classic per-origin connection cap,
    // so over HTTP/1.1 the browser would enforce something like it anyway; over
    // HTTP/2 it is us protecting the server rather than the browser protecting
    // itself.
    concurrency: { type: Number, default: 6 },
    // A frame that neither loads nor errors must not hold its slot forever, or
    // one bad row stalls every row behind it.
    timeout: { type: Number, default: 15000 },
    // Where a row sorts when its frame never resolved. Alongside "ready" — it is
    // not known to be a problem, and promoting unknowns would bury the real ones.
    unresolvedRank: { type: Number, default: 6 }
  }

  connect() {
    this.inFlight = 0
    this.settled = new WeakSet()
    this.timers = new Map()
    // Captured before anything moves, so the sort can fall back to the
    // alphabetical order the server rendered rather than to whatever order the
    // network happened to answer in.
    this.initialOrder = new Map(this.frameTargets.map((frame, index) => [frame, index]))
    this.queue = this.frameTargets.filter((frame) => frame.getAttribute("loading") === "lazy")

    // A frame that has swapped in its content is done, whether or not its event
    // reached us. Turbo fires `turbo:frame-load` in the ordinary case and this
    // sweep is redundant — but a frame that renders without one (a cold first
    // request racing page load will do it) would otherwise hold its slot until
    // the watchdog, and the sort waits on the last slot. Trusting the DOM as
    // well as the event costs a quarter-second timer and removes that stall.
    this.sweep = setInterval(() => this.reconcile(), 250)

    this.pump()
  }

  disconnect() {
    this.timers.forEach((timer) => clearTimeout(timer))
    this.timers.clear()
    clearInterval(this.sweep)
  }

  reconcile() {
    this.frameTargets
      .filter((frame) => !this.settled.has(frame) && frame.getAttribute("loading") === "eager")
      .filter((frame) => frame.querySelector("[data-connector-rank]"))
      .forEach((frame) => this.release(frame))
  }

  // Open the window up to `concurrency`, and sort once it has drained.
  pump() {
    while (this.inFlight < this.concurrencyValue && this.queue.length > 0) {
      this.load(this.queue.shift())
    }

    if (this.inFlight === 0 && this.queue.length === 0) {
      clearInterval(this.sweep)
      this.sort()
    }
  }

  load(frame) {
    this.inFlight += 1

    const release = () => this.release(frame)
    frame.addEventListener("turbo:frame-load", release, { once: true })
    frame.addEventListener("turbo:fetch-request-error", release, { once: true })
    this.timers.set(frame, setTimeout(release, this.timeoutValue))

    // Turbo observes this attribute: switching a frame with a `src` to eager
    // starts the request.
    frame.setAttribute("loading", "eager")
  }

  release(frame) {
    if (this.settled.has(frame)) return
    this.settled.add(frame)

    clearTimeout(this.timers.get(frame))
    this.timers.delete(frame)
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

    const ranked = this.frameTargets
      .map((frame) => ({ frame, rank: this.rankOf(frame), index: this.initialOrder.get(frame) ?? 0 }))
      .sort((a, b) => a.rank - b.rank || a.index - b.index)

    const moved = ranked.some((entry, position) => entry.frame !== this.frameTargets[position])
    if (moved) ranked.forEach((entry) => this.listTarget.appendChild(entry.frame))

    this.element.setAttribute("data-connector-list-sorted", "true")
    this.countAttention(ranked)
  }

  rankOf(frame) {
    const resolved = frame.querySelector("[data-connector-rank]")
    if (!resolved) return this.unresolvedRankValue

    const rank = Number(resolved.getAttribute("data-connector-rank"))
    return Number.isFinite(rank) ? rank : this.unresolvedRankValue
  }

  countAttention(ranked) {
    if (!this.hasAttentionTarget) return

    const count = ranked.filter((entry) => entry.rank < this.unresolvedRankValue).length
    this.attentionTarget.textContent =
      count === 0 ? "Everything is configured" : `${count} need${count === 1 ? "s" : ""} attention, listed first`
    this.attentionTarget.setAttribute("data-attention-count", String(count))
  }
}
