import { Controller } from "@hotwired/stimulus"

// Displays compact time since a timestamp (e.g., "1m", "2h", "30m")
// Updates every second for real-time display
// Also updates parent badge color based on elapsed time:
// - Green: < 3 minutes (healthy/active)
// - Yellow: 3-10 minutes (potentially slow)
// - Red: 10+ minutes (potentially stalled)
//
// Usage: Add data-controller="time-since" to an element with data-timestamp.
// For badge color updates, add data-time-since-update-badge-color-value="true"
// and ensure a parent element has the data-running-badge attribute.
export default class extends Controller {
  static values = {
    updateBadgeColor: { type: Boolean, default: false }
  }

  // Time thresholds in minutes for color transitions
  static WARNING_THRESHOLD_MINUTES = 3
  static DANGER_THRESHOLD_MINUTES = 10

  // Color class definitions for badge states
  static COLOR_CLASSES = {
    green: { badge: ['bg-green-100', 'text-green-800'], spinner: 'text-green-600' },
    yellow: { badge: ['bg-yellow-100', 'text-yellow-800'], spinner: 'text-yellow-600' },
    red: { badge: ['bg-red-100', 'text-red-800'], spinner: 'text-red-600' }
  }

  connect() {
    // Cache the badge element reference for performance
    this.badgeElement = this.updateBadgeColorValue
      ? this.element.closest('[data-running-badge]')
      : null

    // Track previous values to avoid unnecessary DOM updates
    this.previousTimeString = null
    this.previousColorState = null

    this.updateTime()
    // Update every second for real-time display
    this.interval = setInterval(() => {
      this.updateTime()
    }, 1000)
  }

  disconnect() {
    if (this.interval) {
      clearInterval(this.interval)
    }
  }

  updateTime() {
    const timestamp = this.element.dataset.timestamp
    if (!timestamp) {
      this.element.textContent = "--"
      return
    }

    const date = new Date(timestamp)
    const now = new Date()
    const seconds = Math.floor((now - date) / 1000)

    const timeString = this.formatTimeString(seconds)

    // Only update DOM if value changed
    if (timeString !== this.previousTimeString) {
      this.element.textContent = timeString
      this.previousTimeString = timeString
    }

    // Update parent badge color if enabled
    if (this.updateBadgeColorValue && this.badgeElement) {
      this.updateBadgeColorBasedOnTime(seconds)
    }
  }

  formatTimeString(seconds) {
    if (seconds < 60) {
      // Less than 1 minute: show "<1m"
      return "<1m"
    } else if (seconds < 3600) {
      // Less than 1 hour: show minutes
      const minutes = Math.floor(seconds / 60)
      return `${minutes}m`
    } else if (seconds < 86400) {
      // Less than 1 day: show hours
      const hours = Math.floor(seconds / 3600)
      return `${hours}h`
    } else {
      // 1 day or more: show days
      const days = Math.floor(seconds / 86400)
      return `${days}d`
    }
  }

  updateBadgeColorBasedOnTime(seconds) {
    const minutes = seconds / 60

    // Determine color state based on thresholds
    let colorState
    if (minutes < this.constructor.WARNING_THRESHOLD_MINUTES) {
      colorState = 'green'
    } else if (minutes < this.constructor.DANGER_THRESHOLD_MINUTES) {
      colorState = 'yellow'
    } else {
      colorState = 'red'
    }

    // Only update DOM if color state changed
    if (colorState === this.previousColorState) return
    this.previousColorState = colorState

    const colors = this.constructor.COLOR_CLASSES
    const allBadgeClasses = [
      ...colors.green.badge,
      ...colors.yellow.badge,
      ...colors.red.badge
    ]
    const allSpinnerClasses = [
      colors.green.spinner,
      colors.yellow.spinner,
      colors.red.spinner
    ]

    // Update badge classes
    this.badgeElement.classList.remove(...allBadgeClasses)
    this.badgeElement.classList.add(...colors[colorState].badge)

    // Update spinner classes
    const spinner = this.badgeElement.querySelector('svg')
    if (spinner) {
      spinner.classList.remove(...allSpinnerClasses)
      spinner.classList.add(colors[colorState].spinner)
    }

    // Update aria-label for accessibility
    const ariaLabels = {
      green: 'Running - recently active',
      yellow: 'Running - no activity for several minutes',
      red: 'Running - no activity for extended period'
    }
    this.badgeElement.setAttribute('aria-label', ariaLabels[colorState])
  }
}
