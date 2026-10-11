import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="infinite-scroll"
// Handles loading older timeline items when scrolling to the top
//
// This controller implements "reverse infinite scroll" - loading older items
// when the user scrolls up. The primary goal is improving browser performance
// by limiting initial DOM size for sessions with many messages.
//
// Tail first: the transcript panel renders only the newest handful of items
// (SessionsController::TRANSCRIPT_TAIL_LIMIT). The moment that tail is in the
// DOM this controller prefetches a short page before it, in the background, so
// a reader who scrolls up finds it already there — and only then asks for the
// filtered total, which the tail does not compute and the prefetch must not
// wait on.
//
// Filter-aware counting:
// This controller works with the log-level-filter controller to show accurate
// item counts based on the current filter level. Items have a data-filter-category
// attribute ("message", "regular-log", or "verbose-log") that determines visibility.
export default class extends Controller {
  // How many earlier items the post-tail prefetch brings: "slightly earlier",
  // enough to scroll up through without waiting, small enough to stay cheap.
  // Pages after it are the server's default size.
  static PREFETCH_LIMIT = 40

  static targets = ["loadMoreTrigger", "loadMoreButton", "timelineContent", "loadingIndicator", "itemsCount"]
  static values = {
    url: String,
    beforeTimestamp: { type: String, default: "" },
    // The transcript line the next backward read starts below. A hint, not the
    // boundary — the timestamp is that — so a blank one only costs the server a
    // read from the end.
    beforeLine: { type: String, default: "" },
    hasMore: Boolean,
    loading: { type: Boolean, default: false },
    // 0 until a page has reported it: the tail does not count.
    totalCount: Number,
    filterLevel: { type: String, default: "minimal" }
  }

