import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="editable-catalog-plugins"
// Inline editor for catalog plugins on the session detail page.
// Mirrors the editable-catalog-skills controller pattern with purple color scheme.
export default class extends Controller {
  static targets = ["display", "editor", "input", "dropdown", "selectedContainer", "status", "saveButton"]
  static values = {
    sessionId: Number,
    plugins: Array, // Currently selected plugin IDs
    availablePlugins: Array // Array of {id, title, description} objects
  }

  connect() {
    this.pluginsList = this.availablePluginsValue || []
    this.selectedPlugins = new Set(this.pluginsValue || [])
    this.originalPlugins = new Set(this.pluginsValue || [])
    this.filteredPlugins = []
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
    if (!this.dropdownTarget.classList.contains("hidden")) {
      this.repositionDropdown()
    }
  }

  repositionDropdown() {
    const inputRect = this.inputTarget.getBoundingClientRect()
    this.dropdownTarget.style.top = `${inputRect.bottom}px`
    this.dropdownTarget.style.left = `${inputRect.left}px`
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
    this.selectedPlugins = new Set(this.originalPlugins)
    this.editorTarget.classList.add("hidden")
    this.displayTarget.classList.remove("hidden")
    this.hideDropdown()
    this.statusTarget.textContent = ""
  }

  async save() {
    const pluginsArray = Array.from(this.selectedPlugins)

    if (this.hasSaveButtonTarget) {
      this.saveButtonTarget.disabled = true
    }

    this.statusTarget.textContent = "Saving..."
    this.statusTarget.classList.remove("text-red-500", "text-purple-500")
    this.statusTarget.classList.add("text-gray-500")

    try {
      const response = await fetch(`/sessions/${this.sessionIdValue}/update_catalog_plugins`, {
        method: 'PATCH',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content,
          'Accept': 'application/json'
        },
        body: JSON.stringify({ catalog_plugins: pluginsArray })
      })

      const data = await response.json()

      if (response.ok) {
        this.originalPlugins = new Set(pluginsArray)
        this.pluginsValue = pluginsArray

        this.updateDisplayText(pluginsArray)

        this.isEditing = false
        this.editorTarget.classList.add("hidden")
        this.displayTarget.classList.remove("hidden")
        this.hideDropdown()
        this.statusTarget.textContent = ""
      } else {
        this.statusTarget.textContent = data.error || "Save failed"
        this.statusTarget.classList.remove("text-gray-500", "text-purple-500")
        this.statusTarget.classList.add("text-red-500")
      }
    } catch (error) {
      console.error('Failed to update catalog plugins:', error)
      this.statusTarget.textContent = `Error: ${error.message || 'Network error'}`
      this.statusTarget.classList.remove("text-gray-500", "text-purple-500")
      this.statusTarget.classList.add("text-red-500")
    } finally {
      if (this.hasSaveButtonTarget) {
        this.saveButtonTarget.disabled = false
      }
    }
  }

  updateDisplayText(plugins) {
    const tagsContainer = this.displayTarget.querySelector('[data-role="plugin-tags"]')
    const emptySpan = this.displayTarget.querySelector('[data-role="plugin-empty"]')

    if (plugins.length > 0) {
      if (tagsContainer) {
        tagsContainer.innerHTML = plugins.map(id => {
          return `<span class="inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium bg-purple-100 text-purple-800">${this.escapeHtml(id)}</span>`
        }).join('')
        tagsContainer.classList.remove("hidden")
      }
      if (emptySpan) emptySpan.classList.add("hidden")
    } else {
      if (tagsContainer) tagsContainer.classList.add("hidden")
      if (emptySpan) emptySpan.classList.remove("hidden")
    }
  }

  showDropdown() {
    this.filterPlugins()
  }

  filterPlugins() {
    const inputValue = this.inputTarget.value.toLowerCase().trim()
    const searchTerms = inputValue ? inputValue.split(/\s+/).filter(t => t.length > 0) : []

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

    this.dropdownTarget.style.position = 'fixed'
    this.repositionDropdown()

    const maxShown = 10
    let html = ''

    this.filteredPlugins.slice(0, maxShown).forEach((plugin, index) => {
      html += `
        <div class="plugin-item px-3 py-2 cursor-pointer hover:bg-purple-50 border-b border-gray-100 last:border-b-0 ${index === 0 ? 'bg-gray-50' : ''}"
             data-id="${this.escapeHtml(plugin.id)}"
             data-action="click->editable-catalog-plugins#selectPluginFromClick">
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
        const items = this.dropdownTarget.querySelectorAll('.plugin-item')
        if (this.selectedIndex >= 0 && items[this.selectedIndex]) {
          this.addPlugin(items[this.selectedIndex].dataset.id)
        }
      }
    } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault()
      this.showDropdown()
    }

    if (event.key === "Backspace" && this.inputTarget.value === "" && this.selectedPlugins.size > 0) {
      const lastId = Array.from(this.selectedPlugins).pop()
      this.removePlugin(lastId)
    }

    if (event.key === "Escape" && this.dropdownTarget.classList.contains("hidden")) {
      this.cancel()
    }
  }

  selectPluginFromClick(event) {
    const id = event.currentTarget.dataset.id
    this.addPlugin(id)
    event.stopPropagation()
  }

  addPlugin(id) {
    this.selectedPlugins.add(id)
    this.updateSelectedDisplay()

    this.inputTarget.value = ""
    this.inputTarget.focus()
    this.filterPlugins()
  }

  removePlugin(id) {
    this.selectedPlugins.delete(id)
    this.updateSelectedDisplay()
    this.inputTarget.focus()

    if (!this.dropdownTarget.classList.contains("hidden")) {
      this.filterPlugins()
    }
  }

  removePluginFromTag(event) {
    event.preventDefault()
    event.stopPropagation()
    const id = event.currentTarget.dataset.id
    this.removePlugin(id)
  }

  updateSelectedDisplay() {
    this.selectedContainerTarget.innerHTML = ""

    this.selectedPlugins.forEach(id => {
      const plugin = this.pluginsList.find(p => p.id === id)
      const displayTitle = plugin ? plugin.title : id

      const tag = document.createElement("span")
      tag.className = "inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-medium bg-purple-100 text-purple-800"
      tag.innerHTML = `
        ${this.escapeHtml(displayTitle)}
        <button type="button"
                class="text-purple-600 hover:text-purple-800 focus:outline-none"
                data-action="click->editable-catalog-plugins#removePluginFromTag"
                data-id="${this.escapeHtml(id)}">
          <svg class="h-3 w-3" fill="currentColor" viewBox="0 0 20 20">
            <path fill-rule="evenodd" d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z" clip-rule="evenodd" />
          </svg>
        </button>
      `
      this.selectedContainerTarget.appendChild(tag)
    })
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
    if (!this.isEditing) return

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
