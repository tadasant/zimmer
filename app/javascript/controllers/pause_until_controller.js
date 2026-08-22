import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="pause-until"
//
// "Pause Until": sleep a session now and either schedule a one-time trigger to
// wake it at a chosen time (the web-UI counterpart of the wake_me_up_later MCP
// tool — SessionsController#pause_until routes both through
// Sessions::ScheduleWakeUp) or hand it to the spot queue with no wake-up at all,
// which is the `mode: "spot_queue"` branch of the same endpoint.
//
// Every time this controller computes is a LOCAL time in the browser's zone, and
// it sends that naive wall-clock string alongside the zone's IANA name. Sending
// the naive value alone would let the server read it as UTC and silently offset
// every pause by the operator's UTC offset — and "Tomorrow, 9:00 AM" means the
// operator's morning, not the server's.
//
// Two layouts, one behaviour: `inline` renders the panel in normal flow (inside
// the session card's overflow menu, which is already a positioned box), anything
// else renders it as an absolute popover (the session detail header).
export default class extends Controller {
  static targets = ["button", "panel", "presetTime", "customInput", "promptInput", "status", "zone"]
  static values = {
    url: String,
    inline: Boolean
  }

  connect() {
    this._outsideClick = this._outsideClick.bind(this)
    this._onKeydown = this._onKeydown.bind(this)
  }

  disconnect() {
    document.removeEventListener("click", this._outsideClick)
    document.removeEventListener("keydown", this._onKeydown)
  }

  toggle(event) {
    event.preventDefault()
    event.stopPropagation()
    if (this.panelTarget.classList.contains("hidden")) {
      this._open()
    } else {
      this._close()
    }
  }

  choosePreset(event) {
    event.preventDefault()
    event.stopPropagation()
    const at = this._presetDate(event.currentTarget.dataset.preset)
    if (at) this._schedule(this._naiveLocal(at))
  }

  // The one choice that is not a time: sleep the session and hand it to the spot
  // queue, which arms no trigger at all. It shares the panel's "Resume with"
  // box — the prompt rides on the session's own record instead of on a trigger.
  chooseSpotQueue(event) {
    event.preventDefault()
    event.stopPropagation()
    this._post(
      { mode: event.currentTarget.dataset.mode },
      (data) =>
        data.pending_sleep
          ? "Joins the spot queue when this turn ends."
          : `Queued for spot (precedence ${data.precedence}).`,
      "Queuing…"
    )
  }

  chooseCustom(event) {
    event.preventDefault()
    event.stopPropagation()
    const value = this.customInputTarget.value
    if (!value) {
      this._setStatus("Pick a date and time first.", true)
      return
    }
    // A datetime-local value is ALREADY a naive local wall-clock string
    // ("2026-08-22T09:00"), which is exactly what the server wants alongside the
    // zone below — so it goes through untouched rather than round-tripping a Date.
    this._schedule(value)
  }

  // --- scheduling ---

  _schedule(wakeAt) {
    return this._post(
      { wake_at: wakeAt, timezone: this._timezone() },
      // A running session does not sleep mid-turn: the trigger marks it
      // pending_sleep and it transitions when the turn ends. Say that rather than
      // claiming a state change the badge is about to contradict.
      (data) =>
        data.pending_sleep
          ? `Sleeps when this turn ends, then wakes ${this._humanize(wakeAt)}.`
          : `Paused until ${this._humanize(wakeAt)}.`
    )
  }

