import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="visibility"
//
// Board visibility: "Snooze until…" and "Hide" — the presentation-only axis that
// tidies the dashboard. It changes what is on screen and nothing else: no
// session is started, stopped, slept or woken by anything in this file. Nothing
// in the web UI sleeps a session at all; that is `wake_me_up_later` and
// `pause_into_spot_queue` over MCP.
//
// Snooze times are computed here, in the BROWSER's zone, and posted as a naive
// wall-clock string alongside the zone's IANA name — the same contract
// `wake_me_up_later` uses. Computing them server-side in UTC is how "Tomorrow, 9 AM" becomes
// 3am for the person reading the board.
//
// Two layouts, one behaviour: `inline` renders the snooze panel in normal flow
// (inside a card or ranked row's overflow menu, which is already a positioned
// box), anything else renders it as an absolute popover (the detail header).
export default class extends Controller {
  static targets = ["button", "panel", "presetTime", "customInput", "status", "zone"]
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
    // SNOOZE_PRESETS and _presetDate's switch are two hand-kept lists of the same
    // keys. A key added to one and not the other renders a row with a blank time
    // that does nothing when clicked; say so rather than swallowing the click.
    if (!at) {
      this._setStatus("Could not work out that time.", true)
      return
    }
    this._snooze(this._naiveLocal(at))
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
    // ("2026-09-05T09:00"), which is exactly what the server wants alongside the
    // zone — so it goes through untouched rather than round-tripping a Date.
    this._snooze(value)
  }

  hide(event) {
    event.preventDefault()
    event.stopPropagation()
    this._post({ visibility: "hidden" }, "Hidden from the board.", "Hiding…")
  }

  // Put a hidden or snoozed session back. Only rendered while the session is
  // tucked away, which is only while the board is revealing them.
  restore(event) {
    event.preventDefault()
    event.stopPropagation()
    this._post({ visibility: "visible" }, "Back on the board.", "Restoring…")
  }

  // --- posting ---

  _snooze(snoozedUntil) {
    return this._post(
      { visibility: "snoozed", snoozed_until: snoozedUntil, timezone: this._timezone() },
      `Snoozed until ${this._humanize(snoozedUntil)}.`,
      "Snoozing…"
    )
  }

  async _post(body, confirmation, pending) {
    this._setStatus(pending)

    let data
    try {
      const response = await fetch(this.urlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content,
          "Accept": "application/json"
        },
        body: JSON.stringify(body)
      })
      data = await response.json()
      if (!response.ok) {
        this._setStatus(data.error || "Could not change visibility.", true)
        return
      }
    } catch (error) {
      this._setStatus("Network error — visibility unchanged.", true)
      return
    }

    this._setStatus(confirmation)
    this.dispatch("changed", { detail: data, prefix: "visibility" })
    setTimeout(() => this._settle(data), 500)
  }

  // What the page does with the answer.
  //
  // A session that has just left the board leaves the DOM too, so the board the
  // operator was tidying is tidy immediately rather than after a reload — that
  // responsiveness is the whole point of the feature. Everything else (putting a
  // card back, or any change made while the board is revealing tucked-away
  // sessions) re-renders the page, because the badge and the counts are
  // server-rendered and would otherwise disagree with the row.
  _settle(data) {
    this._close()

    const unit = this.element.closest("[data-visibility-unit]")
    if (unit && data.board_visible === false && !this._boardReveals()) {
      // A card sits inside its own <turbo-frame>; taking the frame with it stops
      // an empty frame being left behind for a live status broadcast to fill.
      const parent = unit.parentElement
      const removable = parent && parent.tagName === "TURBO-FRAME" ? parent : unit
      removable.remove()
      return
    }

    window.location.reload()
  }

  // Whether the page currently on screen is showing tucked-away sessions. The
  // dashboard states its own filter; anywhere else (the session detail page) has
  // no board to take a card off, so the answer is "yes, keep it".
  _boardReveals() {
    const board = document.querySelector("[data-board-visibility-filter]")
    if (!board) return true

    return board.dataset.boardVisibilityFilter !== "on_board"
  }

  // --- presets ---

  // Resolved against `now` so a panel left open overnight still snoozes from the
  // moment the button is pressed, not from when it was rendered. Morning presets
  // land at 9am local; "later today" is a nudge rather than a landmark.
  _presetDate(key, now = new Date()) {
    const at = new Date(now.getTime())
    switch (key) {
      case "later_today":
        at.setHours(at.getHours() + 3)
        return at
      case "tomorrow":
        at.setDate(at.getDate() + 1)
        at.setHours(9, 0, 0, 0)
        return at
      case "in_3_days":
        at.setDate(at.getDate() + 3)
        at.setHours(9, 0, 0, 0)
        return at
      case "this_weekend": {
        // The coming Saturday. On a Saturday or Sunday it means NEXT Saturday —
        // a weekend already under way is not somewhere to push work to.
        const daysAhead = ((6 - at.getDay()) + 7) % 7 || 7
        at.setDate(at.getDate() + daysAhead)
        at.setHours(9, 0, 0, 0)
        return at
      }
      case "next_week": {
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
    if (!this.hasPanelTarget) return

    this.panelTarget.classList.add("hidden")
    if (this.hasButtonTarget) this.buttonTarget.setAttribute("aria-expanded", "false")
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

  // "2026-09-05T09:00:00" in the browser's own zone. Deliberately NOT
  // toISOString(), which converts to UTC and would defeat the whole point.
  _naiveLocal(date) {
    const pad = (n) => String(n).padStart(2, "0")
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}` +
      `T${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`
  }

  _shortLabel(date, now) {
    const time = date.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })
    return date.toDateString() === now.toDateString() ? time : `${date.toLocaleDateString([], { weekday: "short", month: "short", day: "numeric" })}, ${time}`
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
