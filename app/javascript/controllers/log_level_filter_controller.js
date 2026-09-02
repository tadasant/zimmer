import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="log-level-filter"
export default class extends Controller {
  static targets = ["select", "timeline"]
  static values = {
    level: { type: String, default: "minimal" },
    serverFilter: { type: String, default: "minimal" }
  }

  connect() {
    // Check whether the address this body was rendered from already carries an
    // explicit filter param (see `filterOrigin` — that address is NOT always the
    // document's).
    const origin = this.filterOrigin
    const urlFilter = origin.url ? origin.url.searchParams.get('filter') : null

    // If no filter param, check localStorage for user's preference and re-fetch
    // with it (so the server can filter properly)
    if (!urlFilter) {
      const savedLevel = localStorage.getItem('logLevelFilter')
      if (savedLevel && savedLevel !== this.serverFilterValue && this.refetchAtLevel(savedLevel)) {
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
    if (this.refetchAtLevel(newLevel)) return

    // Nothing addressable to re-fetch (see `filterOrigin`). Fall back to hiding
    // and showing the items already in the DOM, so the select still does
    // something rather than nothing.
    this.levelValue = newLevel
    this.filter()
  }

  // Where this detail body came from, and therefore what has to be re-fetched to
  // change its filter. The body renders in two places, at two different
  // addresses:
  //
  //   - the full session page (/sessions/:id), which is the document itself; and
  //   - the dashboard's right-side drawer, where it is lazy-loaded into
  //     <turbo-frame id="session_detail"> from /sessions/:id/drawer.
  //
  // Inside the drawer `window.location` is the DASHBOARD, not the session, so
  // filtering through it navigated the whole page to /?filter=<level> — a param
  // that means nothing there — dismissing the drawer and losing the reader's
  // place (#666). The enclosing frame's own `src` is the session's address, so
  // that is what the drawer re-fetches. `closest("turbo-frame")` returns null on
  // the full page, which is how the document branch is selected.
  //
  // Returns { frame, url }: `frame` is null on the full page, and `url` is null
  // only for the degenerate case of a frame with no `src` — a body that is not
  // in the document and has no address of its own either. Navigating the
  // document from there would be the very bug this replaces, so it reports "no
  // origin" and the callers fall back to client-side filtering.
  get filterOrigin() {
    const frame = this.element.closest("turbo-frame")
    if (!frame) return { frame: null, url: new URL(window.location.href) }

    // Turbo's FrameElement#src is a plain attribute passthrough, so it can be a
    // relative path — resolve it against the document.
    const src = frame.getAttribute("src")
    return { frame, url: src ? new URL(src, window.location.href) : null }
  }

  // Re-fetch this detail body at `level`, addressing whichever of the two
  // origins above applies. Returns true when a fetch was started (the caller's
  // DOM is on its way out), false when there was nothing to address.
  refetchAtLevel(level) {
    const { frame, url } = this.filterOrigin
    if (!url) return false

    url.searchParams.set('filter', level)

    if (frame) {
      // Setting `src` is a real Turbo Frame navigation: the response's matching
      // frame is swapped in, so only the drawer's contents change and the
      // dashboard behind it — scroll position, open drawer and all — is left
      // alone.
      frame.src = url.toString()
    } else {
      window.location.href = url.toString()
    }
    return true
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
