import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="mcp-server-select"
// Multi-select dropdown with autocomplete for MCP server selection
export default class extends Controller {
  static targets = ["input", "dropdown", "selectedContainer", "hiddenInputs"]
  static values = {
    servers: Array, // Array of {name, title, description} objects
    agentRootDefaults: Object, // Mapping of agent root names to default MCP server arrays
    defaultServers: Array, // Default servers for the initially selected agent root
    inputName: { type: String, default: "session[mcp_servers][]" } // Name attribute for hidden inputs
  }

  connect() {
    this.serversList = this.serversValue || []
    this.selectedServers = new Set()
    this.selectedIndex = -1
    this.filteredServers = []
    this.hideDropdown()

    // Pre-select default servers for the initial agent root
    const defaultServers = this.defaultServersValue || []
    defaultServers.forEach(name => {
      if (this.serversList.some(s => s.name === name)) {
        this.selectedServers.add(name)
      }
    })
    this.updateSelectedDisplay()
    this.updateHiddenInputs()

    // Close dropdown when clicking outside
    this.boundHandleClickOutside = this.handleClickOutside.bind(this)
    document.addEventListener('click', this.boundHandleClickOutside)
  }

  disconnect() {
    document.removeEventListener('click', this.boundHandleClickOutside)
  }

  handleFocus() {
    this.showDropdown()
  }

  handleInput() {
    this.showDropdown()
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
          this.toggleServer(displayServers[this.selectedIndex].name)
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
  }

  showDropdown() {
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

    // Position dropdown below the input
    const inputRect = this.inputTarget.getBoundingClientRect()
    const scrollTop = window.pageYOffset || document.documentElement.scrollTop
    const scrollLeft = window.pageXOffset || document.documentElement.scrollLeft

    this.dropdownTarget.style.position = 'absolute'
    this.dropdownTarget.style.top = `${inputRect.bottom + scrollTop}px`
    this.dropdownTarget.style.left = `${inputRect.left + scrollLeft}px`
    // Make dropdown wider - at least 400px or input width, whichever is larger
    // Cap at viewport width minus padding to prevent overflow on small screens
    const maxWidth = window.innerWidth - 32
    this.dropdownTarget.style.width = `${Math.min(Math.max(inputRect.width, 400), maxWidth)}px`

    // Populate dropdown - compact single-line format, limit to 10 results
    const displayServers = this.filteredServers.slice(0, 10)
    this.dropdownTarget.innerHTML = displayServers.map((server, index) => `
      <div class="server-item px-3 py-2 cursor-pointer hover:bg-indigo-50 border-b border-gray-100 last:border-b-0 ${index === 0 ? 'bg-gray-50' : ''}"
           data-name="${this.escapeHtml(server.name)}"
           data-action="click->mcp-server-select#selectItemFromClick">
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

  selectItemFromClick(event) {
    const name = event.currentTarget.dataset.name
    this.toggleServer(name)
    event.stopPropagation()
  }

  toggleServer(name) {
    if (this.selectedServers.has(name)) {
      this.removeServer(name)
    } else {
      this.addServer(name)
    }
  }

  addServer(name) {
    this.selectedServers.add(name)
    this.updateSelectedDisplay()
    this.updateHiddenInputs()

    // Clear input and refresh dropdown
    this.inputTarget.value = ""
    this.inputTarget.focus()
    this.showDropdown()
  }

  removeServer(name) {
    this.selectedServers.delete(name)
    this.updateSelectedDisplay()
    this.updateHiddenInputs()

    // Focus input after removal
    this.inputTarget.focus()

    // Refresh dropdown if visible
    if (!this.dropdownTarget.classList.contains("hidden")) {
      this.showDropdown()
    }
  }

  updateSelectedDisplay() {
    // Clear the container
    this.selectedContainerTarget.innerHTML = ""

    // Add a tag for each selected server
    this.selectedServers.forEach(name => {
      const server = this.serversList.find(s => s.name === name)
      if (server) {
        const tag = document.createElement("span")
        tag.className = "inline-flex items-center gap-1 px-2.5 py-1 rounded-md text-sm font-medium bg-indigo-100 text-indigo-800 mr-2 mb-2"
        tag.innerHTML = `
          ${this.escapeHtml(server.title)}
          <button type="button"
                  class="text-indigo-600 hover:text-indigo-800 focus:outline-none"
                  data-action="click->mcp-server-select#removeServerFromTag"
                  data-name="${this.escapeHtml(name)}">
            <svg class="h-4 w-4" fill="currentColor" viewBox="0 0 20 20">
              <path fill-rule="evenodd" d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z" clip-rule="evenodd" />
            </svg>
          </button>
        `
        this.selectedContainerTarget.appendChild(tag)
      }
    })
  }

  updateHiddenInputs() {
    // Clear existing hidden inputs
    this.hiddenInputsTarget.innerHTML = ""

    if (this.selectedServers.size === 0) {
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = this.inputNameValue
      input.value = ""
      this.hiddenInputsTarget.appendChild(input)
      return
    }

    // Add a hidden input for each selected server
    this.selectedServers.forEach(name => {
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = this.inputNameValue
      input.value = name
      this.hiddenInputsTarget.appendChild(input)
    })
  }

  removeServerFromTag(event) {
    event.preventDefault()
    event.stopPropagation()
    const name = event.currentTarget.dataset.name
    this.removeServer(name)
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
    // Check if click is outside the MCP server selector area (input, dropdown, and selected container)
    const isOutsideInput = !this.inputTarget.contains(event.target)
    const isOutsideDropdown = !this.dropdownTarget.contains(event.target)
    const isOutsideSelectedContainer = !this.selectedContainerTarget.contains(event.target)

    if (isOutsideInput && isOutsideDropdown && isOutsideSelectedContainer) {
      this.hideDropdown()
    }
  }

  escapeHtml(text) {
    const div = document.createElement('div')
    div.textContent = text
    return div.innerHTML
  }

  handleAgentRootChange(event) {
    // Get the selected agent root name from the radio button's data attribute,
    // or from the select element's value (for triggers form)
    const selectedAgentRootName = event.target.dataset.agentRootName || event.target.value

    // Look up the default MCP servers for this agent root
    const agentRootDefaults = this.agentRootDefaultsValue || {}
    const defaultServers = agentRootDefaults[selectedAgentRootName] || []

    // Clear current selection and set new defaults
    this.selectedServers.clear()
    defaultServers.forEach(name => {
      if (this.serversList.some(s => s.name === name)) {
        this.selectedServers.add(name)
      }
    })

    // Update UI
    this.updateSelectedDisplay()
    this.updateHiddenInputs()

    // Hide dropdown when agent root changes
    this.hideDropdown()
  }
}
