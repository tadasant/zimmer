import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="session-prefetch"
//
// Fetches the detail of the session rows on screen in the background, so that
// clicking View paints from the browser's HTTP cache instead of waiting on the
// server.
//
// What it fetches is what the click will load, because that is the only copy
// the click can reuse:
//
//   - At `sm` and wider a plain click opens the drawer, which loads the row's
//     drawer url (`data-session-drawer-url`) as a Turbo Frame. That url is
//     prefetched with the frame's `Turbo-Frame` header, since the server keys the
//     cached copy on it (Vary: Turbo-Frame).
//   - Below `sm` the drawer declines and the link navigates to the full page, so
//     the link's own href is prefetched, with no frame header.
//   - A reader who opens sessions in new tabs (⌘/Ctrl/Shift-click, middle-click)
//     gets the full page prefetched too, after every drawer url. That second
//     pass doubles the requests, so it is only made for a browser that has
//     opened a session from a list that way in the last fortnight.
//
// The server answers a prefetch (`X-Sec-Purpose: prefetch`) with
// `Cache-Control: private, max-age=120` and records nothing: no notification is
// marked read, no view is counted. The page shown from that copy does both when
// it is actually opened (session_activation_controller). Fetching here only
// fills the HTTP cache — no document is built, so no socket opens and no panel
// loads until a click.
//
// Every prefetch is a full detail render on a web server with three threads,
// which also serve the agents' MCP calls. So the load is kept small on purpose:
//   - only rows on screen or within a screen of it are fetched, not the whole
//     list (a board can hold hundreds);
//   - one request at a time, top row first, and nothing until the page has
//     loaded and the browser is idle;
//   - opening the drawer aborts the request in flight and holds the queue, so
//     the session being read has the server to itself;
//   - nothing on Save-Data, a 2G connection, or a hidden tab;
//   - a url fetched in the last FRESH_MS is not fetched again — that memory is
//     module-level, so it survives Turbo visits back to the dashboard;
//   - a dashboard nobody is using does not refresh itself. A row a broadcast
//     re-renders is fetched only if it never was; expired copies are fetched
//     again when the tab comes back into view or the reader moves, and hovering
//     a row with a mouse moves it to the front.
const FRESH_MS = 100 * 1000 // under the server's max-age=120, so a "fresh" url is still in the cache
const ACCEPT = "text/html, application/xhtml+xml" // what Turbo sends for a frame load or a visit
const DRAWER_FRAME = "session_detail"
const SM_BREAKPOINT = 640 // session_drawer_controller's: below it, View navigates instead
const NEAR_SCREEN_MARGIN = "100% 0px" // a screen above and below the viewport
const NEW_TAB_KEY = "zimmer:session-prefetch:new-tab-at"
const NEW_TAB_MEMORY_MS = 14 * 24 * 60 * 60 * 1000

const fetchedAt = new Map()

function isFresh(url) {
  const at = fetchedAt.get(url)
  return at !== undefined && Date.now() - at < FRESH_MS
}

function whenIdle(callback) {
  const idle = () => {
    if (typeof window.requestIdleCallback === "function") {
      window.requestIdleCallback(callback, { timeout: 2000 })
    } else {
      setTimeout(callback, 200)
    }
  }
  if (document.readyState === "complete") idle()
  else window.addEventListener("load", idle, { once: true })
}

export default class extends Controller {
  static targets = ["link"]
  static values = { concurrency: { type: Number, default: 1 } }

  initialize() {
    this.queue = []
    this.inFlight = new Map() // url -> { entry, abortController }
    this.near = new Set()
    this.started = false
    this.paused = false
    this.lastSweepAt = 0
  }

