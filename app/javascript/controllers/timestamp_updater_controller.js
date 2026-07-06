import { Controller } from "@hotwired/stimulus"

// Updates relative timestamps (e.g., "5 minutes ago") every minute
export default class extends Controller {
  connect() {
    this.updateTimestamp()
    // Update every 60 seconds
    this.interval = setInterval(() => {
      this.updateTimestamp()
    }, 60000)
  }

  disconnect() {
    if (this.interval) {
      clearInterval(this.interval)
    }
  }

  updateTimestamp() {
    const timestamp = this.element.dataset.timestamp
    if (!timestamp) return

    const date = new Date(timestamp)
    const now = new Date()
    const seconds = Math.floor((now - date) / 1000)

    let timeAgo
    if (seconds < 60) {
      timeAgo = "less than a minute"
    } else if (seconds < 3600) {
      const minutes = Math.floor(seconds / 60)
      timeAgo = `${minutes} ${minutes === 1 ? 'minute' : 'minutes'}`
    } else if (seconds < 86400) {
      const hours = Math.floor(seconds / 3600)
      timeAgo = `${hours} ${hours === 1 ? 'hour' : 'hours'}`
    } else if (seconds < 2592000) {
      const days = Math.floor(seconds / 86400)
      timeAgo = `${days} ${days === 1 ? 'day' : 'days'}`
    } else if (seconds < 31536000) {
      const months = Math.floor(seconds / 2592000)
      timeAgo = `${months} ${months === 1 ? 'month' : 'months'}`
    } else {
      const years = Math.floor(seconds / 31536000)
      timeAgo = `${years} ${years === 1 ? 'year' : 'years'}`
    }

    this.element.textContent = `${timeAgo} ago`
  }
}
