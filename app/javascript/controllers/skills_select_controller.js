import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="skills-select"
// Multi-select dropdown with autocomplete for catalog skill selection.
// Mirrors the mcp-server-select controller pattern.
export default class extends Controller {
  static targets = ["input", "dropdown", "selectedContainer", "hiddenInputs"]
  static values = {
    skills: Array, // Array of {id, name, title, description} objects
    agentRootDefaults: Object, // Mapping of agent root names to default skill arrays
    defaultSkills: Array, // Default skills for the initially selected agent root
    inputName: { type: String, default: "session[catalog_skills][]" }
  }

  connect() {
    this.skillsList = this.skillsValue || []
    this.selectedSkills = new Set()
    this.selectedIndex = -1
    this.filteredSkills = []
    this.hideDropdown()

    // Pre-select default skills for the initial agent root
    const defaultSkills = this.defaultSkillsValue || []
    defaultSkills.forEach(name => {
      if (this.skillsList.some(s => s.name === name)) {
        this.selectedSkills.add(name)
      }
    })
    this.updateSelectedDisplay()
    this.updateHiddenInputs()
    this.dispatchSkillsChanged()

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
        const displaySkills = this.filteredSkills.slice(0, 10)
        if (this.selectedIndex >= 0 && displaySkills[this.selectedIndex]) {
          this.toggleSkill(displaySkills[this.selectedIndex].name)
        }
      }
    } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault()
      this.showDropdown()
    }

    // Handle backspace to remove last selected skill when input is empty
    if (event.key === "Backspace" && this.inputTarget.value === "" && this.selectedSkills.size > 0) {
      const lastName = Array.from(this.selectedSkills).pop()
      this.removeSkill(lastName)
    }
  }

  showDropdown() {
    const inputValue = this.inputTarget.value.toLowerCase().trim()
    const searchTerms = inputValue ? inputValue.split(/\s+/).filter(t => t.length > 0) : []

    // Filter skills based on input (excluding already selected ones)
    // Category is included in searchable text so users can type a category name
    this.filteredSkills = this.skillsList.filter(skill => {
      if (this.selectedSkills.has(skill.name)) {
        return false
      }
      if (searchTerms.length === 0) {
        return true
      }
      const searchableText = `${skill.title} ${skill.description || ''} ${skill.name} ${skill.category || ''}`.toLowerCase()
      return searchTerms.every(term => searchableText.includes(term))
    })

    if (this.filteredSkills.length === 0) {
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

    // Group filtered skills by category for display
    const grouped = {}
    this.filteredSkills.forEach(skill => {
      const cat = skill.category || 'uncategorized'
      if (!grouped[cat]) grouped[cat] = []
      grouped[cat].push(skill)
    })

    // Build grouped HTML with category headers, limiting to 10 skill items total
    const maxShown = 10
    let totalShown = 0
    let html = ''
    const sortedCategories = Object.keys(grouped).sort()

    for (const category of sortedCategories) {
      if (totalShown >= maxShown) break

      // Category header (not a .skill-item, so keyboard nav skips it)
      html += `<div class="skill-category-header px-3 py-1.5 text-xs font-semibold text-green-700 uppercase tracking-wider bg-green-50 border-b border-green-100">${this.escapeHtml(category)}</div>`

      for (const skill of grouped[category]) {
        if (totalShown >= maxShown) break
        html += `
          <div class="skill-item px-3 py-2 cursor-pointer hover:bg-green-50 border-b border-gray-100 last:border-b-0 ${totalShown === 0 ? 'bg-gray-50' : ''}"
               data-name="${this.escapeHtml(skill.name)}"
               data-action="click->skills-select#selectItemFromClick">
            <div class="flex items-center justify-between gap-3">
              <span class="text-sm font-medium text-gray-900 truncate">${this.escapeHtml(skill.title)}</span>
              <span class="text-xs text-gray-500 font-mono flex-shrink-0">${this.escapeHtml(skill.name)}</span>
            </div>
          </div>`
        totalShown++
      }
    }

    if (this.filteredSkills.length > maxShown) {
      html += `
        <div class="px-3 py-2 text-xs text-gray-400 text-center border-t border-gray-200">
          +${this.filteredSkills.length - maxShown} more results (keep typing to narrow)
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
    this.toggleSkill(name)
    event.stopPropagation()
  }

  toggleSkill(name) {
    if (this.selectedSkills.has(name)) {
      this.removeSkill(name)
    } else {
      this.addSkill(name)
    }
  }

  addSkill(name) {
    this.selectedSkills.add(name)
    this.updateSelectedDisplay()
    this.updateHiddenInputs()
    this.dispatchSkillsChanged()

    this.inputTarget.value = ""
    this.inputTarget.focus()
    this.showDropdown()
  }

  removeSkill(name) {
    this.selectedSkills.delete(name)
    this.updateSelectedDisplay()
    this.updateHiddenInputs()
    this.dispatchSkillsChanged()

    this.inputTarget.focus()

    if (!this.dropdownTarget.classList.contains("hidden")) {
      this.showDropdown()
    }
  }

  updateSelectedDisplay() {
    this.selectedContainerTarget.innerHTML = ""

    this.selectedSkills.forEach(name => {
      const skill = this.skillsList.find(s => s.name === name)
      if (skill) {
        const tag = document.createElement("span")
        tag.className = "inline-flex items-center gap-1 px-2.5 py-1 rounded-md text-sm font-medium bg-green-100 text-green-800 mr-2 mb-2"
        tag.innerHTML = `
          ${this.escapeHtml(skill.title)}
          <button type="button"
                  class="text-green-600 hover:text-green-800 focus:outline-none"
                  data-action="click->skills-select#removeSkillFromTag"
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

    this.selectedSkills.forEach(name => {
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = this.inputNameValue
      input.value = name
      this.hiddenInputsTarget.appendChild(input)
    })
  }

  removeSkillFromTag(event) {
    event.preventDefault()
    event.stopPropagation()
    const name = event.currentTarget.dataset.name
    this.removeSkill(name)
  }

  selectNextItem() {
    const items = this.dropdownTarget.querySelectorAll('.skill-item')
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
    const items = this.dropdownTarget.querySelectorAll('.skill-item')
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
    const defaultSkills = agentRootDefaults[selectedAgentRootName] || []

    this.selectedSkills.clear()
    defaultSkills.forEach(name => {
      if (this.skillsList.some(s => s.name === name)) {
        this.selectedSkills.add(name)
      }
    })

    this.updateSelectedDisplay()
    this.updateHiddenInputs()
    this.dispatchSkillsChanged()
    this.hideDropdown()
  }

  // Dispatch a custom event with the current selected skill names so other
  // controllers (e.g. slash-command) can react to selection changes.
  dispatchSkillsChanged() {
    this.dispatch("skillsChanged", {
      detail: { selectedSkills: Array.from(this.selectedSkills) }
    })
  }
}