  connect() {
    // Track connection state to prevent observer setup after disconnect
    this.isConnected = true

    // The filter level is now passed from the server via data attribute
    // (data-infinite-scroll-filter-level-value), so we don't need to load
    // from localStorage here. The server filters items before pagination.

    // Initial count update based on current filter
    // Use requestAnimationFrame to ensure the DOM is ready
    requestAnimationFrame(() => this.recountVisibleItems())

    // Delay setting up the IntersectionObserver to avoid triggering immediately on page load.
    // The session_scroll_controller scrolls to bottom using double requestAnimationFrame,
    // so we need to wait until after that scroll completes before observing.
    // Using triple requestAnimationFrame ensures the scroll has completed.
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        requestAnimationFrame(() => {
          // Check connection state to prevent observer setup after disconnect
          if (this.isConnected) {
            this.setupIntersectionObserver()
          }
        })
      })
    })

    this.prefetchEarlier()
  }

  // Fetch the page before the tail once the browser is idle — after the tail has
  // painted, never ahead of it. Whatever the reader does first (opening the
  // panel, scrolling up, following a #message-N link) finds either the page
  // already in place or this request already in flight, and loadMore's
  // in-flight guard keeps the two from doubling up.
  prefetchEarlier() {
    if (!this.hasMoreValue) return

    const run = async () => {
      if (!this.isConnected) return

      await this.loadMore({ limit: this.constructor.PREFETCH_LIMIT })
      if (this.isConnected) this.fetchTotal()
    }
    if ("requestIdleCallback" in window) {
      window.requestIdleCallback(run, { timeout: 500 })
    } else {
      setTimeout(run, 0)
    }
  }

  disconnect() {
    this.isConnected = false
    if (this.intersectionObserver) {
      this.intersectionObserver.disconnect()
    }
  }

  setupIntersectionObserver() {
    // Use intersection observer on the load more trigger element
    // This fires when the element becomes visible in the viewport
    const options = {
      root: null, // use viewport
      rootMargin: "200px 0px 0px 0px", // trigger 200px before reaching the element
      threshold: 0
    }

    this.intersectionObserver = new IntersectionObserver((entries) => {
      entries.forEach(entry => {
        if (entry.isIntersecting && this.hasMoreValue && !this.loadingValue) {
          this.loadMore()
        }
      })
    }, options)

    if (this.hasLoadMoreTriggerTarget) {
      this.intersectionObserver.observe(this.loadMoreTriggerTarget)
    }
  }

  // Load the page before the oldest item on screen.
  //
  // `throughIndex` asks for every item back to that transcript index in one
  // response, however many that is — what a `#message-N` link older than the
  // loaded history needs (transcript-panel#reveal). Resolves once the batch is
  // in the DOM; a call made while another is in flight waits for that one
  // instead of issuing its own.
  async loadMore({ throughIndex = null, limit = null } = {}) {
    if (this.inFlight) return this.inFlight
    if (!this.hasMoreValue || !this.beforeTimestampValue) return

    this.inFlight = this.fetchEarlier(throughIndex, limit)
    try {
      await this.inFlight
    } finally {
      this.inFlight = null
    }
  }

  // Load until transcript index `index` is in the DOM, or there is nothing
  // older to load. Usually one request — through_index makes the server read
  // back to it — and a second only when the first was already in flight.
  async loadThrough(index) {
    while (this.hasMoreValue && !this.isIndexLoaded(index)) {
      const before = this.beforeTimestampValue
      await this.loadMore({ throughIndex: index })
      if (this.beforeTimestampValue === before) return
    }
  }

  // True when the oldest transcript row on screen is at or before `index`.
  isIndexLoaded(index) {
    if (!this.hasTimelineContentTarget) return false

    const first = this.timelineContentTarget.querySelector("[data-transcript-index]")
    return first !== null && parseInt(first.dataset.transcriptIndex, 10) <= index
  }

  // The filtered total the tail did not compute. Best effort: until it lands,
  // or if it never does, the count reads "Showing latest N items".
  async fetchTotal() {
    if (this.totalCountValue || !this.hasMoreValue) return

    try {
      const url = new URL(this.urlValue, window.location.origin)
      url.searchParams.set("total_only", "1")
      url.searchParams.set("filter", this.filterLevelValue)
      const response = await fetch(url, { headers: { "Accept": "text/html", "X-Requested-With": "XMLHttpRequest" } })
      if (!response.ok) return

      const state = new DOMParser().parseFromString(await response.text(), "text/html").querySelector("#timeline-pagination-state")
      if (state && state.dataset.totalCount) {
        this.totalCountValue = parseInt(state.dataset.totalCount, 10)
        this.updateItemsCount()
      }
    } catch (error) {
      console.error("Error loading the timeline total:", error)
    }
  }

  async fetchEarlier(throughIndex, limit) {
    this.loadingValue = true
    this.showLoadingIndicator()

    try {
      const url = new URL(this.urlValue, window.location.origin)
      url.searchParams.set("before_timestamp", this.beforeTimestampValue)
      if (this.beforeLineValue !== "") url.searchParams.set("before_line", this.beforeLineValue)
      if (throughIndex !== null) url.searchParams.set("through_index", throughIndex)
      if (limit !== null) url.searchParams.set("limit", limit)
      // Pass the current filter level to the server so it can filter before limiting
      url.searchParams.set("filter", this.filterLevelValue)

      const response = await fetch(url, {
        headers: {
          "Accept": "text/html",
          "X-Requested-With": "XMLHttpRequest"
        }
      })

      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}`)
      }

      const html = await response.text()

      // Parse the response to extract items and pagination state
      const tempDiv = document.createElement("div")
      tempDiv.innerHTML = html

      // Extract pagination state
      const paginationState = tempDiv.querySelector("#timeline-pagination-state")
      if (paginationState) {
        this.hasMoreValue = paginationState.dataset.hasMore === "true"
        this.beforeTimestampValue = paginationState.dataset.nextBeforeTimestamp || ""
        this.beforeLineValue = paginationState.dataset.nextBeforeLine || ""
        // Remove the pagination state element from the content to insert
        paginationState.remove()
      }

      // Remember the scroll position just before inserting, not when the request
      // went out: a prefetch runs in the background, and a reader may have
      // scrolled anywhere while it was in flight.
      const scrollContainer = document.documentElement
      const oldScrollHeight = scrollContainer.scrollHeight
      const oldScrollTop = window.scrollY

      // Insert new items AFTER the loadMoreTrigger and loadingIndicator elements.
      // This is critical for continued infinite scroll - if we prepend to innerHTML,
      // the trigger elements get buried in the middle and the IntersectionObserver
      // won't fire on subsequent scrolls to the top.
      if (this.hasTimelineContentTarget) {
        // Find the insertion point: after loadingIndicator or loadMoreTrigger
        const loadingIndicator = this.hasLoadingIndicatorTarget ? this.loadingIndicatorTarget : null
        const loadMoreTrigger = this.hasLoadMoreTriggerTarget ? this.loadMoreTriggerTarget : null

        // The insertion point is after the loading indicator (if present), otherwise after the trigger
        const insertAfter = loadingIndicator || loadMoreTrigger

        if (insertAfter) {
          // Insert new content after the trigger/loading elements
          insertAfter.insertAdjacentHTML("afterend", tempDiv.innerHTML)
        } else {
          // Fallback: if no trigger elements, prepend to the container
          this.timelineContentTarget.insertAdjacentHTML("afterbegin", tempDiv.innerHTML)
        }
      }

      // Update displayed count based on items loaded
      // Note: We'll recount all visible items after filter is applied

      // Restore scroll position so user stays at the same content
      // Use requestAnimationFrame to wait for layout to settle
      // A batch landing in a closed panel adds no height, and then there is
      // nothing to restore — leave the reader's scroll alone.
      requestAnimationFrame(() => {
        const newScrollHeight = scrollContainer.scrollHeight
        const scrollDiff = newScrollHeight - oldScrollHeight
        if (scrollDiff !== 0) window.scrollTo(0, oldScrollTop + scrollDiff)
      })

      // Update the "Load more" button visibility
      this.updateLoadMoreVisibility()

      // Update item count display if present
      this.updateItemsCount()

      // Apply log level filter to newly loaded content, then recount
      this.applyLogLevelFilter()

      // Recount visible items after filter is applied
      this.recountVisibleItems()

    } catch (error) {
      console.error("Error loading more timeline items:", error)
      this.showErrorMessage("Failed to load earlier messages. Please try again.")
    } finally {
      this.loadingValue = false
      this.hideLoadingIndicator()
    }
  }

  showLoadingIndicator() {
    if (this.hasLoadingIndicatorTarget) {
      this.loadingIndicatorTarget.classList.remove("hidden")
    }
    if (this.hasLoadMoreButtonTarget) {
      this.loadMoreButtonTarget.disabled = true
    }
  }

  hideLoadingIndicator() {
    if (this.hasLoadingIndicatorTarget) {
      this.loadingIndicatorTarget.classList.add("hidden")
    }
    if (this.hasLoadMoreButtonTarget) {
      this.loadMoreButtonTarget.disabled = false
    }
  }

  updateLoadMoreVisibility() {
    if (this.hasLoadMoreTriggerTarget) {
      if (this.hasMoreValue) {
        this.loadMoreTriggerTarget.classList.remove("hidden")
      } else {
        this.loadMoreTriggerTarget.classList.add("hidden")
      }
    }
  }

  updateItemsCount() {
    if (this.hasItemsCountTarget) {
      const { visibleLoaded, visibleTotal, hasMoreVisible } = this.getFilteredCounts()

      if (hasMoreVisible && !this.totalCountValue) {
        this.itemsCountTarget.textContent = `Showing latest ${visibleLoaded} items`
      } else if (hasMoreVisible) {
        this.itemsCountTarget.textContent = `Showing ${visibleLoaded} of ${visibleTotal} items`
      } else {
        this.itemsCountTarget.textContent = `${visibleTotal} ${visibleTotal === 1 ? "item" : "items"}`
      }
    }
  }

  // Get counts based on the current filter level
  // Now that the server filters items before pagination, counts are accurate.
  // Returns { visibleLoaded, visibleTotal, hasMoreVisible }
  getFilteredCounts() {
    if (!this.hasTimelineContentTarget) {
      return { visibleLoaded: 0, visibleTotal: 0, hasMoreVisible: false }
    }

    // Count all loaded items (server already filtered them)
    const allLoadedItems = this.timelineContentTarget.querySelectorAll("[data-timeline-item]")
    const visibleLoaded = allLoadedItems.length

    // Total count is the filtered total from the server
    const visibleTotal = this.totalCountValue || visibleLoaded

    // hasMoreValue from server indicates if there are more filtered items to load
    const hasMoreVisible = this.hasMoreValue

    return { visibleLoaded, visibleTotal, hasMoreVisible }
  }

  // Check if an item should be visible for the given filter level
  isItemVisibleForFilter(item, filterLevel) {
    const category = item.dataset.filterCategory

    if (filterLevel === "minimal") {
      // Only regular messages are visible (not tool-use/result, not queue events)
      return category === "message"
    } else if (filterLevel === "condensed") {
      // All messages (including tool-use/result and queue events) are visible, no logs
      return category === "message" || category === "tool-message" || category === "queue-event"
    } else if (filterLevel === "show-logs") {
      // All messages and regular logs are visible
      return category === "message" || category === "tool-message" || category === "queue-event" || category === "regular-log"
    } else {
      // Verbose: everything is visible
      return true
    }
  }

  // Recount all visible items and update the display
  // Called when filter changes or new items are loaded
  recountVisibleItems() {
    this.updateItemsCount()
  }

  // Called by log-level-filter controller when filter changes
  onFilterChange(newLevel) {
    this.filterLevelValue = newLevel
    this.recountVisibleItems()
  }

  // Trigger log level filter to apply to newly loaded content
  applyLogLevelFilter() {
    const filterController = this.application.getControllerForElementAndIdentifier(
      document.querySelector("[data-controller~='log-level-filter']"),
      "log-level-filter"
    )
    if (filterController && typeof filterController.filter === "function") {
      filterController.filter()
    }
  }

  showErrorMessage(message) {
    // Create a temporary error banner at the top of the timeline
    const errorDiv = document.createElement("div")
    errorDiv.className = "px-6 py-3 text-center bg-red-50 text-red-700 text-sm border-b border-red-100"
    errorDiv.textContent = message
    errorDiv.setAttribute("role", "alert")

    if (this.hasTimelineContentTarget) {
      this.timelineContentTarget.insertBefore(errorDiv, this.timelineContentTarget.firstChild)

      // Auto-remove after 5 seconds
      setTimeout(() => {
        errorDiv.remove()
      }, 5000)
    }
  }

  // Manual trigger for the "Load more" button click
  loadMoreClicked(event) {
    event.preventDefault()
    this.loadMore()
  }
}