  connect() {
    this.abortController = new AbortController()
    if (!this.allowed) return

    this.observer = new IntersectionObserver((entries) => this.handleIntersections(entries), {
      rootMargin: NEAR_SCREEN_MARGIN
    })
    for (const link of this.linkTargets) this.observer.observe(link)

    const options = { signal: this.abortController.signal }
    const passive = { ...options, passive: true }
    document.addEventListener("visibilitychange", () => this.handleVisible(), options)
    this.element.addEventListener("pointerover", (event) => this.handleHover(event), passive)
    this.element.addEventListener("click", (event) => this.noteNewTabIntent(event), { ...options, capture: true })
    this.element.addEventListener("auxclick", (event) => this.noteNewTabIntent(event), { ...options, capture: true })
    for (const type of ["pointermove", "keydown", "scroll"]) {
      window.addEventListener(type, () => this.sweepIfStale(), passive)
    }

    whenIdle(() => {
      if (this.abortController.signal.aborted) return
      this.started = true
      this.sweep()
    })
  }

  disconnect() {
    this.abortController.abort()
    this.observer?.disconnect()
    for (const { abortController } of this.inFlight.values()) abortController.abort()
    this.inFlight.clear()
    this.queue = []
    this.near.clear()
    this.started = false
  }

  linkTargetConnected(link) {
    this.observer?.observe(link)
  }

  linkTargetDisconnected(link) {
    this.observer?.unobserve(link)
    this.near.delete(link)
    this.queue = this.queue.filter((entry) => entry.link !== link)
  }

  // A row coming near the screen is fetched unless its copy is still fresh. A
  // row a broadcast re-rendered arrives here as a new element; it is fetched
  // only if its url never was, so a busy session does not cost a render per
  // broadcast on a dashboard nobody is touching.
  handleIntersections(entries) {
    for (const { target, isIntersecting } of entries) {
      if (isIntersecting) {
        this.near.add(target)
        if (this.started) this.enqueue(target, { onlyIfNeverFetched: true })
      } else {
        this.near.delete(target)
        this.queue = this.queue.filter((entry) => entry.link !== target)
      }
    }
  }

  // session-drawer dispatches these on the same element. The request in flight
  // is aborted and goes back to the front of the queue.
  pause() {
    this.paused = true
    for (const [url, { entry, abortController }] of this.inFlight) {
      abortController.abort()
      this.inFlight.delete(url)
      this.push(entry, { front: true })
    }
  }

  resume() {
    this.paused = false
    this.pump()
  }

  sweep() {
    this.lastSweepAt = Date.now()
    for (const link of this.linkTargets) {
      if (!this.near.has(link)) continue
      for (const entry of this.requestsFor(link)) this.push(entry)
    }
    this.pump()
  }

  sweepIfStale() {
    if (this.started && Date.now() - this.lastSweepAt >= FRESH_MS) this.sweep()
  }

  // The pump is deferred a tick, so that a board's worth of rows arriving in one
  // render are all queued — and so ordered by tier — before any is fetched.
  enqueue(link, { front = false, onlyIfNeverFetched = false } = {}) {
    for (const entry of this.requestsFor(link)) {
      if (onlyIfNeverFetched && fetchedAt.has(entry.url)) continue
      this.push(entry, { front })
    }
    if (front) {
      this.pump()
    } else if (!this.pumpScheduled) {
      this.pumpScheduled = true
      setTimeout(() => {
        this.pumpScheduled = false
        this.pump()
      }, 0)
    }
  }

  // Two tiers: what a click will load (0) always goes ahead of the new-tab
  // pass's full pages (1), wherever in the list a row turns up. `front` (a
  // hovered row) jumps both.
  push(entry, { front = false } = {}) {
    if (isFresh(entry.url) || this.inFlight.has(entry.url)) return
    const queued = this.queue.findIndex((other) => other.url === entry.url)
    if (queued !== -1) {
      if (!front) return
      this.queue.splice(queued, 1)
    }
    if (front) {
      this.queue.unshift(entry)
      return
    }
    const firstLater = this.queue.findIndex((other) => other.tier > entry.tier)
    if (firstLater === -1) this.queue.push(entry)
    else this.queue.splice(firstLater, 0, entry)
  }

