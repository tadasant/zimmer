import { Controller } from "@hotwired/stimulus"
import { partitionMedia } from "lib/media_kinds"
import { csrfToken } from "lib/csrf"
import { startSession, DRAFT_KEY } from "lib/session_starts"

// Handles the dashboard quick prompt:
//
// Desktop:
// - Cmd+Enter (Mac) / Ctrl+Enter (Windows/Linux) to submit
// - Textarea is vertically resizable via drag handle
// - Prevents double-submission
// - Photo / camera / file attach buttons forward clicks to hidden file inputs
//   (capture="environment" makes the camera button open the rear camera on mobile)
//
// Mobile:
// - Tappable pill opens full-screen overlay editor
// - X button or Escape key dismisses the overlay
// - Dedicated Submit button at the bottom of the screen
// - Closing the overlay resets the Advanced accordion (harness, model, spot)
// - Attach buttons mirror the desktop behavior
// - Double-submit protection
//
// Client-side guards reject oversize files and excess counts before the form
// posts so the user gets immediate feedback instead of a server-side redirect
// with a flash. Values are sourced from server-side constants via data attrs.
//
// A submit does not wait for the server. The form's fields and files go out as a
// JSON request (lib/session_starts.js) and the browser visits the starting page
// at once, with the words on it; the session's page replaces it when the id
// comes, and a refusal shows there with the words kept for Edit, which puts them
// back in this box. The forms stay `data-turbo="false"` native forms, so a
// browser that cannot run this still posts and follows the redirect.
//
// The photo input accepts everything a phone's library holds, which is wider than
// the four types ImageStorageService can store. A selection is re-routed before it
// is ever submitted: JPEG/PNG/GIF/WebP stay on images[], HEIC stills and video are
// moved onto files[]. The routing has to happen client-side because this form posts
// natively — an unroutable photo reaches the server, is rejected, and takes the
// typed prompt with it into a redirect.
export default class extends Controller {
  static targets = [
    "textarea",            // desktop textarea
    "desktopForm",         // desktop form
    "desktopImageInput",   // desktop photos & videos picker
    "desktopCameraInput",  // desktop camera input (capture="environment")
    "desktopFileInput",    // desktop file picker
    "desktopBadge",        // desktop "N attached" hint
    "mobileOverlay",       // full-screen overlay (mobile)
    "mobileTextarea",      // textarea inside overlay
    "mobileForm",          // form inside overlay
    "mobileSubmit",        // submit button (disabled during submission)
    "mobileImageInput",    // mobile photos & videos picker
    "mobileCameraInput",   // mobile camera input
    "mobileFileInput",     // mobile file picker
    "mobileBadge",         // mobile "N attached" hint
    "mobileAdvanced"       // mobile <details> holding the harness, model + spot controls
  ]

  static values = {
    maxImageSize: { type: Number, default: 10 * 1024 * 1024 }, // 10MB
    maxImages: { type: Number, default: 20 },
    maxFileSize: { type: Number, default: 500 * 1024 * 1024 }, // 500MB
    maxFiles: { type: Number, default: 200 }
  }

  connect() {
    this.submitting = false
    this.restoreDraft()
  }

  // The words a refused start handed back from the starting page's Edit. Not on
  // Turbo's cached preview of the board, which the fresh page replaces a moment
  // later — a draft taken there would be gone before the real box could show it.
  restoreDraft() {
    if (document.documentElement.hasAttribute("data-turbo-preview")) return
    let draft = null
    try {
      draft = sessionStorage.getItem(DRAFT_KEY)
      if (draft) sessionStorage.removeItem(DRAFT_KEY)
    } catch (error) {
      return
    }
    if (!draft) return
    if (this.hasTextareaTarget && !this.textareaTarget.value) this.textareaTarget.value = draft
    if (this.hasMobileTextareaTarget && !this.mobileTextareaTarget.value) this.mobileTextareaTarget.value = draft
  }

  // Ask for the session and open its page now. The FormData is read before the
  // visit tears the form down; the prompt rides along for the starting page.
  start(form, textarea) {
    const prompt = textarea.value.trim()
    if (!prompt) {
      textarea.focus()
      return false
    }
    const body = new FormData(form)
    const url = form.action
    startSession({
      prompt,
      title: "Quick Router",
      request: () => fetch(url, {
        method: "POST",
        headers: { "X-CSRF-Token": csrfToken(), "Accept": "application/json" },
        body
      })
    })
    return true
  }

