import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="log-level-filter"
export default class extends Controller {
  static targets = ["select", "timeline"]
  static values = {
    level: { type: String, default: "minimal" },
    serverFilter: { type: String, default: "minimal" }
  }

  connect() {
    // Check if URL has an explicit filter param
    const urlParams = new URLSearchParams(window.location.search)
    const urlFilter = urlParams.get('filter')

    // If no URL filter param, check localStorage for user's preference
    // and redirect to include it (so server can filter properly)
    if (!urlFilter) {
      const savedLevel = localStorage.getItem('logLevelFilter')
      if (savedLevel && savedLevel !== this.serverFilterValue) {
        // Redirect to include the saved preference
        const url = new URL(window.location.href)
        url.searchParams.set('filter', savedLevel)
        window.location.href = url.toString()
        return // Don't continue setup since we're redirecting
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

    // When the filter changes, we need to reload the page to get fresh server-side
    // filtered data. The server now filters items before pagination, so changing
    // filters requires re-fetching with the new filter parameter.
    const url = new URL(window.location.href)
    url.searchParams.set('filter', newLevel)
    window.location.href = url.toString()
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
