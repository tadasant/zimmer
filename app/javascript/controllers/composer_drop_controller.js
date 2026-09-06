import { Controller } from "@hotwired/stimulus"

// Owns the drag-and-drop surface for the message composer, and hands whatever was
// dropped to the two attachment controllers that share it.
//
// The surface is the *document*, not the composer's own box. Anywhere on the page, a
// dragged file belongs to the composer, because the composer is the only thing on the
// page that takes one -- and a file drop no handler claims is not inert, it navigates
// the tab to the file and takes the half-typed draft with it. Binding to an element
// instead leaves everything outside it (the button row, the preview strip, the panel
// margins, the transcript) unclaimed, and a user aiming at "the composer" hits those.
//
// The overlay target is what keeps a document-wide surface readable as a targeted
// one: it marks where the file will go.
//
// Drags that carry no files are ignored outright -- no preventDefault, no overlay,
// no drop handling. That is what keeps the enqueued-message reorder working: it is
// an internal HTML5 drag with no "Files" entry in dataTransfer.types, so these
// listeners never touch it and enqueued-messages-list still sees its own events.
export default class extends Controller {
  static targets = ["overlay"]

  connect() {
    // dragenter/dragleave fire once per element the pointer crosses, and they bubble
    // to the document, so a plain boolean would clear the overlay the moment the
    // pointer moves from the panel onto the textarea inside it. Counting the pairs
    // and only clearing at zero is what survives crossing child boundaries.
    this.dragDepth = 0

    this.documentListeners = {
      dragenter: this.dragEnter.bind(this),
      dragover: this.dragOver.bind(this),
      dragleave: this.dragLeave.bind(this),
      drop: this.drop.bind(this),
      dragend: this.hideOverlay.bind(this)
    }

    for (const [ name, listener ] of Object.entries(this.documentListeners)) {
      document.addEventListener(name, listener)
    }
  }

  disconnect() {
    for (const [ name, listener ] of Object.entries(this.documentListeners)) {
      document.removeEventListener(name, listener)
    }
    this.hideOverlay()
  }

  dragEnter(event) {
    if (!this.carriesFiles(event)) return

    event.preventDefault()
    this.dragDepth += 1
    this.showOverlay()
  }

  dragOver(event) {
    if (!this.carriesFiles(event)) return

    // Chrome only allows a drop where dragover's default was prevented, so this is
    // the line that decides whether the drop below ever happens.
    event.preventDefault()
    event.dataTransfer.dropEffect = "copy"
    // A drag that began outside the window can land its first dragover without a
    // dragenter this controller saw, so the overlay is asserted here too.
    this.showOverlay()
  }

  dragLeave(event) {
    if (!this.carriesFiles(event)) return

    this.dragDepth = Math.max(0, this.dragDepth - 1)
    if (this.dragDepth === 0) this.hideOverlay()
  }

  drop(event) {
    if (!this.carriesFiles(event)) return

    event.preventDefault()
    this.hideOverlay()

    // Dispatched synchronously so the listeners can still read dataTransfer: the
    // DataTransfer and its items are only valid for the duration of this handler.
    this.dispatch("files", { detail: { dataTransfer: event.dataTransfer } })
  }

  // True only for a drag carrying files from outside the page. Text selections,
  // links, and the enqueued-message reorder all fail this and are left alone.
  carriesFiles(event) {
    const types = event.dataTransfer?.types
    return types ? Array.from(types).includes("Files") : false
  }

  showOverlay() {
    if (this.overlayVisible || !this.hasOverlayTarget) return

    this.overlayVisible = true
    this.overlayTarget.classList.remove("hidden")
    // An affordance the user cannot see does not tell them anything. On the session
    // screen the composer is a fixed panel and this is a no-op; on the new-session
    // form the prompt field sits partway down a long page, and a drag that starts
    // over the agent-root picker at the top would otherwise show nothing at all.
    // "nearest" scrolls only when it is actually off-screen.
    this.overlayTarget.scrollIntoView({ block: "nearest" })
  }

  hideOverlay() {
    this.dragDepth = 0
    this.overlayVisible = false
    if (this.hasOverlayTarget) this.overlayTarget.classList.add("hidden")
  }
}
