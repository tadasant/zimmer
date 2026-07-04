import { Controller } from "@hotwired/stimulus"

/**
 * Session Drawer Controller
 *
 * Opens a session's detail view in a large drawer that slides in from the right
 * of the dashboard, so the user can peek at a transcript (and act on it — send a
 * follow-up, archive) without losing their place on the dashboard.
 *
 * The detail view is lazy-loaded into a Turbo Frame by setting its `src` to the
 * session URL. Loading via a real frame navigation (rather than innerHTML
 * injection) is what makes the detail view's `turbo_stream_from` subscriptions
 * and Stimulus controllers connect, so the transcript streams live inside the
 * drawer and the follow-up/archive controls work.
 *
 * Native link semantics are preserved: the "View" trigger is a real <a href>, so
 * middle-clicks (which fire `auxclick`, not `click`) and modifier-clicks
 * (Cmd/Ctrl/Shift/Alt) still open the session in a new tab. Only a plain
 * left-click is intercepted.
 *
 * The panel's left edge carries a resize handle: drag it to widen or narrow the
 * drawer. The chosen width is persisted in localStorage so it sticks across
 * opens and page loads.
 */
export default class extends Controller {
  static targets = ["panel", "overlay", "frame", "resizeHandle"]

  // Resize bounds. The drawer never gets narrower than MIN_WIDTH or wider than
  // the viewport (less a small gutter so the overlay stays grabbable to close).
  static MIN_WIDTH = 480
  static VIEWPORT_GUTTER = 48
  static STORAGE_KEY = "aoSessionDrawerWidth"
  // Below Tailwind's `sm` breakpoint the drawer is full-width and the resize
  // handle is hidden, so a custom width neither applies nor can be set.
  static SM_BREAKPOINT = 640

  connect() {
    this.boundKeydown = this.handleKeydown.bind(this)
    document.addEventListener("keydown", this.boundKeydown)

    // Close controls (the detail view's "Close" button) live inside the
    // lazy-loaded `session_detail` Turbo Frame, not in the static dashboard
    // markup this controller is attached to. A per-button
    // `click->session-drawer#close` action would only fire once Stimulus's
    // MutationObserver has wired the freshly-swapped frame content — a beat
    // AFTER the HTML is in the DOM. A click in that sub-frame gap fires a plain
    // DOM event no controller handles and is silently dropped, leaving the
    // drawer open (the historically flaky close race). Delegate close clicks
    // from the always-present controller root instead: this listener is bound
    // eagerly at connect, so a click on any `[data-session-drawer-close]`
    // control is honored the instant the button exists, with no wiring race.
    this.boundDelegatedClose = this.handleDelegatedClose.bind(this)
    this.element.addEventListener("click", this.boundDelegatedClose)

    // Bound once so add/removeEventListener pair up during a drag.
    this.boundDoResize = this.doResize.bind(this)
    this.boundEndResize = this.endResize.bind(this)

    // Re-evaluate the custom width when the viewport crosses the `sm` boundary:
    // a desktop width must be dropped on mobile (where the drawer is full-width),
    // and an over-wide width must be re-clamped to a now-smaller viewport.
    this.boundViewportResize = this.handleViewportResize.bind(this)
    window.addEventListener("resize", this.boundViewportResize)

    this.applyStoredWidth()
    this.syncResizeAria()
  }

  disconnect() {
    document.removeEventListener("keydown", this.boundKeydown)
    this.element.removeEventListener("click", this.boundDelegatedClose)
    window.removeEventListener("resize", this.boundViewportResize)
    this.stopResizeListeners()
    this.unlockScroll()
    if (this.clearTimer) clearTimeout(this.clearTimer)
  }

