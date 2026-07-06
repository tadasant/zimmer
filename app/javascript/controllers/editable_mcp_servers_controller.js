import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="editable-mcp-servers"
// Inline editor for MCP servers on the session detail page
export default class extends Controller {
  static targets = ["display", "editor", "input", "dropdown", "selectedContainer", "status", "saveButton"]
  static values = {
    sessionId: Number,
    servers: Array, // Currently selected server names (configured only)
    injectedServers: Array, // Auto-injected server names (read-only)
    availableServers: Array // Array of {name, title, description} objects
  }

  connect() {
    this.serversList = this.availableServersValue || []
    this.selectedServers = new Set(this.serversValue || [])
    this.originalServers = new Set(this.serversValue || [])
    this.filteredServers = []
    this.selectedIndex = -1
    this.isEditing = false

    // Close dropdown when clicking outside
    this.boundHandleClickOutside = this.handleClickOutside.bind(this)
    document.addEventListener('click', this.boundHandleClickOutside)

    // Reposition dropdown on scroll (needed for fixed positioning)
    this.boundHandleScroll = this.handleScroll.bind(this)
    window.addEventListener('scroll', this.boundHandleScroll, true)
  }

  disconnect() {
    document.removeEventListener('click', this.boundHandleClickOutside)
    window.removeEventListener('scroll', this.boundHandleScroll, true)
  }

  handleScroll() {
    // Reposition the dropdown if it's visible
    if (!this.dropdownTarget.classList.contains("hidden")) {
      this.repositionDropdown()
    }
  }

  repositionDropdown() {
    const inputRect = this.inputTarget.getBoundingClientRect()
    this.dropdownTarget.style.top = `${inputRect.bottom}px`
    this.dropdownTarget.style.left = `${inputRect.left}px`
    // Update width in case viewport changed
    const maxWidth = window.innerWidth - 32
    this.dropdownTarget.style.width = `${Math.min(Math.max(inputRect.width, 400), maxWidth)}px`
  }

  edit() {
    this.isEditing = true
    this.displayTarget.classList.add("hidden")
    this.editorTarget.classList.remove("hidden")
    this.updateSelectedDisplay()
    this.inputTarget.focus()
  }

  cancel() {
    this.isEditing = false
    this.selectedServers = new Set(this.originalServers)
    this.editorTarget.classList.add("hidden")
    this.displayTarget.classList.remove("hidden")
    this.hideDropdown()
    this.statusTarget.textContent = ""
  }

