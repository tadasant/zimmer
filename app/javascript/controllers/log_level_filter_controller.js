import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="log-level-filter"
export default class extends Controller {
  static targets = ["select", "timeline"]
  static values = {
    level: { type: String, default: "minimal" },
    serverFilter: { type: String, default: "minimal" }
  }

  connect() {
    // Does the address this body was rendered from already carry an explicit
    // filter param? That address is not always the document's — see filterOrigin.
    const origin = this.filterOrigin
    const urlFilter = origin.url.searchParams.get('filter')

    // If no filter param, check localStorage for user's preference and re-fetch
    // with it (so the server can filter properly)
    if (!urlFilter) {
      const savedLevel = localStorage.getItem('logLevelFilter')
      if (savedLevel && savedLevel !== this.serverFilterValue) {
        this.refetchAtLevel(savedLevel, origin)
        return // Don't continue setup — this DOM is being replaced
      }
    }

    // The filter level is now determined server-side and passed via URL param.
    // The server sets the select value via the 'selected' attribute, so we just
    // read the current value from the select element.
    this.levelValue = this.selectTarget.value

    // Update localStorage to match the current filter (from URL or default)
    localStorage.setItem('logLevelFilter', this.levelValue)

    // No need to apply client-side filtering on initial load since server
    // already filtered the items. However, we still need the MutationObserver
    // for Turbo Stream updates (new items added in real-time).
    this.observer = new MutationObserver((mutations) => {
      // Check if any mutations added nodes
      const hasNewNodes = mutations.some(mutation => mutation.addedNodes.length > 0)
      if (hasNewNodes) {
        // Apply filter to newly added items from Turbo Streams
        this.filter()
      }
    })

    // Observe the timeline for child node additions
    this.observer.observe(this.timelineTarget, {
      childList: true,
      subtree: true
    })
  }

  disconnect() {
    // Clean up observer when controller is disconnected
    if (this.observer) {
      this.observer.disconnect()
    }
  }

  change(event) {
    const newLevel = event.target.value
    localStorage.setItem('logLevelFilter', newLevel)

    // Changing the filter needs fresh server-side filtered data: the server
    // filters items before pagination, so a new level means re-fetching with the
    // new filter parameter.
    this.refetchAtLevel(newLevel)
  }

  // The address this detail body was rendered from, and therefore the thing that
  // has to be re-fetched to change its filter. Two cases, told apart by the
  // enclosing frame's `src`:
  //
  //   - **A frame carrying a `src`** was lazy-loaded from that address into some
  //     other document. That is the dashboard's session drawer, where
  //     `window.location` is the DASHBOARD rather than the session — so filtering
  //     through the document navigates the whole page to /?filter=<level>, a
  //     param that means nothing there, and dismisses the drawer along with the
  //     reader's place (#666). The frame's own `src` is the session's address.
  //   - **No frame, or a frame with no `src`**, was server-rendered as part of
  //     this document, so the document's address is the body's address too. That
  //     covers the full session page (/sessions/:id, no frame at all) and
  //     /sessions/:id/drawer opened directly (a bare frame, which #drawer renders
  //     without a `src`).
  //
  // Returns { frame, url }; `frame` is null whenever the document is the thing to
  // navigate.
  get filterOrigin() {
    const frame = this.element.closest('turbo-frame')
    // Turbo's FrameElement#src is a plain attribute passthrough, so it hands back
    // whatever string was set — often a relative path. Resolve against the document.
    const src = frame && frame.getAttribute('src')
    if (!src) return { frame: null, url: new URL(window.location.href) }

    return { frame, url: new URL(src, window.location.href) }
  }

  // Re-fetch this detail body at `level`, addressing whichever of the two origins
  // above applies. The caller's DOM is on its way out once this returns.
  refetchAtLevel(level, origin = this.filterOrigin) {
    const { frame, url } = origin
    url.searchParams.set('filter', level)

    if (frame) {
      // Setting `src` is a real Turbo Frame navigation: the response's matching
      // frame is swapped in, so only the drawer's contents change and the
      // dashboard behind it — scroll position, open drawer and all — is left
      // alone. Turbo marks the frame `busy` for the round trip; the drawer styles
      // that (app/assets/tailwind/application.css) so the stale content reads as
      // stale, which the browser's own loading UI used to do for free.
      frame.src = url.toString()
    } else {
      window.location.href = url.toString()
    }
  }

  filter() {
    // Use data-filter-category attribute consistently for all filtering (single source of truth)
    const toolMessages = this.timelineTarget.querySelectorAll('[data-filter-category="tool-message"]')
    const queueEvents = this.timelineTarget.querySelectorAll('[data-filter-category="queue-event"]')
    const regularLogs = this.timelineTarget.querySelectorAll('[data-filter-category="regular-log"]')
    const verboseLogs = this.timelineTarget.querySelectorAll('[data-filter-category="verbose-log"]')

    if (this.levelValue === 'minimal') {
      // Hide tool messages, queue events, and all logs — only show user/assistant messages
      toolMessages.forEach(msg => msg.style.display = 'none')
      queueEvents.forEach(msg => msg.style.display = 'none')
      regularLogs.forEach(log => log.style.display = 'none')
      verboseLogs.forEach(log => log.style.display = 'none')
    } else if (this.levelValue === 'condensed') {
      // Show all messages (including tool use/result and queue events), hide all logs
      toolMessages.forEach(msg => msg.style.display = '')
      queueEvents.forEach(msg => msg.style.display = '')
      regularLogs.forEach(log => log.style.display = 'none')
      verboseLogs.forEach(log => log.style.display = 'none')
    } else if (this.levelValue === 'show-logs') {
      // Show all messages and regular logs, hide verbose logs
      toolMessages.forEach(msg => msg.style.display = '')
      queueEvents.forEach(msg => msg.style.display = '')
      regularLogs.forEach(log => log.style.display = '')
      verboseLogs.forEach(log => log.style.display = 'none')
    } else if (this.levelValue === 'verbose') {
      // Show everything
      toolMessages.forEach(msg => msg.style.display = '')
      queueEvents.forEach(msg => msg.style.display = '')
      regularLogs.forEach(log => log.style.display = '')
      verboseLogs.forEach(log => log.style.display = '')
    }
  }
}