  open(event) {
    // On mobile the drawer is too clunky, so skip it entirely: don't intercept
    // the click and let the native <a href> navigate to the full session page.
    // Use the same `sm` breakpoint that defines "full-width drawer" elsewhere in
    // this controller, so "mobile" stays consistent with the rest of the UI.
    if (this.isMobileViewport) return

    // Only intercept a plain left-click. Let the browser handle modifier-clicks
    // and any non-primary button so "open in new tab" keeps working.
    if (
      event.button !== 0 ||
      event.metaKey ||
      event.ctrlKey ||
      event.shiftKey ||
      event.altKey
    ) {
      return
    }

    const url = event.currentTarget.href
    if (!url) return

    event.preventDefault()

    // Remember the trigger so focus can return to it on close (the panel is an
    // aria-modal dialog; focus must not be stranded on <body> after dismissal).
    this.returnFocusEl = event.currentTarget

    // Cancel any pending frame-clear from a previous close so reopening keeps
    // (or replaces) the content cleanly.
    if (this.clearTimer) {
      clearTimeout(this.clearTimer)
      this.clearTimer = null
    }

    // If a different session is being opened than the one still loaded in the
    // frame, blank the frame first so the previous session's content doesn't
    // flash while the new fetch is in flight.
    if (this.frameTarget.getAttribute("src") !== url) {
      this.frameTarget.removeAttribute("src")
      this.frameTarget.innerHTML = ""
    }

    // Setting src triggers a Turbo Frame fetch; the matching
    // <turbo-frame id="session_detail"> in the response is swapped in.
    this.frameTarget.src = url

    this.show()
  }

  show() {
    this.overlayTarget.classList.remove("hidden")
    // Toggle to an explicit translate-x-0 (rather than just removing
    // translate-x-full) so the panel always carries a non-none `translate`
    // value. That makes it the containing block for its `position: fixed`
    // descendants — notably the detail view's follow-up form — so the form
    // spans the drawer width instead of escaping to the full viewport.
    this.panelTarget.classList.remove("translate-x-full")
    this.panelTarget.classList.add("translate-x-0")
    this.panelTarget.setAttribute("aria-hidden", "false")
    this.lockScroll()
    // Move focus into the panel so keyboard users land inside the dialog and
    // Escape-to-close feels natural. preventScroll is essential: the panel is
    // position:fixed, and a plain focus() makes the browser scroll the dashboard
    // underneath toward the panel's layout position — the exact "the page jumps
    // when I open the drawer" jiggle we want to avoid.
    this.panelTarget.focus({ preventScroll: true })
  }

  close() {
    if (this.isClosed) return
    // Move focus back to the trigger BEFORE hiding the panel, so focus is never
    // left inside an aria-hidden subtree. preventScroll keeps the dashboard from
    // jumping if the trigger sits just outside the viewport.
    if (this.returnFocusEl && document.contains(this.returnFocusEl)) {
      this.returnFocusEl.focus({ preventScroll: true })
    }
    this.returnFocusEl = null
    this.panelTarget.classList.remove("translate-x-0")
    this.panelTarget.classList.add("translate-x-full")
    this.overlayTarget.classList.add("hidden")
    this.panelTarget.setAttribute("aria-hidden", "true")
    this.unlockScroll()

    // After the slide-out transition, clear the frame so its live Turbo Stream
    // subscriptions disconnect — we don't want to keep streaming a hidden
    // session. Reopening sets a fresh src.
    this.clearTimer = setTimeout(() => {
      if (this.isClosed) {
        this.frameTarget.removeAttribute("src")
        this.frameTarget.innerHTML = ""
      }
      this.clearTimer = null
    }, 300)
  }

  // Eagerly-bound delegated handler for close controls inside the lazy-loaded
  // frame (see connect). A click anywhere under the controller root that
  // resolves to a `[data-session-drawer-close]` element dismisses the drawer,
  // sidestepping the MutationObserver gap that drops a per-button action click.
  handleDelegatedClose(event) {
    const trigger = event.target.closest("[data-session-drawer-close]")
    if (!trigger || !this.element.contains(trigger)) return
    this.close()
  }

  handleKeydown(event) {
    if (this.isClosed) return

    if (event.key === "Escape") {
      this.close()
      return
    }

    // The panel is aria-modal, so keep Tab focus inside it while open.
    if (event.key === "Tab") {
      this.trapFocus(event)
    }
  }

  trapFocus(event) {
    const focusables = this.focusableElements
    if (focusables.length === 0) {
      // Nothing focusable yet (frame still loading) — keep focus on the panel.
      event.preventDefault()
      this.panelTarget.focus({ preventScroll: true })
      return
    }

    const first = focusables[0]
    const last = focusables[focusables.length - 1]
    const active = document.activeElement

    if (event.shiftKey) {
      if (active === first || active === this.panelTarget || !this.panelTarget.contains(active)) {
        event.preventDefault()
        last.focus()
      }
    } else if (active === last) {
      event.preventDefault()
      first.focus()
    }
  }