  async save() {
    const serverArray = Array.from(this.selectedServers)

    // Disable save button to prevent double-submit
    if (this.hasSaveButtonTarget) {
      this.saveButtonTarget.disabled = true
    }

    this.statusTarget.textContent = "Saving..."
    this.statusTarget.classList.remove("text-red-500", "text-green-500")
    this.statusTarget.classList.add("text-gray-500")

    try {
      const response = await fetch(`/sessions/${this.sessionIdValue}/update_mcp_servers`, {
        method: 'PATCH',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content,
          'Accept': 'text/vnd.turbo-stream.html, application/json'
        },
        body: JSON.stringify({ mcp_servers: serverArray })
      })

      if (response.ok) {
        const contentType = response.headers.get('Content-Type') || ''

        if (contentType.includes('text/vnd.turbo-stream.html')) {
          // The server replaced the relevant DOM regions in place. The current
          // controller instance is being detached as part of the swap, so we don't
          // need to update local DOM state — the new partial is already in display
          // mode and the new Stimulus instance will initialize fresh.
          const html = await response.text()
          Turbo.renderStreamMessage(html)
        } else {
          // Fallback: server returned JSON instead of a stream (older clients,
          // unexpected content negotiation). Keep prior behavior of swapping back
          // to display mode without a page reload.
          this.originalServers = new Set(serverArray)
          this.serversValue = serverArray
          this.isEditing = false
          this.editorTarget.classList.add("hidden")
          this.displayTarget.classList.remove("hidden")
          this.hideDropdown()
          this.statusTarget.textContent = ""
        }
      } else {
        // Try to surface a helpful error message regardless of response format
        let errorMessage = "Save failed"
        try {
          const data = await response.json()
          errorMessage = data.error || errorMessage
        } catch (_e) {
          // Non-JSON error body — fall through with default message
        }
        this.statusTarget.textContent = errorMessage
        this.statusTarget.classList.remove("text-gray-500", "text-green-500")
        this.statusTarget.classList.add("text-red-500")
      }
    } catch (error) {
      console.error('Failed to update MCP servers:', error)
      this.statusTarget.textContent = `Error: ${error.message || 'Network error'}`
      this.statusTarget.classList.remove("text-gray-500", "text-green-500")
      this.statusTarget.classList.add("text-red-500")
    } finally {
      // Re-enable save button (in case we kept the editor open)
      if (this.hasSaveButtonTarget) {
        this.saveButtonTarget.disabled = false
      }
    }
  }

  showDropdown() {
    this.filterServers()
  }

  filterServers() {
    const inputValue = this.inputTarget.value.toLowerCase().trim()
    // Split input into search terms for AND matching
    const searchTerms = inputValue ? inputValue.split(/\s+/).filter(t => t.length > 0) : []

    // Filter servers based on input (excluding already selected ones)
    this.filteredServers = this.serversList.filter(server => {
      if (this.selectedServers.has(server.name)) {
        return false
      }
      if (searchTerms.length === 0) {
        return true
      }
      // AND matching: every search term must match somewhere in title, description, or name
      const searchableText = `${server.title} ${server.description || ''} ${server.name}`.toLowerCase()
      return searchTerms.every(term => searchableText.includes(term))
    })

    if (this.filteredServers.length === 0) {
      this.hideDropdown()
      return
    }

    // Position dropdown below the input with fixed positioning and a minimum width of 400px
    // Fixed positioning breaks out of parent container width constraints
    // This ensures the dropdown is wide enough to show full MCP server names
    this.dropdownTarget.style.position = 'fixed'
    this.repositionDropdown()

    // Populate dropdown - compact single-line format, limit to 10 results
    const displayServers = this.filteredServers.slice(0, 10)
    this.dropdownTarget.innerHTML = displayServers.map((server, index) => `
      <div class="server-item px-3 py-2 cursor-pointer hover:bg-indigo-50 border-b border-gray-100 last:border-b-0 ${index === 0 ? 'bg-gray-50' : ''}"
           data-name="${this.escapeHtml(server.name)}"
           data-action="click->editable-mcp-servers#selectServerFromClick">
        <div class="flex items-center justify-between gap-3">
          <span class="text-sm font-medium text-gray-900 truncate">${this.escapeHtml(server.title)}</span>
          <span class="text-xs text-gray-500 font-mono flex-shrink-0">${this.escapeHtml(server.name)}</span>
        </div>
      </div>
    `).join('') + (this.filteredServers.length > 10 ? `
      <div class="px-3 py-2 text-xs text-gray-400 text-center border-t border-gray-200">
        +${this.filteredServers.length - 10} more results (keep typing to narrow)
      </div>
    ` : '')

    this.dropdownTarget.classList.remove("hidden")
    this.selectedIndex = 0
  }

  hideDropdown() {
    this.dropdownTarget.classList.add("hidden")
    this.selectedIndex = -1
  }

  handleKeydown(event) {
    if (!this.dropdownTarget.classList.contains("hidden")) {
      if (event.key === "Escape") {
        event.preventDefault()
        this.hideDropdown()
      } else if (event.key === "ArrowDown") {
        event.preventDefault()
        this.selectNextItem()
      } else if (event.key === "ArrowUp") {
        event.preventDefault()
        this.selectPreviousItem()
      } else if (event.key === "Enter") {
        event.preventDefault()
        // Use displayServers (limited to 10) for keyboard selection, not filteredServers
        const displayServers = this.filteredServers.slice(0, 10)
        if (this.selectedIndex >= 0 && displayServers[this.selectedIndex]) {
          this.addServer(displayServers[this.selectedIndex].name)
        }
      }
    } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault()
      this.showDropdown()
    }

    // Handle backspace to remove last selected server when input is empty
    if (event.key === "Backspace" && this.inputTarget.value === "" && this.selectedServers.size > 0) {
      const lastName = Array.from(this.selectedServers).pop()
      this.removeServer(lastName)
    }

    // Handle Escape to cancel editing
    if (event.key === "Escape" && this.dropdownTarget.classList.contains("hidden")) {
      this.cancel()
    }
  }

  selectServerFromClick(event) {
    const name = event.currentTarget.dataset.name
    this.addServer(name)
    event.stopPropagation()
  }

  addServer(name) {
    this.selectedServers.add(name)
    this.updateSelectedDisplay()

    // Clear input and refresh dropdown
    this.inputTarget.value = ""
    this.inputTarget.focus()
    this.filterServers()
  }

  removeServer(name) {
    this.selectedServers.delete(name)
    this.updateSelectedDisplay()
    this.inputTarget.focus()

    // Refresh dropdown if visible
    if (!this.dropdownTarget.classList.contains("hidden")) {
      this.filterServers()
    }
  }

  removeServerFromTag(event) {
    event.preventDefault()
    event.stopPropagation()
    const name = event.currentTarget.dataset.name
    this.removeServer(name)
  }

  updateSelectedDisplay() {
    this.selectedContainerTarget.innerHTML = ""

    // Editable server chips (with remove button)
    this.selectedServers.forEach(name => {
      const server = this.serversList.find(s => s.name === name)
      const displayTitle = server ? server.title : name

      const tag = document.createElement("span")
      tag.className = "inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-medium bg-indigo-100 text-indigo-800"
      tag.innerHTML = `
        ${this.escapeHtml(displayTitle)}
        <button type="button"
                class="text-indigo-600 hover:text-indigo-800 focus:outline-none"
                data-action="click->editable-mcp-servers#removeServerFromTag"
                data-name="${this.escapeHtml(name)}">
          <svg class="h-3 w-3" fill="currentColor" viewBox="0 0 20 20">
            <path fill-rule="evenodd" d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z" clip-rule="evenodd" />
          </svg>
        </button>
      `
      this.selectedContainerTarget.appendChild(tag)
    })

    // Injected server chips (read-only, no remove button)
    this.injectedServersValue.forEach(name => {
      if (this.selectedServers.has(name)) return
      const tag = document.createElement("span")
      tag.className = "inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-medium bg-gray-100 text-gray-500 italic border border-dashed border-gray-300"
      tag.title = `${name} (auto-injected, read-only)`
      tag.textContent = name
      this.selectedContainerTarget.appendChild(tag)
    })
  }

  selectNextItem() {
    const items = this.dropdownTarget.querySelectorAll('.server-item')
    if (items.length === 0) return

    if (this.selectedIndex < items.length - 1) {
      if (this.selectedIndex >= 0) {
        items[this.selectedIndex].classList.remove('bg-gray-50')
      }
      this.selectedIndex++
      items[this.selectedIndex].classList.add('bg-gray-50')
      this.scrollItemIntoView(items[this.selectedIndex])
    }
  }

  selectPreviousItem() {
    const items = this.dropdownTarget.querySelectorAll('.server-item')
    if (items.length === 0) return

    if (this.selectedIndex > 0) {
      items[this.selectedIndex].classList.remove('bg-gray-50')
      this.selectedIndex--
      items[this.selectedIndex].classList.add('bg-gray-50')
      this.scrollItemIntoView(items[this.selectedIndex])
    }
  }

  scrollItemIntoView(item) {
    item.scrollIntoView({ block: 'nearest', behavior: 'smooth' })
  }

  handleClickOutside(event) {
    if (!this.isEditing) return

    // Check if click is outside the editor area
    const isOutsideEditor = !this.editorTarget.contains(event.target)
    const isOutsideDropdown = !this.dropdownTarget.contains(event.target)

    if (isOutsideEditor && isOutsideDropdown) {
      this.hideDropdown()
    }
  }

  escapeHtml(text) {
    const div = document.createElement('div')
    div.textContent = text
    return div.innerHTML
  }
}
