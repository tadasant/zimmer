import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="cable-reconnect"
//
// Keeps the Turbo Stream subscriptions inside this element alive, keyed on the
// cable's actual connection state rather than on elapsed time.
//
// turbo-rails' <turbo-cable-stream-source> carries a `connected` attribute that
// it sets when its subscription connects and removes when it drops. ActionCable
// heals most drops on its own by reloading every subscription once the consumer
// reconnects. When it does not — a suspended socket the browser never reports as
// closed, a server that restarted mid-subscribe — the element sits there without
// `connected` and live updates stop arriving with no visible symptom.
//
// This controller watches that attribute. A source that is still disconnected
// after the grace window is re-subscribed by detaching and re-attaching it, which
// runs the element's own disconnectedCallback/connectedCallback pair and yields a
// fresh subscription. Retries back off so a genuinely unreachable server is not
// hammered, and the page is never reloaded — nothing the user typed is lost.
export default class extends Controller {
  static values = {
    // How long a source may stay disconnected before we re-subscribe it. Long
    // enough for ActionCable's own monitor to reconnect first.
    grace: { type: Number, default: 3000 },
    // Ceiling for the exponential backoff between re-subscribe attempts.
    maxGrace: { type: Number, default: 30000 }
  }

  connect() {
    this.timers = new Map()
    this.attempts = new Map()

    this.observer = new MutationObserver((mutations) => this.handleMutations(mutations))
    this.observer.observe(this.element, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: [ "connected" ]
    })

    // A source that was already disconnected when this controller mounted never
    // fires a mutation, so take a reading now.
    this.sources.forEach((source) => this.watch(source))
  }

  disconnect() {
    this.observer?.disconnect()
    this.timers.forEach((timer) => clearTimeout(timer))
    this.timers.clear()
    this.attempts.clear()
  }

  get sources() {
    return Array.from(this.element.querySelectorAll("turbo-cable-stream-source"))
  }

  handleMutations(mutations) {
    let sourcesChanged = false

    for (const mutation of mutations) {
      if (mutation.type === "attributes") {
        this.watch(mutation.target)
      } else {
        sourcesChanged = true
      }
    }

    // A childList change can add sources (a frame swap) or drop the ones we were
    // holding timers for. Re-read the set and forget anything detached.
    if (sourcesChanged) {
      const live = this.sources
      this.timers.forEach((_timer, source) => {
        if (!live.includes(source)) this.forget(source)
      })
      live.forEach((source) => this.watch(source))
    }
  }

  // Schedule a re-subscribe for a disconnected source; cancel any pending one for
  // a source that has come back.
  watch(source) {
    if (source.hasAttribute("connected")) {
      this.forget(source)
      return
    }

    if (this.timers.has(source)) return

    const attempt = this.attempts.get(source) || 0
    const delay = Math.min(this.graceValue * 2 ** attempt, this.maxGraceValue)

    this.timers.set(source, setTimeout(() => {
      this.timers.delete(source)
      this.attempts.set(source, attempt + 1)
      this.resubscribe(source)
    }, delay))
  }

  forget(source) {
    const timer = this.timers.get(source)
    if (timer) clearTimeout(timer)
    this.timers.delete(source)
    this.attempts.delete(source)
  }

  resubscribe(source) {
    // Both conditions can have changed while the timer was pending.
    if (!source.isConnected || source.hasAttribute("connected")) {
      this.forget(source)
      return
    }

    const placeholder = document.createComment("turbo-cable-stream-source")
    source.replaceWith(placeholder)
    placeholder.replaceWith(source)

    // Still down? watch() schedules the next attempt at the next backoff step.
    // A successful subscribe sets `connected`, which cancels it via the observer.
    this.watch(source)
  }
}
