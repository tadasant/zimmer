import { Controller } from "@hotwired/stimulus"

// Ticks the Account Pool's "work unblocked in" clock down to an absolute moment.
//
// The deadline ships as an ISO-8601 instant rather than a remaining duration,
// because /quotas is a page people leave open. A server-rendered "in 22m" is
// right for one second and wrong for every second after it; the instant stays
// true, and this recomputes the wait from it every second.
//
// The server renders the same clock string from the same instant (see
// QuotasHelper#countdown_clock_text), so the first paint is already correct and
// nothing jumps when this connects — and the value is still right if JavaScript
// never runs at all.
//
// Usage:
//   <div data-controller="unblock-countdown"
//        data-unblock-countdown-deadline-value="2026-08-20T18:30:00Z">
//     <p data-unblock-countdown-target="label">Work unblocked in</p>
//     <p data-unblock-countdown-target="remaining">21:59</p>
//     <p data-unblock-countdown-target="passed" hidden>…</p>
//   </div>
export default class extends Controller {
  static targets = ["label", "remaining", "passed"]
  static values = { deadline: String }

  connect() {
    this.deadline = new Date(this.deadlineValue)
    // An unparseable deadline leaves the server's text alone rather than
    // replacing it with "NaN:NaN".
    if (isNaN(this.deadline.getTime())) return

    this.tick()
    this.interval = setInterval(() => this.tick(), 1000)
  }

  disconnect() {
    this.stop()
  }

  tick() {
    const remaining = Math.floor((this.deadline - new Date()) / 1000)

    if (remaining <= 0) {
      this.expire()
      return
    }

    const text = this.constructor.clockText(remaining)
    // The seconds change every tick, so this only saves a write on a repaint —
    // but it keeps the element untouched when nothing about it changed.
    if (text === this.previousText) return

    this.remainingTarget.textContent = text
    this.previousText = text
  }

  // The deadline is behind us. The page cannot know what the next probe will
  // read, so it says the moment passed rather than freezing on 0:00 — or, worse,
  // counting up into a negative wait.
  expire() {
    this.remainingTarget.textContent = "now"
    if (this.hasLabelTarget) this.labelTarget.textContent = "Work unblocked"
    if (this.hasPassedTarget) this.passedTarget.hidden = false
    this.stop()
  }

  stop() {
    if (this.interval) clearInterval(this.interval)
    this.interval = null
  }

  // "4:31" under an hour, "2:04:31" under a day, "1d 02:04:31" beyond it. The
  // Ruby side renders the identical string for the first paint.
  static clockText(totalSeconds) {
    const days = Math.floor(totalSeconds / 86400)
    const hours = Math.floor((totalSeconds % 86400) / 3600)
    const minutes = Math.floor((totalSeconds % 3600) / 60)
    const seconds = totalSeconds % 60
    const pad = (value) => String(value).padStart(2, "0")

    if (days > 0) return `${days}d ${pad(hours)}:${pad(minutes)}:${pad(seconds)}`
    if (hours > 0) return `${hours}:${pad(minutes)}:${pad(seconds)}`

    return `${minutes}:${pad(seconds)}`
  }
}
