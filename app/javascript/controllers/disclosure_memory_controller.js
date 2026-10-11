import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="disclosure-memory"
//
// Keeps a reader's open/closed choice on the <details data-disclosure="…">
// inside this element when a Turbo Stream replaces the markup they sit in.
//
// The Session hierarchy and Human messages disclosures are server-rendered
// closed, and the partial that holds them is re-broadcast whenever anything in
// the family changes (Session#broadcast_provenance_change_to_hierarchy) — which,
// in a family that is busy spawning, is often. Without this, every such
// broadcast would snap shut a disclosure the reader had just opened.
export default class extends Controller {
  connect() {
    this.boundBeforeStreamRender = this.beforeStreamRender.bind(this)
    document.addEventListener("turbo:before-stream-render", this.boundBeforeStreamRender)
  }

  disconnect() {
    document.removeEventListener("turbo:before-stream-render", this.boundBeforeStreamRender)
  }

  beforeStreamRender(event) {
    const open = this.openKeys()
    if (open.size === 0) return

    const render = event.detail.render
    event.detail.render = async (streamElement) => {
      await render(streamElement)
      this.restore(open)
    }
  }

  openKeys() {
    const keys = new Set()
    for (const details of this.element.querySelectorAll("details[data-disclosure]")) {
      if (details.open) keys.add(details.dataset.disclosure)
    }
    return keys
  }

  restore(keys) {
    for (const details of this.element.querySelectorAll("details[data-disclosure]")) {
      if (keys.has(details.dataset.disclosure)) details.open = true
    }
  }
}
