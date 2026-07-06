import { Controller } from "@hotwired/stimulus"

// Floating chat bubble that appears on every page.
//
// - Click the bubble icon to open a slide-out panel with a textarea
// - Cmd/Ctrl+Enter submits in the background (session runs silently)
// - "Submit & Open" button creates the session and navigates to it
// - Automatically captures the current page HTML as markdown context
// - Escape key closes the panel
export default class extends Controller {
  static targets = [
    "panel",
    "textarea",
    "submitButton",
    "submitOpenButton",
    "overlay",
    "badge",
    "error",
    "imageInput",
    "cameraInput",
    "fileInput",
    "preview"
  ]

  static values = {
    open: { type: Boolean, default: false },
    submitUrl: String,
    promptMaxLength: { type: Number, default: 500000 },
    maxImageSize: { type: Number, default: 10 * 1024 * 1024 }, // 10MB
    maxImages: { type: Number, default: 20 },
    maxFileSize: { type: Number, default: 500 * 1024 * 1024 }, // 500MB
    maxFiles: { type: Number, default: 20 }
  }

  connect() {
    this.submitting = false
    this.attachedImages = []
    this.attachedFiles = []
    // Listen for keyboard shortcut to open bubble (Cmd/Ctrl+K)
    this.handleGlobalKeydown = this._handleGlobalKeydown.bind(this)
    document.addEventListener("keydown", this.handleGlobalKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this.handleGlobalKeydown)
  }

  // ---- Toggle ----

  toggle() {
    this.openValue = !this.openValue
  }

  open() {
    this.openValue = true
  }

  close() {
    this.openValue = false
  }

  openValueChanged() {
    if (this.openValue) {
      this.panelTarget.classList.remove("translate-x-full", "opacity-0", "pointer-events-none")
      this.panelTarget.classList.add("translate-x-0", "opacity-100")
      this.overlayTarget.classList.remove("hidden")
      requestAnimationFrame(() => this.textareaTarget.focus())
    } else {
      this.panelTarget.classList.add("translate-x-full", "opacity-0", "pointer-events-none")
      this.panelTarget.classList.remove("translate-x-0", "opacity-100")
      this.overlayTarget.classList.add("hidden")
    }
  }

  // ---- Keyboard ----

  _handleGlobalKeydown(event) {
    // Cmd/Ctrl+K to toggle the bubble
    if (event.key === "k" && (event.metaKey || event.ctrlKey)) {
      event.preventDefault()
      this.toggle()
    }
  }