  disconnect() {
    document.body.style.overflow = ""
  }

  // ---- Desktop ----

  submitOnCmdEnter(event) {
    if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
      event.preventDefault()
      this.submitDesktop()
    }
  }

  submitDesktop() {
    if (this.submitting) return
    this.submitting = true
    if (!this.start(this.desktopFormTarget, this.textareaTarget)) this.submitting = false
  }

  // The desktop form's own submit (a click on a submit button, or Enter in a
  // browser that submits on it): the same start, instead of the native post.
  submitDesktopForm(event) {
    event.preventDefault()
    this.submitDesktop()
  }

  openDesktopImage() {
    if (this.hasDesktopImageInputTarget) this.desktopImageInputTarget.click()
  }

  openDesktopCamera() {
    if (this.hasDesktopCameraInputTarget) this.desktopCameraInputTarget.click()
  }

  openDesktopFile() {
    if (this.hasDesktopFileInputTarget) this.desktopFileInputTarget.click()
  }

  updateDesktopBadge(event) {
    if (event) {
      this._routeMedia("desktop")
      this._validateScope("desktop", event.target)
    }
    this._updateBadge("desktop")
  }

  // ---- Mobile ----

  openMobile() {
    this.mobileOverlayTarget.classList.remove("hidden")
    document.body.style.overflow = "hidden"
    requestAnimationFrame(() => {
      this.mobileTextareaTarget.focus()
    })
  }

  closeMobile() {
    this.mobileOverlayTarget.classList.add("hidden")
    document.body.style.overflow = ""
    this.mobileTextareaTarget.value = ""
    // Clear any selected files so the next open starts clean.
    if (this.hasMobileImageInputTarget) this.mobileImageInputTarget.value = ""
    if (this.hasMobileCameraInputTarget) this.mobileCameraInputTarget.value = ""
    if (this.hasMobileFileInputTarget) this.mobileFileInputTarget.value = ""
    // Everything in Advanced is per-submission, not a sticky preference — the
    // next open starts back at the defaults (the root's harness and model,
    // priority) with the accordion collapsed again. The accordion owns what
    // "defaults" means, so this asks it rather than reaching into its controls.
    if (this.hasMobileAdvancedTarget) {
      this.mobileAdvancedTarget.dispatchEvent(new CustomEvent("quick-router-advanced:reset"))
    }
    this.updateMobileBadge()
  }

  closeMobileOnEscape(event) {
    if (event.key === "Escape") {
      this.closeMobile()
    }
  }

  submitMobile(event) {
    event.preventDefault()
    if (this.submitting) return
    this.submitting = true
    if (!this.start(this.mobileFormTarget, this.mobileTextareaTarget)) this.submitting = false
  }

  openMobileImage() {
    if (this.hasMobileImageInputTarget) this.mobileImageInputTarget.click()
  }

  openMobileCamera() {
    if (this.hasMobileCameraInputTarget) this.mobileCameraInputTarget.click()
  }

  openMobileFile() {
    if (this.hasMobileFileInputTarget) this.mobileFileInputTarget.click()
  }

  updateMobileBadge(event) {
    if (event) {
      this._routeMedia("mobile")
      this._validateScope("mobile", event.target)
    }
    this._updateBadge("mobile")
  }

  // ---- Internal ----

  // Move anything the image path cannot store out of the photo input and onto the
  // file input. An iPhone still is HEIC and a phone video is .mov/.mp4; both are
  // offered by the picker on purpose, and both are rejected by
  // ImageStorageService. As files[] they are stored verbatim and the agent is
  // handed a path — see app/javascript/lib/media_kinds.js.
  _routeMedia(scope) {
    const file = this._fileInput(scope)
    if (!file) return

    // Both the library picker and the camera input post under `images[]`, so both
    // have to be drained: an Android camera storing HEIF hands back a capture the
    // image path cannot take, just as the library does.
    for (const source of [ this._mediaInput(scope), this._cameraInput(scope) ]) {
      if (!source) continue

      const { images, files } = partitionMedia(source.files)
      if (files.length === 0) continue

      this._setInputFiles(source, images)
      this._setInputFiles(file, [ ...Array.from(file.files || []), ...files ])
    }
  }

  // Drop anything over the per-kind size limit, then clear the kind entirely if
  // it is over the count limit. Oversize entries are removed individually rather
  // than rejecting the whole selection: a phone multi-select is one tap over a
  // grid, and one long video in it should not discard the photos beside it.
  _validateScope(scope, changedInput) {
    for (const group of this._scopeGroups(scope)) {
      const { inputs, maxSize, maxCount, kind } = group
      const sizeMb = Math.round(maxSize / (1024 * 1024))

      for (const input of inputs) {
        const picked = Array.from(input.files || [])
        const tooLarge = picked.filter(f => f.size > maxSize)
        if (tooLarge.length === 0) continue

        this._setInputFiles(input, picked.filter(f => f.size <= maxSize))
        const names = tooLarge.map(f => `"${f.name}"`).join(", ")
        window.alert(`${names} ${tooLarge.length === 1 ? "is" : "are"} over the ${sizeMb}MB ${kind} limit and ${tooLarge.length === 1 ? "was" : "were"} not attached.`)
      }

      // Over the count, only the selection that crossed the line is dropped. Zeroing
      // the whole kind would take the twenty photos already picked along with the
      // twenty-first, which is the one thing the user did not ask for.
      const total = inputs.reduce((n, input) => n + (input.files?.length || 0), 0)
      if (total > maxCount) {
        const offender = inputs.includes(changedInput) ? changedInput : inputs[inputs.length - 1]
        this._setInputFiles(offender, [])
        window.alert(`Maximum ${maxCount} ${kind}${maxCount === 1 ? "" : "s"} allowed.`)
      }
    }
  }

  // A file input's `files` is only assignable from a FileList, so the round trip
  // goes through a DataTransfer. This is how a selection is edited in place
  // without asking the user to pick again.
  //
  // Returns false where the browser has no constructible DataTransfer. Failing
  // loudly matters: silently leaving the selection alone would post unsplit media
  // as `images[]` and lose the prompt to a server-side rejection, which is exactly
  // the failure the split exists to remove.
  _setInputFiles(input, files) {
    try {
      const dt = new DataTransfer()
      for (const file of files) dt.items.add(file)
      input.files = dt.files
      return true
    } catch (error) {
      console.error("Cannot rewrite a file input's selection in this browser:", error)
      input.value = ""
      window.alert("This browser could not stage that selection. Please attach the file with the paperclip button instead.")
      return false
    }
  }

  _mediaInput(scope) {
    if (scope === "mobile") return this.hasMobileImageInputTarget ? this.mobileImageInputTarget : null
    return this.hasDesktopImageInputTarget ? this.desktopImageInputTarget : null
  }

  _cameraInput(scope) {
    if (scope === "mobile") return this.hasMobileCameraInputTarget ? this.mobileCameraInputTarget : null
    return this.hasDesktopCameraInputTarget ? this.desktopCameraInputTarget : null
  }

  _fileInput(scope) {
    if (scope === "mobile") return this.hasMobileFileInputTarget ? this.mobileFileInputTarget : null
    return this.hasDesktopFileInputTarget ? this.desktopFileInputTarget : null
  }

  // The two kinds, each with the inputs that post under its name. Kind is decided
  // structurally rather than by sniffing the `accept` string, which says "image"
  // on an input that may be carrying a video.
  _scopeGroups(scope) {
    return [
      {
        kind: "image",
        inputs: [ this._mediaInput(scope), this._cameraInput(scope) ].filter(Boolean),
        maxSize: this.maxImageSizeValue,
        maxCount: this.maxImagesValue
      },
      {
        kind: "file",
        inputs: [ this._fileInput(scope) ].filter(Boolean),
        maxSize: this.maxFileSizeValue,
        maxCount: this.maxFilesValue
      }
    ]
  }

  _updateBadge(scope) {
    let images = 0
    let files = 0
    for (const group of this._scopeGroups(scope)) {
      const count = group.inputs.reduce((n, input) => n + (input.files?.length || 0), 0)
      if (group.kind === "image") images += count
      else files += count
    }

    const parts = []
    if (images > 0) parts.push(`${images} image${images === 1 ? "" : "s"}`)
    if (files > 0) parts.push(`${files} file${files === 1 ? "" : "s"}`)
    const text = parts.length > 0 ? `${parts.join(", ")} attached` : ""

    if (scope === "mobile" && this.hasMobileBadgeTarget) {
      this.mobileBadgeTarget.textContent = text
    }
    if (scope === "desktop" && this.hasDesktopBadgeTarget) {
      this.desktopBadgeTarget.textContent = text
    }
  }
}