  // What a click on this link will load, first; then, for a new-tab reader on a
  // drawer-sized screen, the full page too.
  requestsFor(link) {
    const drawerUrl = link.dataset.sessionDrawerUrl
    if (!this.drawerViewport || !drawerUrl) return [{ link, url: link.href, frame: null, tier: 0 }]

    const drawer = { link, url: new URL(drawerUrl, window.location.href).href, frame: DRAWER_FRAME, tier: 0 }
    return this.opensNewTabs ? [drawer, { link, url: link.href, frame: null, tier: 1 }] : [drawer]
  }

  pump() {
    if (!this.started || this.paused || document.visibilityState !== "visible") return

    while (this.inFlight.size < this.concurrencyValue && this.queue.length > 0) {
      const entry = this.queue.shift()
      if (isFresh(entry.url) || this.inFlight.has(entry.url)) continue
      this.prefetch(entry)
    }
  }

  async prefetch(entry) {
    const abortController = new AbortController()
    this.inFlight.set(entry.url, { entry, abortController })
    const headers = { Accept: ACCEPT, "X-Sec-Purpose": "prefetch" }
    if (entry.frame) headers["Turbo-Frame"] = entry.frame

    let aborted = false
    try {
      // `reload`: always ask the server and store what it answers. A refetch of
      // an expiring copy answered from the cache would leave the copy to expire
      // on its old clock while this one counted it fresh.
      const response = await fetch(entry.url, {
        headers,
        credentials: "same-origin",
        cache: "reload",
        priority: "low",
        signal: abortController.signal
      })
      // The cache only keeps a response it has read to the end.
      await response.blob()
    } catch (_error) {
      // Aborted (the drawer opened, or the page went away) or offline. An abort
      // is not remembered — pause() has already put the entry back — but a
      // failure is, so a failing url is not retried in a tight loop.
      aborted = abortController.signal.aborted
    } finally {
      if (this.inFlight.get(entry.url)?.abortController === abortController) this.inFlight.delete(entry.url)
      if (!aborted) fetchedAt.set(entry.url, Date.now())
      this.pump()
    }
  }

  handleVisible() {
    if (document.visibilityState !== "visible") return
    this.sweepIfStale()
    this.pump()
  }

  // Hovering a row with a mouse is the best hint of the next click there is. A
  // tap fires pointerover too, an instant before the navigation it starts; that
  // one would only race the click for the same render.
  handleHover(event) {
    if (!this.started || event.pointerType !== "mouse") return
    const link = event.target.closest?.("[data-session-prefetch-target~='link']")
    if (link && this.element.contains(link)) this.enqueue(link, { front: true })
  }

  noteNewTabIntent(event) {
    const link = event.target.closest?.("[data-session-prefetch-target~='link']")
    if (!link) return
    const newTab = event.button === 1 || event.metaKey || event.ctrlKey || event.shiftKey
    if (!newTab) return
    try {
      localStorage.setItem(NEW_TAB_KEY, String(Date.now()))
    } catch (_e) {
      // Private mode: the full-page pass just stays off.
    }
  }

  get opensNewTabs() {
    try {
      const at = Number(localStorage.getItem(NEW_TAB_KEY))
      return at > 0 && Date.now() - at < NEW_TAB_MEMORY_MS
    } catch (_e) {
      return false
    }
  }

  get drawerViewport() {
    return window.innerWidth >= SM_BREAKPOINT
  }

  get allowed() {
    if (typeof IntersectionObserver !== "function") return false
    const connection = navigator.connection
    if (connection?.saveData) return false
    if (/(^|-)2g$/.test(connection?.effectiveType || "")) return false
    if (window.matchMedia?.("(prefers-reduced-data: reduce)").matches) return false
    return true
  }
}
