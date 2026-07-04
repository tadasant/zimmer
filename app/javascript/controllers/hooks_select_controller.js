import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="hooks-select"
// Multi-select dropdown with autocomplete for catalog hook selection.
// Mirrors the skills-select controller pattern.
export default class extends Controller {
  static targets = ["input", "dropdown", "selectedContainer", "hiddenInputs"]
  static values = {
    hooks: Array, // Array of {id, name, title, description} objects
    agentRootDefaults: Object, // Mapping of agent root names to default hook arrays
    defaultHooks: Array, // Default hooks for the initially selected agent root
    inputName: { type: String, default: "session[catalog_hooks][]" }
  }

  connect() {
    this.hooksList = this.hooksValue || []
    this.selectedHooks = new Set()
    this.selectedIndex = -1
    this.filteredHooks = []
    this.hideDropdown()

    // Pre-select default hooks for the initial agent root
    const defaultHooks = this.defaultHooksValue || []
    defaultHooks.forEach(name => {
      if (this.hooksList.some(h => h.name === name)) {
        this.selectedHooks.add(name)
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
        const displayHooks = this.filteredHooks.slice(0, 10)
        if (this.selectedIndex >= 0 && displayHooks[this.selectedIndex]) {
          this.toggleHook(displayHooks[this.selectedIndex].name)
        }
      }
    } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault()
      this.showDropdown()
    }

    // Handle backspace to remove last selected hook when input is empty
    if (event.key === "Backspace" && this.inputTarget.value === "" && this.selectedHooks.size > 0) {
      const lastName = Array.from(this.selectedHooks).pop()
      this.removeHook(lastName)
    }
  }

  showDropdown() {
    const inputValue = this.inputTarget.value.toLowerCase().trim()
    const searchTerms = inputValue ? inputValue.split(/\s+/).filter(t => t.length > 0) : []

    // Filter hooks based on input (excluding already selected ones)
    this.filteredHooks = this.hooksList.filter(hook => {
      if (this.selectedHooks.has(hook.name)) {
        return false
      }
      if (searchTerms.length === 0) {
        return true
      }
      const searchableText = `${hook.title} ${hook.description || ''} ${hook.name}`.toLowerCase()
      return searchTerms.every(term => searchableText.includes(term))
    })

    if (this.filteredHooks.length === 0) {
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

    // Build HTML (hooks don't have categories, so flat list)
    const maxShown = 10
    let html = ''

    this.filteredHooks.slice(0, maxShown).forEach((hook, index) => {
      html += `
        <div class="hook-item px-3 py-2 cursor-pointer hover:bg-amber-50 border-b border-gray-100 last:border-b-0 ${index === 0 ? 'bg-gray-50' : ''}"
             data-name="${this.escapeHtml(hook.name)}"
             data-action="click->hooks-select#selectItemFromClick">
          <div class="flex items-center justify-between gap-3">
            <span class="text-sm font-medium text-gray-900 truncate">${this.escapeHtml(hook.title)}</span>
            <span class="text-xs text-gray-500 font-mono flex-shrink-0">${this.escapeHtml(hook.name)}</span>
          </div>
          ${hook.description ? `<div class="text-xs text-gray-500 mt-0.5 truncate">${this.escapeHtml(hook.description)}</div>` : ''}
        </div>`
    })

    if (this.filteredHooks.length > maxShown) {
      html += `
        <div class="px-3 py-2 text-xs text-gray-400 text-center border-t border-gray-200">
          +${this.filteredHooks.length - maxShown} more results (keep typing to narrow)
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
    const name = event.currentTarget.dataset.name
    this.toggleHook(name)
    event.stopPropagation()
  }

  toggleHook(name) {
    if (this.selectedHooks.has(name)) {
      this.removeHook(name)
    } else {
      this.addHook(name)
    }
  }

  addHook(name) {
    this.selectedHooks.add(name)
    this.updateSelectedDisplay()
    this.updateHiddenInputs()

    this.inputTarget.value = ""
    this.inputTarget.focus()
    this.showDropdown()
  }

  removeHook(name) {
    this.selectedHooks.delete(name)
    this.updateSelectedDisplay()
    this.updateHiddenInputs()

    this.inputTarget.focus()

    if (!this.dropdownTarget.classList.contains("hidden")) {
      this.showDropdown()
    }
  }

  updateSelectedDisplay() {
    this.selectedContainerTarget.innerHTML = ""

    this.selectedHooks.forEach(name => {
      const hook = this.hooksList.find(h => h.name === name)
      if (hook) {
        const tag = document.createElement("span")
        tag.className = "inline-flex items-center gap-1 px-2.5 py-1 rounded-md text-sm font-medium bg-amber-100 text-amber-800 mr-2 mb-2"
        tag.innerHTML = `
          ${this.escapeHtml(hook.title)}
          <button type="button"
                  class="text-amber-600 hover:text-amber-800 focus:outline-none"
                  data-action="click->hooks-select#removeHookFromTag"
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
    this.hiddenInputsTarget.innerHTML = ""

    this.selectedHooks.forEach(name => {
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = this.inputNameValue
      input.value = name
      this.hiddenInputsTarget.appendChild(input)
    })
  }

  removeHookFromTag(event) {
    event.preventDefault()
    event.stopPropagation()
    const name = event.currentTarget.dataset.name
    this.removeHook(name)
  }

  selectNextItem() {
    const items = this.dropdownTarget.querySelectorAll('.hook-item')
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
    const items = this.dropdownTarget.querySelectorAll('.hook-item')
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
    const selectedAgentRootName = event.target.dataset.agentRootName || event.target.value
    const agentRootDefaults = this.agentRootDefaultsValue || {}
    const defaultHooks = agentRootDefaults[selectedAgentRootName] || []

    this.selectedHooks.clear()
    defaultHooks.forEach(name => {
      if (this.hooksList.some(h => h.name === name)) {
        this.selectedHooks.add(name)
      }
    })

    this.updateSelectedDisplay()
    this.updateHiddenInputs()
    this.hideDropdown()
  }
}
