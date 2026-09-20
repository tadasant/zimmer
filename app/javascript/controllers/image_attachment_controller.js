import { Controller } from "@hotwired/stimulus"
import { csrfHeaders } from "lib/csrf"
import { partitionMedia } from "lib/media_kinds"

// Controller for handling image attachments on session prompts
// Supports: file input, paste, and drag-and-drop
//
// Drag-and-drop is not bound here. composer-drop owns the drag surface for the whole
// composer and dispatches `composer-drop:files`, which #handleComposerDrop claims the
// image files out of; file-attachment takes the rest from the same event.
//
// Works for both:
// - Follow-up prompts (existing session, uses sessionId)
// - New session creation (uses tempSessionId)
export default class extends Controller {
  //
  // preview / attachButton / cameraButton are PLURAL: the follow-up composer
  // renders a desktop row and a phone row, only one of which is on screen at a
  // time, and both have to be written to — a singular target would leave the
  // phone row showing nothing and never re-enable its buttons.
  static targets = ["input", "cameraInput", "preview", "imagesField", "attachButton", "cameraButton"]
  static values = {
    sessionId: Number,
    tempSessionId: String, // Used for new session creation before session exists
    uploadUrl: String,
    maxSize: { type: Number, default: 10 * 1024 * 1024 }, // 10MB
    maxImages: { type: Number, default: 20 }
  }

  connect() {
    this.images = []
    this.setupPasteHandler()
  }

  disconnect() {
    if (this.boundPasteHandler) {
      document.removeEventListener("paste", this.boundPasteHandler)
    }
  }

  // Setup paste event handler on the document
  setupPasteHandler() {
    this.boundPasteHandler = this.handlePaste.bind(this)
    document.addEventListener("paste", this.boundPasteHandler)
  }

  // Open the file dialog when attach button is clicked
  openFileDialog() {
    if (this.hasInputTarget) {
      this.inputTarget.click()
    }
  }

  // Open the camera dialog when camera button is clicked
  // On mobile (with capture="environment") this invokes the rear camera directly.
  // On desktop the capture attribute is ignored and a normal file picker opens.
  openCameraDialog() {
    if (this.hasCameraInputTarget) {
      this.cameraInputTarget.click()
    } else if (this.hasInputTarget) {
      this.inputTarget.click()
    }
  }

  // Handle file input change.
  //
  // The picker accepts everything a phone's media library holds, which is wider
  // than the four types the image path can store: an iPhone still is HEIC and a
  // phone video is QuickTime or MP4. Those are handed off to file-attachment via
  // `image-attachment:mediaHandoff` (wired on the composer, the same way
  // `composer-drop:files` is) so they reach the agent as files instead of being
  // rejected by the upload endpoint.
  handleFileSelect(event) {
    const { images, files } = partitionMedia(event.target.files)
    // Reset the input so the same file can be selected again
    event.target.value = ""

    if (files.length > 0) {
      this.dispatch("mediaHandoff", { detail: { files: files } })
    }
    if (images.length > 0) {
      this.uploadFiles(images)
    }
  }

  // Handle paste events
  handlePaste(event) {
    // Only handle if the paste target is within our controller or a textarea
    const target = event.target
    const isOurTextarea = target.tagName === "TEXTAREA" &&
                          (target.id.includes("follow_up_textarea") || target.closest("[data-controller~='image-attachment']"))

    if (!isOurTextarea) return

    const items = event.clipboardData?.items
    if (!items) return

    const imageFiles = []
    for (const item of items) {
      if (item.type.startsWith("image/")) {
        const file = item.getAsFile()
        if (file) {
          imageFiles.push(file)
        }
      }
    }

    if (imageFiles.length === 0) return

    event.preventDefault()
    // Same split as the picker: a phone keyboard can hand over a HEIC, which the
    // image path would reject. file-attachment takes those.
    const { images, files } = partitionMedia(imageFiles)
    if (files.length > 0) this.dispatch("mediaHandoff", { detail: { files: files } })
    if (images.length > 0) this.uploadFiles(images)
  }

  // Files dropped on the composer, routed here by composer-drop. Only top-level
  // images are claimed; file-attachment handles everything else, including images
  // found inside a dropped folder (this controller does not walk folders).
  handleComposerDrop(event) {
    const files = event.detail?.dataTransfer?.files
    if (!files) return

    // Same split as the media picker, and for the same reason: a dropped HEIC or
    // .mov is an image to the OS but not to the image path. file-attachment reads
    // the complement of this filter off the same event, so nothing is dropped twice
    // and nothing is dropped by neither.
    const { images } = partitionMedia(files)
    if (images.length > 0) {
      this.uploadFiles(images)
    }
  }

  // Upload files to the server
  async uploadFiles(files) {
    // Check max images limit
    if (this.images.length + files.length > this.maxImagesValue) {
      alert(`Maximum ${this.maxImagesValue} images allowed`)
      return
    }

    // Oversize images are dropped individually rather than failing the whole
    // selection. A phone multi-select is one tap over a grid of photos, and one
    // 12MP panorama in it should not silently discard the other nine.
    const maxMb = Math.round(this.maxSizeValue / (1024 * 1024))
    const tooLarge = files.filter(file => file.size > this.maxSizeValue)
    const withinLimit = files.filter(file => file.size <= this.maxSizeValue)

    if (tooLarge.length > 0) {
      const names = tooLarge.map(file => `"${file.name}"`).join(", ")
      alert(`${names} ${tooLarge.length === 1 ? "is" : "are"} over the ${maxMb}MB image limit and ${tooLarge.length === 1 ? "was" : "were"} not attached.`)
    }
    if (withinLimit.length === 0) return
    files = withinLimit

    // Show loading state
    this.showLoading()

    try {
      // For each file, read as base64 and upload
      const uploadPromises = files.map(file => this.uploadSingleFile(file))
      const results = await Promise.all(uploadPromises)

      // Add successfully uploaded images
      for (const result of results) {
        if (result && result.images) {
          this.images.push(...result.images)
        }
      }

      this.updatePreview()
      this.updateHiddenField()
    } catch (error) {
      console.error("Failed to upload images:", error)
      alert("Failed to upload one or more images. Please try again.")
    } finally {
      this.hideLoading()
    }
  }

