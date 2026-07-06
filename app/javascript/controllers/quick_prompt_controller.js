import { Controller } from "@hotwired/stimulus"

// Handles the dashboard quick prompt:
//
// Desktop:
// - Cmd+Enter (Mac) / Ctrl+Enter (Windows/Linux) to submit
// - Textarea is vertically resizable via drag handle
// - Prevents double-submission
// - Image / camera / file attach buttons forward clicks to hidden file inputs
//   (capture="environment" makes the camera button open the rear camera on mobile)
//
// Mobile:
// - Tappable pill opens full-screen overlay editor
// - X button or Escape key dismisses the overlay
// - Dedicated Submit button at the bottom of the screen
// - Attach buttons mirror the desktop behavior
// - Double-submit protection
//
// Client-side guards reject oversize files and excess counts before the form
// posts so the user gets immediate feedback instead of a server-side redirect
// with a flash. Values are sourced from server-side constants via data attrs.
export default class extends Controller {
  static targets = [
    "textarea",            // desktop textarea
    "desktopForm",         // desktop form
    "desktopImageInput",   // desktop image picker
    "desktopCameraInput",  // desktop camera input (capture="environment")
    "desktopFileInput",    // desktop file picker
    "desktopBadge",        // desktop "N attached" hint
    "mobileOverlay",       // full-screen overlay (mobile)
    "mobileTextarea",      // textarea inside overlay
    "mobileForm",          // form inside overlay
    "mobileSubmit",        // submit button (disabled during submission)
    "mobileImageInput",    // mobile image picker
    "mobileCameraInput",   // mobile camera input
    "mobileFileInput",     // mobile file picker
    "mobileBadge"          // mobile "N attached" hint
  ]

  static values = {
    maxImageSize: { type: Number, default: 10 * 1024 * 1024 }, // 10MB
    maxImages: { type: Number, default: 20 },
    maxFileSize: { type: Number, default: 500 * 1024 * 1024 }, // 500MB
    maxFiles: { type: Number, default: 200 }
  }

  connect() {
    this.submitting = false
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
    this.textareaTarget.readOnly = true
    this.desktopFormTarget.requestSubmit()
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
    if (event && !this._validateInputChange(event, "desktop")) return
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
    this.updateMobileBadge()
  }

  closeMobileOnEscape(event) {
    if (event.key === "Escape") {
      this.closeMobile()
    }
  }

  submitMobile(event) {
    if (this.submitting) {
      event.preventDefault()
      return
    }
    this.submitting = true
    this.mobileSubmitTarget.disabled = true
    this.mobileSubmitTarget.textContent = "Submitting…"
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
    if (event && !this._validateInputChange(event, "mobile")) return
    this._updateBadge("mobile")
  }

  // ---- Internal ----

  // Inspect the changed input and reject if it would push us over count or
  // size limits. Returns true if the selection is acceptable, false otherwise.
  // On rejection, clears the input and surfaces an alert.
  _validateInputChange(event, scope) {
    const input = event?.target
    if (!input || !input.files) return true

    const files = Array.from(input.files)
    if (files.length === 0) return true

    const isImage = (input.accept || "").includes("image")
    const maxSize = isImage ? this.maxImageSizeValue : this.maxFileSizeValue
    const maxCount = isImage ? this.maxImagesValue : this.maxFilesValue
    const sizeMb = Math.round(maxSize / (1024 * 1024))
    const kind = isImage ? "image" : "file"

    for (const f of files) {
      if (f.size > maxSize) {
        input.value = ""
        window.alert(`${kind === "image" ? "Image" : "File"} "${f.name}" is too large (max ${sizeMb}MB).`)
        return false
      }
    }

    // Count combined images / files separately across both inputs of the same
    // kind in this scope (image input + camera input both count as "images").
    const sameKindTotal = this._countAttached(scope, isImage)
    if (sameKindTotal > maxCount) {
      input.value = ""
      window.alert(`Maximum ${maxCount} ${kind}${maxCount === 1 ? "" : "s"} allowed.`)
      return false
    }

    return true
  }

  _countAttached(scope, isImage) {
    const inputs = this._scopeInputs(scope)
    let total = 0
    for (const input of inputs) {
      if (!input || !input.files) continue
      const inputIsImage = (input.accept || "").includes("image")
      if (inputIsImage === isImage) total += input.files.length
    }
    return total
  }

  _scopeInputs(scope) {
    return scope === "mobile"
      ? [this.hasMobileImageInputTarget && this.mobileImageInputTarget,
         this.hasMobileCameraInputTarget && this.mobileCameraInputTarget,
         this.hasMobileFileInputTarget && this.mobileFileInputTarget]
      : [this.hasDesktopImageInputTarget && this.desktopImageInputTarget,
         this.hasDesktopCameraInputTarget && this.desktopCameraInputTarget,
         this.hasDesktopFileInputTarget && this.desktopFileInputTarget]
  }

  _updateBadge(scope) {
    const inputs = this._scopeInputs(scope)

    let images = 0
    let files = 0
    for (const input of inputs) {
      if (!input || !input.files) continue
      const isImage = (input.accept || "").includes("image")
      if (isImage) images += input.files.length
      else files += input.files.length
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