  get focusableElements() {
    return Array.from(
      this.panelTarget.querySelectorAll(
        'a[href], button:not([disabled]), textarea:not([disabled]), input:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex="-1"])'
      )
    ).filter((el) => el.offsetParent !== null || el === document.activeElement)
  }

  get isClosed() {
    return this.panelTarget.classList.contains("translate-x-full")
  }

  // --- Scroll lock -----------------------------------------------------------

  lockScroll() {
    // Already locked (e.g. open() called twice) — don't clobber the saved offset.
    if (this.scrollLocked) return
    this.scrollLocked = true

    // Pin the body in place with position:fixed rather than merely hiding
    // overflow. `overflow: hidden` stops the *user* from scrolling but does NOT
    // stop programmatic/browser scrolling: when the drawer's Turbo Frame loads
    // and the browser brings a freshly focused control into view, it scrolls the
    // dashboard underneath — the "page jumps when I open the drawer" jiggle.
    // Taking the body out of the scroll flow entirely makes that impossible: the
    // document can no longer scroll, so nothing can move it. The exact offset is
    // restored on unlock.
    this.savedScrollY = window.scrollY
    this.savedScrollX = window.scrollX

    // Removing the body scrollbar reclaims its width; pad by that amount so the
    // dashboard doesn't shift sideways on platforms with classic (non-overlay)
    // scrollbars.
    const scrollbarWidth = window.innerWidth - document.documentElement.clientWidth

    const body = document.body
    body.style.position = "fixed"
    body.style.top = `-${this.savedScrollY}px`
    body.style.left = `-${this.savedScrollX}px`
    body.style.width = "100%"
    if (scrollbarWidth > 0) body.style.paddingRight = `${scrollbarWidth}px`
  }

  unlockScroll() {
    if (!this.scrollLocked) return
    this.scrollLocked = false

    const body = document.body
    body.style.position = ""
    body.style.top = ""
    body.style.left = ""
    body.style.width = ""
    body.style.paddingRight = ""

    // Restore the exact scroll position the dashboard had when the drawer opened.
    window.scrollTo(this.savedScrollX || 0, this.savedScrollY || 0)
    this.savedScrollX = null
    this.savedScrollY = null
  }

  // --- Resize ----------------------------------------------------------------

  startResize(event) {
    // Primary button / single touch only, and only when the drawer is resizable
    // (desktop widths — below `sm` it's full-width with the handle hidden).
    if (event.button != null && event.button !== 0) return
    if (!this.isResizable) return
    event.preventDefault()

    this.resizing = true
    // Suppress text selection and pointer interactions with the (now irrelevant)
    // content while dragging, and signal intent with a resize cursor.
    document.body.style.userSelect = "none"
    document.body.style.cursor = "col-resize"
    if (this.hasResizeHandleTarget) this.resizeHandleTarget.classList.add("bg-indigo-400")

    window.addEventListener("pointermove", this.boundDoResize)
    window.addEventListener("pointerup", this.boundEndResize)
    window.addEventListener("pointercancel", this.boundEndResize)
  }

  doResize(event) {
    if (!this.resizing) return
    // The panel is anchored to the right edge, so its width is the distance from
    // the pointer to the right edge of the viewport.
    const width = window.innerWidth - event.clientX
    this.setWidth(width)
  }

  // Keyboard resize for the handle (focusable separator). Arrow keys nudge the
  // width; Shift takes bigger steps; Home/End jump to the max/min. This makes the
  // ARIA `separator` we advertise actually operable without a pointer.
  resizeKeydown(event) {
    if (!this.isResizable) return

    const step = event.shiftKey ? 64 : 16
    const current = parseInt(this.panelTarget.style.width, 10) || this.panelTarget.offsetWidth
    let next = current

    switch (event.key) {
      // The handle is on the panel's left edge, so left = wider, right = narrower.
      case "ArrowLeft":
      case "ArrowUp":
        next = current + step
        break
      case "ArrowRight":
      case "ArrowDown":
        next = current - step
        break
      case "Home":
        next = window.innerWidth // clamped to max by setWidth
        break
      case "End":
        next = this.constructor.MIN_WIDTH
        break
      default:
        return
    }

    event.preventDefault()
    this.setWidth(next)
    this.persistWidth()
  }

