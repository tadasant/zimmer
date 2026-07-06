import { Controller } from "@hotwired/stimulus"

// Controller for the health dashboard auto-refresh functionality
// Connects to data-controller="health-dashboard"
export default class extends Controller {
  static targets = ["content", "lastUpdated", "autoRefreshStatus"]
  static values = {
    refreshInterval: { type: Number, default: 30000 } // 30 seconds
  }

  connect() {
    this.startAutoRefresh()
  }

  disconnect() {
    this.stopAutoRefresh()
  }

  startAutoRefresh() {
    if (this.refreshIntervalValue > 0) {
      this.refreshTimer = setInterval(() => {
        this.refresh()
      }, this.refreshIntervalValue)
    }
  }

  stopAutoRefresh() {
    if (this.refreshTimer) {
      clearInterval(this.refreshTimer)
      this.refreshTimer = null
    }
  }

  async refresh() {
    try {
      const response = await fetch("/health/refresh", {
        headers: {
          "Accept": "text/html",
          "X-Requested-With": "XMLHttpRequest"
        }
      })

      if (response.ok) {
        const html = await response.text()
        if (this.hasContentTarget) {
          this.contentTarget.innerHTML = html
        }
        this.updateLastUpdated()
      } else {
        console.error("Failed to refresh health data:", response.status)
      }
    } catch (error) {
      console.error("Error refreshing health data:", error)
    }
  }

  updateLastUpdated() {
    if (this.hasLastUpdatedTarget) {
      const now = new Date()
      const timeString = now.toLocaleTimeString("en-US", {
        hour12: false,
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit"
      })
      this.lastUpdatedTarget.textContent = timeString
    }
  }

  toggleAutoRefresh() {
    if (this.refreshTimer) {
      this.stopAutoRefresh()
      if (this.hasAutoRefreshStatusTarget) {
        this.autoRefreshStatusTarget.textContent = "(Auto-refresh: paused)"
      }
    } else {
      this.startAutoRefresh()
      if (this.hasAutoRefreshStatusTarget) {
        this.autoRefreshStatusTarget.textContent = `(Auto-refresh: ${this.refreshIntervalValue / 1000}s)`
      }
    }
  }
}