  // Upload a single file
  async uploadSingleFile(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader()

      reader.onload = async (e) => {
        try {
          const base64Data = e.target.result

          // Build request body, including temp_session_id if this is a new session form
          const requestBody = {
            images: [{
              data: base64Data,
              filename: file.name
            }]
          }

          // For new session creation, include temp_session_id so the server knows
          // which temp directory to store images in
          if (this.hasTempSessionIdValue && this.tempSessionIdValue) {
            requestBody.temp_session_id = this.tempSessionIdValue
          }

          const response = await fetch(this.uploadUrlValue, {
            method: "POST",
            headers: csrfHeaders(),
            body: JSON.stringify(requestBody)
          })

          if (!response.ok) {
            let errorMessage = "Upload failed"
            try {
              const errorData = await response.json()
              errorMessage = errorData.error || errorMessage
            } catch (e) {
              // Server returned non-JSON response (e.g., HTML error page)
            }
            throw new Error(errorMessage)
          }

          const data = await response.json()
          resolve(data)
        } catch (error) {
          reject(error)
        }
      }

      reader.onerror = () => reject(new Error("Failed to read file"))
      reader.readAsDataURL(file)
    })
  }

  // Remove an image from the list
  removeImage(event) {
    const index = parseInt(event.currentTarget.dataset.index, 10)
    this.images.splice(index, 1)
    this.updatePreview()
    this.updateHiddenField()
  }

  // Update the preview display
  updatePreview() {
    if (this.previewTargets.length === 0) return

    if (this.images.length === 0) {
      for (const preview of this.previewTargets) {
        preview.innerHTML = ""
        preview.classList.add("hidden")
      }
      return
    }

    for (const preview of this.previewTargets) {
      preview.classList.remove("hidden")
    }

    const html = this.images.map((img, index) => `
      <div class="relative inline-block group">
        <div class="w-16 h-16 rounded-lg border border-gray-300 bg-gray-100 flex items-center justify-center overflow-hidden">
          ${this.getImagePreviewHtml(img)}
        </div>
        <button type="button"
                class="absolute -top-2 -right-2 w-5 h-5 bg-red-500 text-white rounded-full flex items-center justify-center hover:bg-red-600 opacity-0 group-hover:opacity-100 transition-opacity"
                data-action="click->image-attachment#removeImage"
                data-index="${index}"
                title="Remove image">
          <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/>
          </svg>
        </button>
      </div>
    `).join("")

    const markup = `
      <div class="flex flex-wrap gap-2 p-2 bg-gray-50 rounded-lg border border-gray-200">
        <div class="flex items-center gap-1 text-xs text-gray-500 mr-2">
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 16l4.586-4.586a2 2 0 012.828 0L16 16m-2-2l1.586-1.586a2 2 0 012.828 0L20 14m-6-6h.01M6 20h12a2 2 0 002-2V6a2 2 0 00-2-2H6a2 2 0 00-2 2v12a2 2 0 002 2z"/>
          </svg>
          <span>${this.images.length} image${this.images.length > 1 ? 's' : ''}</span>
        </div>
        ${html}
      </div>
    `
    for (const preview of this.previewTargets) {
      preview.innerHTML = markup
    }
  }

  // Get HTML for image preview (icon or thumbnail)
  getImagePreviewHtml(img) {
    // For now, show a file icon with the media type
    const typeLabel = img.media_type.split('/')[1].toUpperCase()
    return `
      <div class="text-center">
        <svg class="w-8 h-8 text-gray-400 mx-auto" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 16l4.586-4.586a2 2 0 012.828 0L16 16m-2-2l1.586-1.586a2 2 0 012.828 0L20 14m-6-6h.01M6 20h12a2 2 0 002-2V6a2 2 0 00-2-2H6a2 2 0 00-2 2v12a2 2 0 002 2z"/>
        </svg>
        <span class="text-[10px] text-gray-500">${typeLabel}</span>
      </div>
    `
  }

  // Update the hidden field with image data
  updateHiddenField() {
    if (!this.hasImagesFieldTarget) return

    // Store as JSON array of { path, media_type }
    this.imagesFieldTarget.value = JSON.stringify(
      this.images.map(img => ({
        path: img.path,
        media_type: img.media_type
      }))
    )
  }

  // Show loading indicator on attach buttons
  showLoading() {
    this.setButtonsDisabled(true)
  }

  // Hide loading indicator
  hideLoading() {
    this.setButtonsDisabled(false)
  }

  // Every attach button in this composer, desktop row and phone row alike.
  setButtonsDisabled(disabled) {
    for (const button of [ ...this.attachButtonTargets, ...this.cameraButtonTargets ]) {
      button.disabled = disabled
      button.classList.toggle("opacity-50", disabled)
    }
  }

  // Clear all images (called after successful form submission)
  clearImages() {
    this.images = []
    this.updatePreview()
    this.updateHiddenField()
  }

  // Public method to get current images for form submission
  getImages() {
    return this.images
  }
}
