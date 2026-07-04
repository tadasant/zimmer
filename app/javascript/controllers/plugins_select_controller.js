import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="plugins-select"
// Multi-select dropdown with autocomplete for catalog plugin selection.
// Mirrors the skills-select controller pattern with purple color scheme.
export default class extends Controller {
  static targets = ["input", "dropdown", "selectedContainer", "hiddenInputs"]
  static values = {
    plugins: Array, // Array of {id, title, description} objects
    agentRootDefaults: Object, // Mapping of agent root names to default plugin arrays
    defaultPlugins: Array, // Default plugins for the initially selected agent root
    inputName: { type: String, default: "session[catalog_plugins][]" }
  }

  connect() {
    this.pluginsList = this.pluginsValue || []
    this.selectedPlugins = new Set()
    this.selectedIndex = -1
    this.filteredPlugins = []
    this.hideDropdown()

    // Pre-select default plugins for the initial agent root
    const defaultPlugins = this.defaultPluginsValue || []
    defaultPlugins.forEach(id => {
      if (this.pluginsList.some(p => p.id === id)) {
        this.selectedPlugins.add(id)
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
        const displayPlugins = this.filteredPlugins.slice(0, 10)
        if (this.selectedIndex >= 0 && displayPlugins[this.selectedIndex]) {
          this.togglePlugin(displayPlugins[this.selectedIndex].id)
        }
      }
    } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault()
      this.showDropdown()
    }

    // Handle backspace to remove last selected plugin when input is empty
    if (event.key === "Backspace" && this.inputTarget.value === "" && this.selectedPlugins.size > 0) {
      const lastId = Array.from(this.selectedPlugins).pop()
      this.removePlugin(lastId)
    }
  }

  showDropdown() {
    const inputValue = this.inputTarget.value.toLowerCase().trim()
    const searchTerms = inputValue ? inputValue.split(/\s+/).filter(t => t.length > 0) : []

    // Filter plugins based on input (excluding already selected ones)
    this.filteredPlugins = this.pluginsList.filter(plugin => {
      if (this.selectedPlugins.has(plugin.id)) {
        return false
      }
      if (searchTerms.length === 0) {
        return true
      }
      const searchableText = `${plugin.title} ${plugin.description || ''} ${plugin.id}`.toLowerCase()
      return searchTerms.every(term => searchableText.includes(term))
    })

    if (this.filteredPlugins.length === 0) {
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
    const maxWidth = window.innerWidth - 32
    this.dropdownTarget.style.width = `${Math.min(Math.max(inputRect.width, 400), maxWidth)}px`

    // Build HTML (no category grouping for plugins)
    const maxShown = 10
    let html = ''

    this.filteredPlugins.slice(0, maxShown).forEach((plugin, index) => {
      html += `
        <div class="plugin-item px-3 py-2 cursor-pointer hover:bg-purple-50 border-b border-gray-100 last:border-b-0 ${index === 0 ? 'bg-gray-50' : ''}"
             data-id="${this.escapeHtml(plugin.id)}"
             data-action="click->plugins-select#selectItemFromClick">
          <div class="flex items-center justify-between gap-3">
            <span class="text-sm font-medium text-gray-900 truncate">${this.escapeHtml(plugin.title)}</span>
            <span class="text-xs text-gray-500 font-mono flex-shrink-0">${this.escapeHtml(plugin.id)}</span>
          </div>
          ${plugin.description ? `<div class="text-xs text-gray-500 mt-0.5 truncate">${this.escapeHtml(plugin.description)}</div>` : ''}
        </div>`
    })

    if (this.filteredPlugins.length > maxShown) {
      html += `
        <div class="px-3 py-2 text-xs text-gray-400 text-center border-t border-gray-200">
          +${this.filteredPlugins.length - maxShown} more results (keep typing to narrow)
        </div>`
    }

    this.dropdownTarget.innerHTML = html
    this.dropdownTarget.classList.remove("hidden")
    this.selectedIndex = 0
  }

  hideDropdown() {
    this.dropdownTarget.classList.add("hidden")
    this.selectedIndex = -1
  }

  selectItemFromClick(event) {
    const id = event.currentTarget.dataset.id
    this.togglePlugin(id)
    event.stopPropagation()
  }

  togglePlugin(id) {
    if (this.selectedPlugins.has(id)) {
      this.removePlugin(id)
    } else {
      this.addPlugin(id)
    }
  }

  addPlugin(id) {
    this.selectedPlugins.add(id)
    this.updateSelectedDisplay()
    this.updateHiddenInputs()

    this.inputTarget.value = ""
    this.inputTarget.focus()
    this.showDropdown()
  }

  removePlugin(id) {
    this.selectedPlugins.delete(id)
    this.updateSelectedDisplay()
    this.updateHiddenInputs()

    this.inputTarget.focus()

    if (!this.dropdownTarget.classList.contains("hidden")) {
      this.showDropdown()
    }
  }

  updateSelectedDisplay() {
    this.selectedContainerTarget.innerHTML = ""

    this.selectedPlugins.forEach(id => {
      const plugin = this.pluginsList.find(p => p.id === id)
      if (plugin) {
        const tag = document.createElement("span")
        tag.className = "inline-flex items-center gap-1 px-2.5 py-1 rounded-md text-sm font-medium bg-purple-100 text-purple-800 mr-2 mb-2"
        tag.innerHTML = `
          ${this.escapeHtml(plugin.title)}
          <button type="button"
                  class="text-purple-600 hover:text-purple-800 focus:outline-none"
                  data-action="click->plugins-select#removePluginFromTag"
                  data-id="${this.escapeHtml(id)}">
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
    this.hiddenInputsTarget.innerHTML = ""

    this.selectedPlugins.forEach(id => {
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = this.inputNameValue
      input.value = id
      this.hiddenInputsTarget.appendChild(input)
    })
  }

  removePluginFromTag(event) {
    event.preventDefault()
    event.stopPropagation()
    const id = event.currentTarget.dataset.id
    this.removePlugin(id)
  }

  selectNextItem() {
    const items = this.dropdownTarget.querySelectorAll('.plugin-item')
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
    const items = this.dropdownTarget.querySelectorAll('.plugin-item')
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
    // Support both radio buttons (data-agent-root-name) and select elements (value)
    const selectedAgentRootName = event.target.dataset.agentRootName || event.target.value
    const agentRootDefaults = this.agentRootDefaultsValue || {}
    const defaultPlugins = agentRootDefaults[selectedAgentRootName] || []

    this.selectedPlugins.clear()
    defaultPlugins.forEach(id => {
      if (this.pluginsList.some(p => p.id === id)) {
        this.selectedPlugins.add(id)
      }
    })

    this.updateSelectedDisplay()
    this.updateHiddenInputs()
    this.hideDropdown()
  }
}