  handleKeydown(event) {
    if (event.key === "Escape") {
      event.preventDefault()
      this.close()
      return
    }
    // Cmd/Ctrl+Enter to submit in background
    if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
      event.preventDefault()
      this.submitBackground()
    }
  }

  // ---- Context capture ----

  capturePageContext() {
    // Clone the body and remove the chat bubble itself to avoid self-reference
    const clone = document.body.cloneNode(true)
    const bubble = clone.querySelector("[data-controller='chat-bubble']")
    if (bubble) bubble.remove()

    // Remove scripts, styles, SVGs, and hidden elements
    clone.querySelectorAll("script, style, link, svg, [hidden], .hidden, [aria-hidden='true']").forEach(el => el.remove())

    return this._htmlToMarkdown(clone)
  }

  _htmlToMarkdown(element) {
    const lines = []
    const maxLength = 20000 // Cap context to preserve tokens
    let currentLength = 0

    const walk = (node) => {
      if (currentLength > maxLength) return

      if (node.nodeType === Node.TEXT_NODE) {
        const text = node.textContent.trim()
        if (text) {
          lines.push(text)
          currentLength += text.length + 1
        }
        return
      }

      if (node.nodeType !== Node.ELEMENT_NODE) return

      const tag = node.tagName.toLowerCase()

      switch (tag) {
        case "h1":
          lines.push(`\n# ${node.textContent.trim()}`)
          return
        case "h2":
          lines.push(`\n## ${node.textContent.trim()}`)
          return
        case "h3":
          lines.push(`\n### ${node.textContent.trim()}`)
          return
        case "h4":
        case "h5":
        case "h6":
          lines.push(`\n${"#".repeat(parseInt(tag[1]))} ${node.textContent.trim()}`)
          return
        case "p":
          lines.push(`\n${node.textContent.trim()}`)
          return
        case "a": {
          const href = node.getAttribute("href")
          const text = node.textContent.trim()
          if (href && text) {
            lines.push(`[${text}](${href})`)
          } else if (text) {
            lines.push(text)
          }
          return
        }
        case "li":
          lines.push(`- ${node.textContent.trim()}`)
          return
        case "strong":
        case "b":
          lines.push(`**${node.textContent.trim()}**`)
          return
        case "em":
        case "i":
          lines.push(`*${node.textContent.trim()}*`)
          return
        case "code":
          lines.push(`\`${node.textContent.trim()}\``)
          return
        case "pre":
          lines.push(`\n\`\`\`\n${node.textContent.trim()}\n\`\`\``)
          return
        case "br":
          lines.push("")
          return
        case "hr":
          lines.push("\n---")
          return
        case "img": {
          const alt = node.getAttribute("alt") || "image"
          lines.push(`[${alt}]`)
          return
        }
        case "table":
          lines.push(`\n${this._tableToMarkdown(node)}`)
          return
        default:
          // Recurse into children
          for (const child of node.childNodes) {
            walk(child)
          }
      }
    }

    walk(element)

    let result = lines.join("\n").replace(/\n{3,}/g, "\n\n").trim()
    if (result.length > maxLength) {
      result = result.substring(0, maxLength) + "\n\n[...truncated]"
    }
    return result
  }

  _tableToMarkdown(table) {
    const rows = []
    let separatorAdded = false
    for (const row of table.querySelectorAll("tr")) {
      const cells = Array.from(row.querySelectorAll("th, td")).map(c => c.textContent.trim())
      rows.push(`| ${cells.join(" | ")} |`)
      if (row.querySelector("th") && !separatorAdded) {
        rows.push(`| ${cells.map(() => "---").join(" | ")} |`)
        separatorAdded = true
      }
    }
    return rows.join("\n")
  }

  // ---- Attachments ----

  openImageDialog() {
    if (this.hasImageInputTarget) this.imageInputTarget.click()
  }

  openCameraDialog() {
    if (this.hasCameraInputTarget) this.cameraInputTarget.click()
  }

  openFileDialog() {
    if (this.hasFileInputTarget) this.fileInputTarget.click()
  }

  handleImageSelect(event) {
    const files = Array.from(event.target.files || [])
    event.target.value = ""
    if (files.length === 0) return

    if (this.attachedImages.length + files.length > this.maxImagesValue) {
      this._showError(`Maximum ${this.maxImagesValue} images allowed.`)
      return
    }
    for (const f of files) {
      if (f.size > this.maxImageSizeValue) {
        this._showError(`Image "${f.name}" is too large (max ${Math.round(this.maxImageSizeValue / (1024 * 1024))}MB).`)
        return
      }
    }
    this.attachedImages.push(...files)
    this._renderPreview()
  }

  handleFileSelect(event) {
    const files = Array.from(event.target.files || [])
    event.target.value = ""
    if (files.length === 0) return

    if (this.attachedFiles.length + files.length > this.maxFilesValue) {
      this._showError(`Maximum ${this.maxFilesValue} files allowed.`)
      return
    }
    for (const f of files) {
      if (f.size > this.maxFileSizeValue) {
        this._showError(`File "${f.name}" is too large (max ${Math.round(this.maxFileSizeValue / (1024 * 1024))}MB).`)
        return
      }
    }
    this.attachedFiles.push(...files)
    this._renderPreview()
  }

  // Catch pasted images and attach them as files
  handlePaste(event) {
    const items = event.clipboardData?.items
    if (!items) return
    const imageFiles = []
    for (const item of items) {
      if (item.type && item.type.startsWith("image/")) {
        const f = item.getAsFile()
        if (f) imageFiles.push(f)
      }
    }
    if (imageFiles.length > 0) {
      event.preventDefault()
      if (this.attachedImages.length + imageFiles.length > this.maxImagesValue) {
        this._showError(`Maximum ${this.maxImagesValue} images allowed.`)
        return
      }
      this.attachedImages.push(...imageFiles)
      this._renderPreview()
    }
  }

  removeImage(event) {
    const idx = parseInt(event.currentTarget.dataset.index, 10)
    if (!isNaN(idx)) {
      this.attachedImages.splice(idx, 1)
      this._renderPreview()
    }
  }

  removeFile(event) {
    const idx = parseInt(event.currentTarget.dataset.index, 10)
    if (!isNaN(idx)) {
      this.attachedFiles.splice(idx, 1)
      this._renderPreview()
    }
  }

  _renderPreview() {
    if (!this.hasPreviewTarget) return
    const total = this.attachedImages.length + this.attachedFiles.length
    if (total === 0) {
      this.previewTarget.innerHTML = ""
      this.previewTarget.classList.add("hidden")
      return
    }
    this.previewTarget.classList.remove("hidden")

    const escape = (s) => s.replace(/[&<>"']/g, (c) => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;"}[c]))

    const imageChips = this.attachedImages.map((f, i) => `
      <div class="relative inline-flex items-center gap-1 bg-indigo-50 text-indigo-700 px-2 py-1 rounded text-[11px] border border-indigo-200">
        <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 16l4.586-4.586a2 2 0 012.828 0L16 16m-2-2l1.586-1.586a2 2 0 012.828 0L20 14m-6-6h.01M6 20h12a2 2 0 002-2V6a2 2 0 00-2-2H6a2 2 0 00-2 2v12a2 2 0 002 2z"/>
        </svg>
        <span class="truncate max-w-[120px]" title="${escape(f.name)}">${escape(f.name)}</span>
        <button type="button" data-action="chat-bubble#removeImage" data-index="${i}" class="ml-1 text-indigo-500 hover:text-indigo-700" aria-label="Remove">×</button>
      </div>
    `).join("")

    const fileChips = this.attachedFiles.map((f, i) => `
      <div class="relative inline-flex items-center gap-1 bg-gray-100 text-gray-700 px-2 py-1 rounded text-[11px] border border-gray-200">
        <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15.172 7l-6.586 6.586a2 2 0 102.828 2.828l6.414-6.586a4 4 0 00-5.656-5.656l-6.415 6.585a6 6 0 108.486 8.486L20.5 13"/>
        </svg>
        <span class="truncate max-w-[120px]" title="${escape(f.name)}">${escape(f.name)}</span>
        <button type="button" data-action="chat-bubble#removeFile" data-index="${i}" class="ml-1 text-gray-500 hover:text-gray-700" aria-label="Remove">×</button>
      </div>
    `).join("")

    this.previewTarget.innerHTML = `<div class="flex flex-wrap gap-1.5">${imageChips}${fileChips}</div>`
  }

  // ---- Submission ----

  async submitBackground() {
    await this._submit(false)
  }

  async submitAndOpen() {
    await this._submit(true)
  }

  async _submit(openSession) {
    if (this.submitting) return

    const prompt = this.textareaTarget.value.trim()
    if (!prompt) {
      this.textareaTarget.focus()
      return
    }

    if (prompt.length > this.promptMaxLengthValue) {
      this._showError(`Prompt is too long (maximum ${this.promptMaxLengthValue.toLocaleString()} characters).`)
      return
    }

    this.submitting = true
    this._setButtonsLoading(true)

    try {
      const pageContext = this.capturePageContext()
      const csrfToken = document.querySelector("meta[name='csrf-token']")?.content

      // Use FormData to support multipart file uploads alongside text fields.
      const body = new FormData()
      body.append("prompt", prompt)
      body.append("page_context", pageContext)
      body.append("current_url", window.location.href)

      // When on a session detail page, set the parent session ID so the
      // router session is created as a child of the viewed session.
      const sessionId = this._currentSessionId()
      if (sessionId) {
        body.append("parent_session_id", String(sessionId))
      }

      for (const f of this.attachedImages) body.append("images[]", f, f.name)
      for (const f of this.attachedFiles) body.append("files[]", f, f.name)

      const response = await fetch(this.submitUrlValue, {
        method: "POST",
        headers: {
          // Do NOT set Content-Type — the browser will set it (with boundary) for FormData.
          "X-CSRF-Token": csrfToken,
          "Accept": "application/json"
        },
        body: body
      })

      const data = await response.json()

      if (!response.ok) {
        this._showError(data.error || "Failed to create session")
        return
      }

      // Clear and close
      this.textareaTarget.value = ""
      this.attachedImages = []
      this.attachedFiles = []
      this._renderPreview()
      this.close()

      if (openSession && data.session_url) {
        window.location.href = data.session_url
      } else {
        // Flash a brief success indicator on the bubble
        this._showSuccessBadge()
      }
    } catch (error) {
      console.error("Chat bubble submission failed:", error)
      this._showError("Something went wrong. Please try again.")
    } finally {
      this.submitting = false
      this._setButtonsLoading(false)
    }
  }

  _setButtonsLoading(loading) {
    if (loading) {
      this.submitButtonTarget.disabled = true
      this.submitOpenButtonTarget.disabled = true
      this.submitButtonTarget.dataset.originalText = this.submitButtonTarget.textContent
      this.submitOpenButtonTarget.dataset.originalText = this.submitOpenButtonTarget.textContent
      this.submitButtonTarget.textContent = "Submitting..."
      this.submitOpenButtonTarget.textContent = "Submitting..."
      this.textareaTarget.readOnly = true
    } else {
      this.submitButtonTarget.disabled = false
      this.submitOpenButtonTarget.disabled = false
      this.submitButtonTarget.textContent = this.submitButtonTarget.dataset.originalText || "Submit"
      this.submitOpenButtonTarget.textContent = this.submitOpenButtonTarget.dataset.originalText || "Submit & Open"
      this.textareaTarget.readOnly = false
    }
  }

  _showError(message) {
    if (!this.hasErrorTarget) return
    this.errorTarget.textContent = message
    this.errorTarget.classList.remove("hidden")
    // Auto-hide after 5 seconds
    clearTimeout(this._errorTimeout)
    this._errorTimeout = setTimeout(() => {
      this.errorTarget.classList.add("hidden")
    }, 5000)
  }

  _showSuccessBadge() {
    if (!this.hasBadgeTarget) return
    this.badgeTarget.classList.remove("hidden")
    clearTimeout(this._badgeTimeout)
    this._badgeTimeout = setTimeout(() => {
      this.badgeTarget.classList.add("hidden")
    }, 2500)
  }

  // Returns the numeric session ID when the current page is a session detail
  // page (e.g. /sessions/123 or /sessions/my-slug). Returns null otherwise.
  _currentSessionId() {
    const match = window.location.pathname.match(/^\/sessions\/([^/]+)$/)
    if (!match) return null

    // Prefer a dedicated data attribute on the show page's root element.
    // Uses "data-current-session-id" to avoid collisions with session card
    // elements that also carry a generic "data-session-id".
    const el = document.querySelector("[data-current-session-id]")
    if (el) return parseInt(el.dataset.currentSessionId, 10) || null

    // Fallback: if the URL segment is numeric, use it directly.
    const id = parseInt(match[1], 10)
    return isNaN(id) ? null : id
  }
}
