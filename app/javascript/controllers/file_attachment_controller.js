import { Controller } from "@hotwired/stimulus"

// Controller for handling general file attachments on session prompts.
// Sibling to image_attachment_controller — supports drag-and-drop and the
// file picker for arbitrary files (text, source code, logs, JSON, CSV, PDFs, etc.).
//
// Works for both:
// - Follow-up prompts (existing session, uses sessionId)
// - New session creation (uses tempSessionId)
export default class extends Controller {
  static targets = ["input", "folderInput", "preview", "filesField", "dropZone", "attachButton", "attachFolderButton", "progress"]
  static values = {
    sessionId: Number,
    tempSessionId: String,
    uploadUrl: String,
    maxSize: { type: Number, default: 500 * 1024 * 1024 }, // 500MB
    maxFiles: { type: Number, default: 200 }
  }

  connect() {
    this.files = []
    this.setupDropZone()
  }

  disconnect() {}

  // Setup drag and drop on the drop zone
  setupDropZone() {
    if (!this.hasDropZoneTarget) return

    const dropZone = this.dropZoneTarget

    dropZone.addEventListener("dragover", (e) => {
      e.preventDefault()
      e.stopPropagation()
      dropZone.classList.add("border-indigo-500", "bg-indigo-50")
    })

    dropZone.addEventListener("dragleave", (e) => {
      e.preventDefault()
      e.stopPropagation()
      dropZone.classList.remove("border-indigo-500", "bg-indigo-50")
    })

    dropZone.addEventListener("drop", async (e) => {
      e.preventDefault()
      e.stopPropagation()
      dropZone.classList.remove("border-indigo-500", "bg-indigo-50")
      await this.handleDrop(e)
    })
  }

  openFileDialog() {
    if (this.hasInputTarget) {
      this.inputTarget.click()
    }
  }

  openFolderDialog() {
    if (this.hasFolderInputTarget) {
      this.folderInputTarget.click()
    }
  }

  handleFileSelect(event) {
    const files = event.target.files
    if (files && files.length > 0) {
      this.uploadFiles(Array.from(files))
    }
    event.target.value = ""
  }

  // Drop handler that supports both files and folders. When `dataTransfer.items`
  // is available we walk each entry with `webkitGetAsEntry()` so that dropped
  // folders are recursively expanded into their constituent files. Falls back
  // to `dataTransfer.files` for browsers/cases where items aren't usable.
  //
  // Top-level files are passed through an image filter so that image_attachment
  // can claim them (the two controllers share the drop zone). Files harvested
  // from inside a dropped folder are NOT filtered — image_attachment doesn't
  // walk folders, so filtering them here would silently lose them.
  async handleDrop(e) {
    const dt = e.dataTransfer
    const collected = []

    if (dt.items && dt.items.length > 0 && typeof dt.items[0].webkitGetAsEntry === "function") {
      const entries = []
      for (const item of dt.items) {
        if (item.kind !== "file") continue
        const entry = item.webkitGetAsEntry()
        if (entry) entries.push(entry)
      }
      try {
        for (const entry of entries) {
          // Cap traversal at maxFiles + a little headroom so a hostile drop
          // (e.g. ~/) can't OOM the tab. uploadFiles() will reject the actual
          // upload above maxFiles; this just stops the walker early.
          const budget = this.maxFilesValue + 1 - collected.length
          if (budget <= 0) break

          if (entry.isFile) {
            const file = await new Promise((resolve, reject) => entry.file(resolve, reject))
            // Top-level file: defer to image controller for image MIME types.
            if (!file.type.startsWith("image/")) collected.push(file)
          } else if (entry.isDirectory) {
            // Folder contents: keep everything (including images) since
            // image_attachment never sees folders.
            const dirFiles = await this.collectFilesFromEntry(entry, budget)
            collected.push(...dirFiles)
          }
        }
      } catch (err) {
        console.error("Failed to walk dropped entries, falling back to flat files:", err)
        const flat = Array.from(dt.files || []).filter(f => !f.type.startsWith("image/"))
        collected.push(...flat)
      }
    } else {
      // Browser/source without items[]; treat as flat file list (no folders).
      const flat = Array.from(dt.files || []).filter(f => !f.type.startsWith("image/"))
      collected.push(...flat)
    }

    if (collected.length > 0) {
      this.uploadFiles(collected)
    }
  }