  // One POST for both halves of the panel. `confirmation` turns the server's
  // answer into the line the panel shows before it closes.
  async _post(body, confirmation, pending = "Scheduling…") {
    this._setStatus(pending)
    const payload = {
      ...body,
      prompt: this.hasPromptInputTarget ? this.promptInputTarget.value.trim() : ""
    }

    let data
    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content,
          "Accept": "application/json"
        },
        body: JSON.stringify(payload)
      })
      data = await response.json()
      if (!response.ok) {
        this._setStatus(data.error || "Could not schedule the pause.", true)
        return
      }
    } catch (error) {
      this._setStatus("Network error — nothing was scheduled.", true)
      return
    }

    this._setStatus(confirmation(data))

    // Let a wrapping menu close itself; the card and header re-render from the
    // status broadcast the sleep sets off.
    this.dispatch("scheduled", { detail: data, prefix: "pause-until" })
    setTimeout(() => this._close(), 1600)
  }

  // --- presets ---

  // Resolved against `now` so a panel left open overnight still schedules from
  // the moment the button is pressed, not from when it was rendered.
  _presetDate(key, now = new Date()) {
    const at = new Date(now.getTime())
    switch (key) {
      case "15m":
        at.setMinutes(at.getMinutes() + 15)
        return at
      case "1h":
        at.setHours(at.getHours() + 1)
        return at
      case "3h":
        at.setHours(at.getHours() + 3)
        return at
      case "tonight":
        // 6pm today, or 6pm tomorrow once tonight has already gone by.
        at.setHours(18, 0, 0, 0)
        if (at <= now) at.setDate(at.getDate() + 1)
        return at
      case "tomorrow":
        at.setDate(at.getDate() + 1)
        at.setHours(9, 0, 0, 0)
        return at
      case "monday": {
        // The next Monday strictly after today, so clicking it on a Monday means
        // a week out rather than a time that has already passed.
        const daysAhead = ((8 - at.getDay()) % 7) || 7
        at.setDate(at.getDate() + daysAhead)
        at.setHours(9, 0, 0, 0)
        return at
      }
      default:
        return null
    }
  }

  // --- panel ---

  _open() {
    this.panelTarget.classList.remove("hidden")
    this.buttonTarget.setAttribute("aria-expanded", "true")
    this._setStatus("")
    this._refreshPresetTimes()
    this._primeCustomInput()
    if (this.hasZoneTarget) this.zoneTarget.textContent = this._timezone()
    // Defer so the click that opened the panel doesn't immediately close it.
    setTimeout(() => {
      document.addEventListener("click", this._outsideClick)
      document.addEventListener("keydown", this._onKeydown)
    }, 0)
  }

  _close() {
    this.panelTarget.classList.add("hidden")
    this.buttonTarget.setAttribute("aria-expanded", "false")
    document.removeEventListener("click", this._outsideClick)
    document.removeEventListener("keydown", this._onKeydown)
  }

  _outsideClick(event) {
    if (!this.element.contains(event.target)) this._close()
  }

  _onKeydown(event) {
    if (event.key === "Escape") this._close()
  }

  _refreshPresetTimes() {
    const now = new Date()
    this.presetTimeTargets.forEach((el) => {
      const at = this._presetDate(el.dataset.preset, now)
      el.textContent = at ? this._shortLabel(at, now) : ""
    })
  }

  // Floor to the next whole minute and set it as the picker's `min`, so the
  // browser blocks the past-dated case the server would otherwise have to reject.
  _primeCustomInput() {
    if (!this.hasCustomInputTarget) return
    const soon = new Date(Date.now() + 60_000)
    soon.setSeconds(0, 0)
    this.customInputTarget.min = this._naiveLocal(soon).slice(0, 16)
  }

  // --- formatting ---

  _timezone() {
    try {
      return Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC"
    } catch (error) {
      return "UTC"
    }
  }

  // "2026-08-22T09:00:00" in the browser's own zone. Deliberately NOT
  // toISOString(), which converts to UTC and would defeat the whole point.
  _naiveLocal(date) {
    const pad = (n) => String(n).padStart(2, "0")
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}` +
      `T${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`
  }

  _shortLabel(date, now) {
    const time = date.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })
    return date.toDateString() === now.toDateString() ? time : `${date.toLocaleDateString([], { month: "short", day: "numeric" })}, ${time}`
  }

  _humanize(naiveLocal) {
    const parsed = new Date(naiveLocal)
    if (isNaN(parsed.getTime())) return naiveLocal
    return this._shortLabel(parsed, new Date())
  }

  _setStatus(text, isError = false) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = text
    this.statusTarget.classList.toggle("text-red-600", isError)
    this.statusTarget.classList.toggle("text-gray-500", !isError)
  }
}