  endResize() {
    if (!this.resizing) return
    this.resizing = false
    document.body.style.userSelect = ""
    document.body.style.cursor = ""
    if (this.hasResizeHandleTarget) this.resizeHandleTarget.classList.remove("bg-indigo-400")
    this.stopResizeListeners()
    this.persistWidth()
  }

  stopResizeListeners() {
    window.removeEventListener("pointermove", this.boundDoResize)
    window.removeEventListener("pointerup", this.boundEndResize)
    window.removeEventListener("pointercancel", this.boundEndResize)
  }

  // Re-evaluate the custom width on viewport changes so the `sm` full-width rule
  // is never defeated by a stale inline width carried over from a desktop drag.
  handleViewportResize() {
    if (this.isResizable) {
      // Re-clamp the current width to the new viewport (a wide drawer must shrink
      // if the window narrows), or restore the stored width if none is applied.
      if (this.panelTarget.style.width) {
        this.setWidth(parseInt(this.panelTarget.style.width, 10))
      } else {
        this.applyStoredWidth()
      }
    } else {
      // Below `sm` the drawer is full-width: drop the inline overrides so the
      // Tailwind `w-full` / `max-w-5xl` classes govern again.
      this.clearWidth()
    }
  }

  persistWidth() {
    try {
      const px = parseInt(this.panelTarget.style.width, 10)
      if (px) localStorage.setItem(this.constructor.STORAGE_KEY, String(px))
    } catch (_e) {
      // localStorage can throw in private mode / when disabled — width just
      // won't persist, which is fine.
    }
  }

  setWidth(width) {
    const clamped = this.clampWidth(width)
    // Inline width overrides the Tailwind `w-full`; clearing max-width lets the
    // drawer grow past the default `max-w-5xl` cap when dragged wider.
    this.panelTarget.style.width = `${clamped}px`
    this.panelTarget.style.maxWidth = "none"
    this.updateResizeAria(clamped)
  }

  clearWidth() {
    this.panelTarget.style.width = ""
    this.panelTarget.style.maxWidth = ""
    if (this.hasResizeHandleTarget) {
      this.resizeHandleTarget.removeAttribute("aria-valuenow")
    }
  }

  clampWidth(width) {
    const max = window.innerWidth - this.constructor.VIEWPORT_GUTTER
    const min = Math.min(this.constructor.MIN_WIDTH, max)
    return Math.round(Math.max(min, Math.min(width, max)))
  }

  applyStoredWidth() {
    // On narrow viewports the drawer is full-width; never override that with a
    // width carried over from a desktop session.
    if (!this.isResizable) return
    let stored
    try {
      stored = localStorage.getItem(this.constructor.STORAGE_KEY)
    } catch (_e) {
      return
    }
    if (!stored) return
    const px = parseInt(stored, 10)
    if (px) this.setWidth(px)
  }

  // Publish the current width and bounds on the handle so assistive tech can
  // announce the separator's value. Called on init and whenever the width moves.
  updateResizeAria(width) {
    if (!this.hasResizeHandleTarget) return
    const max = Math.round(window.innerWidth - this.constructor.VIEWPORT_GUTTER)
    const min = Math.round(Math.min(this.constructor.MIN_WIDTH, max))
    this.resizeHandleTarget.setAttribute("aria-valuemin", String(min))
    this.resizeHandleTarget.setAttribute("aria-valuemax", String(max))
    this.resizeHandleTarget.setAttribute("aria-valuenow", String(Math.round(width)))
  }

  // Seed the handle's ARIA value from the panel's current rendered width when no
  // explicit inline width has been set (e.g. first load with no stored width).
  syncResizeAria() {
    if (!this.isResizable || !this.hasResizeHandleTarget) return
    if (this.panelTarget.style.width) return
    this.updateResizeAria(this.panelTarget.offsetWidth)
  }

  get isResizable() {
    return window.innerWidth >= this.constructor.SM_BREAKPOINT
  }

  // Below the `sm` breakpoint we treat the viewport as mobile and skip the
  // drawer altogether — clicking "View" performs a normal navigation to the full
  // session page instead. Viewport-width based (not touch/user-agent) so it
  // stays consistent with `isResizable` and the rest of the UI's mobile rules.
  get isMobileViewport() {
    return window.innerWidth < this.constructor.SM_BREAKPOINT
  }
}