  // Recursively walk a FileSystemEntry and return a flat list of File objects.
  // `budget` caps the number of files collected so that an unbounded walk
  // (e.g. someone drops their home directory) bails out early instead of
  // exhausting browser memory.
  async collectFilesFromEntry(entry, budget = this.maxFilesValue + 1) {
    if (!entry || budget <= 0) return []

    if (entry.isFile) {
      const file = await new Promise((resolve, reject) => entry.file(resolve, reject))
      return [file]
    }

    if (entry.isDirectory) {
      const reader = entry.createReader()
      const collected = []
      // readEntries() may return results in batches; loop until empty.
      while (collected.length < budget) {
        const batch = await new Promise((resolve, reject) => reader.readEntries(resolve, reject))
        if (!batch || batch.length === 0) break
        for (const sub of batch) {
          if (collected.length >= budget) break
          const subFiles = await this.collectFilesFromEntry(sub, budget - collected.length)
          collected.push(...subFiles)
        }
      }
      return collected
    }

    return []
  }

  async uploadFiles(files) {
    if (this.files.length + files.length > this.maxFilesValue) {
      alert(`Maximum ${this.maxFilesValue} files allowed`)
      return
    }

    for (const file of files) {
      if (file.size > this.maxSizeValue) {
        alert(`File "${file.name}" is too large. Maximum size is ${this.maxSizeValue / (1024 * 1024)}MB`)
        return
      }
    }

    this.startProgress(files.length)

    try {
      const uploadPromises = files.map(file =>
        this.uploadSingleFile(file).then(result => {
          this.tickProgress()
          return result
        })
      )
      const results = await Promise.all(uploadPromises)

      for (const result of results) {
        if (result && result.files) {
          this.files.push(...result.files)
        }
      }

      this.updatePreview()
      this.updateHiddenField()
    } catch (error) {
      console.error("Failed to upload files:", error)
      alert("Failed to upload one or more files. Please try again.")
    } finally {
      this.endProgress()
    }
  }

  async uploadSingleFile(file) {
    const formData = new FormData()
    formData.append("files[]", file)

    if (this.hasTempSessionIdValue && this.tempSessionIdValue) {
      formData.append("temp_session_id", this.tempSessionIdValue)
    }

    const response = await fetch(this.uploadUrlValue, {
      method: "POST",
      headers: {
        "X-CSRF-Token": this.getCSRFToken()
      },
      body: formData
    })

    if (!response.ok) {
      let errorMessage = "Upload failed"
      try {
        const errorData = await response.json()
        errorMessage = errorData.error || errorMessage
      } catch (e) {
        // non-JSON response
      }
      throw new Error(errorMessage)
    }

    return await response.json()
  }

  removeFile(event) {
    const index = parseInt(event.currentTarget.dataset.index, 10)
    this.files.splice(index, 1)
    this.updatePreview()
    this.updateHiddenField()
  }

  updatePreview() {
    if (!this.hasPreviewTarget) return

    if (this.files.length === 0) {
      this.previewTarget.innerHTML = ""
      this.previewTarget.classList.add("hidden")
      return
    }

    this.previewTarget.classList.remove("hidden")

    const html = this.files.map((f, index) => `
      <div class="relative inline-flex items-center gap-2 bg-white border border-gray-300 rounded-md px-2 py-1 text-xs group">
        <svg class="w-4 h-4 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"/>
        </svg>
        <span class="text-gray-700 max-w-[180px] truncate" title="${this.escapeHtml(f.original_filename)}">${this.escapeHtml(f.original_filename)}</span>
        <span class="text-gray-400">${this.formatSize(f.size)}</span>
        <button type="button"
                class="text-gray-400 hover:text-red-600"
                data-action="click->file-attachment#removeFile"
                data-index="${index}"
                title="Remove file">
          <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/>
          </svg>
        </button>
      </div>
    `).join("")

    this.previewTarget.innerHTML = `
      <div class="flex flex-wrap gap-2 p-2 bg-gray-50 rounded-lg border border-gray-200">
        <div class="flex items-center gap-1 text-xs text-gray-500 mr-2">
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15.172 7l-6.586 6.586a2 2 0 102.828 2.828l6.414-6.586a4 4 0 00-5.656-5.656l-6.415 6.585a6 6 0 108.486 8.486L20.5 13"/>
          </svg>
          <span>${this.files.length} file${this.files.length > 1 ? 's' : ''}</span>
        </div>
        ${html}
      </div>
    `
  }

  updateHiddenField() {
    if (!this.hasFilesFieldTarget) return

    this.filesFieldTarget.value = JSON.stringify(
      this.files.map(f => ({
        path: f.path,
        original_filename: f.original_filename,
        size: f.size
      }))
    )
  }

  // Progress UX: a visible banner with a spinner, "Uploading X / Y" text,
  // and a fill bar. Buttons are disabled so the user can't trigger another
  // upload before this one finishes (which would race against the same
  // `this.files` list).
  startProgress(total) {
    this.uploadTotal = total
    this.uploadCompleted = 0
    this.setButtonsDisabled(true)
    this.renderProgress()
  }

  tickProgress() {
    this.uploadCompleted = (this.uploadCompleted || 0) + 1
    this.renderProgress()
  }

  endProgress() {
    this.uploadTotal = 0
    this.uploadCompleted = 0
    this.setButtonsDisabled(false)
    if (this.hasProgressTarget) {
      this.progressTarget.innerHTML = ""
      this.progressTarget.classList.add("hidden")
    }
  }

  renderProgress() {
    if (!this.hasProgressTarget) return
    const total = this.uploadTotal || 0
    const done = Math.min(this.uploadCompleted || 0, total)
    const pct = total === 0 ? 0 : Math.round((done / total) * 100)
    this.progressTarget.classList.remove("hidden")
    this.progressTarget.innerHTML = `
      <div class="flex items-center gap-3 p-2 bg-indigo-50 border border-indigo-200 rounded-lg">
        <svg class="w-4 h-4 text-indigo-600 animate-spin flex-shrink-0" fill="none" viewBox="0 0 24 24">
          <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
          <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8v4a4 4 0 00-4 4H4z"></path>
        </svg>
        <div class="flex-1 min-w-0">
          <div class="text-xs text-indigo-900 font-medium">
            Uploading ${done} / ${total} file${total === 1 ? '' : 's'}…
          </div>
          <div class="mt-1 h-1.5 w-full bg-indigo-100 rounded-full overflow-hidden">
            <div class="h-full bg-indigo-600 transition-[width] duration-150" style="width: ${pct}%"></div>
          </div>
        </div>
      </div>
    `
  }

  setButtonsDisabled(disabled) {
    const targets = []
    if (this.hasAttachButtonTarget) targets.push(this.attachButtonTarget)
    if (this.hasAttachFolderButtonTarget) targets.push(this.attachFolderButtonTarget)
    for (const target of targets) {
      target.disabled = disabled
      target.classList.toggle("opacity-50", disabled)
      target.classList.toggle("cursor-not-allowed", disabled)
    }
  }

  getCSRFToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }

  clearFiles() {
    this.files = []
    this.updatePreview()
    this.updateHiddenField()
  }

  getFiles() {
    return this.files
  }

  formatSize(bytes) {
    if (bytes < 1024) return `${bytes} B`
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
  }

  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}
