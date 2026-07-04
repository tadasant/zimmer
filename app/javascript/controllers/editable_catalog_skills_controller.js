import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="editable-catalog-skills"
// Inline editor for catalog skills on the session detail page.
// Mirrors the editable-mcp-servers controller pattern.
export default class extends Controller {
  static targets = ["display", "editor", "input", "dropdown", "selectedContainer", "status", "saveButton"]
  static values = {
    sessionId: Number,
    skills: Array, // Currently selected skill names
    availableSkills: Array // Array of {id, name, title, description, category} objects
  }

  connect() {
    this.skillsList = this.availableSkillsValue || []
    this.selectedSkills = new Set(this.skillsValue || [])
    this.originalSkills = new Set(this.skillsValue || [])
    this.filteredSkills = []
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
    this.selectedSkills = new Set(this.originalSkills)
    this.editorTarget.classList.add("hidden")
    this.displayTarget.classList.remove("hidden")
    this.hideDropdown()
    this.statusTarget.textContent = ""
  }

  async save() {
    const skillsArray = Array.from(this.selectedSkills)

    if (this.hasSaveButtonTarget) {
      this.saveButtonTarget.disabled = true
    }

    this.statusTarget.textContent = "Saving..."
    this.statusTarget.classList.remove("text-red-500", "text-green-500")
    this.statusTarget.classList.add("text-gray-500")

    try {
      const response = await fetch(`/sessions/${this.sessionIdValue}/update_catalog_skills`, {
        method: 'PATCH',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content,
          'Accept': 'application/json'
        },
        body: JSON.stringify({ catalog_skills: skillsArray })
      })

      const data = await response.json()

      if (response.ok) {
        this.originalSkills = new Set(skillsArray)
        this.skillsValue = skillsArray

        this.updateDisplayText(skillsArray)

        this.isEditing = false
        this.editorTarget.classList.add("hidden")
        this.displayTarget.classList.remove("hidden")
        this.hideDropdown()
        this.statusTarget.textContent = ""
      } else {
        this.statusTarget.textContent = data.error || "Save failed"
        this.statusTarget.classList.remove("text-gray-500", "text-green-500")
        this.statusTarget.classList.add("text-red-500")
      }
    } catch (error) {
      console.error('Failed to update catalog skills:', error)
      this.statusTarget.textContent = `Error: ${error.message || 'Network error'}`
      this.statusTarget.classList.remove("text-gray-500", "text-green-500")
      this.statusTarget.classList.add("text-red-500")
    } finally {
      if (this.hasSaveButtonTarget) {
        this.saveButtonTarget.disabled = false
      }
    }
  }

  updateDisplayText(skills) {
    const tagsContainer = this.displayTarget.querySelector('[data-role="skill-tags"]')
    const emptySpan = this.displayTarget.querySelector('[data-role="skill-empty"]')

    if (skills.length > 0) {
      if (tagsContainer) {
        tagsContainer.innerHTML = skills.map(name => {
          return `<span class="inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium bg-green-100 text-green-800">${this.escapeHtml(name)}</span>`
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
    this.filterSkills()
  }

  filterSkills() {
    const inputValue = this.inputTarget.value.toLowerCase().trim()
    const searchTerms = inputValue ? inputValue.split(/\s+/).filter(t => t.length > 0) : []

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

    this.dropdownTarget.style.position = 'fixed'
    this.repositionDropdown()

    // Group filtered skills by category
    const grouped = {}
    this.filteredSkills.forEach(skill => {
      const cat = skill.category || 'uncategorized'
      if (!grouped[cat]) grouped[cat] = []
      grouped[cat].push(skill)
    })

    const maxShown = 10
    let totalShown = 0
    let html = ''
    const sortedCategories = Object.keys(grouped).sort()

    for (const category of sortedCategories) {
      if (totalShown >= maxShown) break

      html += `<div class="skill-category-header px-3 py-1.5 text-xs font-semibold text-green-700 uppercase tracking-wider bg-green-50 border-b border-green-100">${this.escapeHtml(category)}</div>`

      for (const skill of grouped[category]) {
        if (totalShown >= maxShown) break
        html += `
          <div class="skill-item px-3 py-2 cursor-pointer hover:bg-green-50 border-b border-gray-100 last:border-b-0 ${totalShown === 0 ? 'bg-gray-50' : ''}"
               data-name="${this.escapeHtml(skill.name)}"
               data-action="click->editable-catalog-skills#selectSkillFromClick">
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
        const items = this.dropdownTarget.querySelectorAll('.skill-item')
        if (this.selectedIndex >= 0 && items[this.selectedIndex]) {
          this.addSkill(items[this.selectedIndex].dataset.name)
        }
      }
    } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault()
      this.showDropdown()
    }

    if (event.key === "Backspace" && this.inputTarget.value === "" && this.selectedSkills.size > 0) {
      const lastName = Array.from(this.selectedSkills).pop()
      this.removeSkill(lastName)
    }

    if (event.key === "Escape" && this.dropdownTarget.classList.contains("hidden")) {
      this.cancel()
    }
  }

  selectSkillFromClick(event) {
    const name = event.currentTarget.dataset.name
    this.addSkill(name)
    event.stopPropagation()
  }

  addSkill(name) {
    this.selectedSkills.add(name)
    this.updateSelectedDisplay()

    this.inputTarget.value = ""
    this.inputTarget.focus()
    this.filterSkills()
  }

  removeSkill(name) {
    this.selectedSkills.delete(name)
    this.updateSelectedDisplay()
    this.inputTarget.focus()

    if (!this.dropdownTarget.classList.contains("hidden")) {
      this.filterSkills()
    }
  }

  removeSkillFromTag(event) {
    event.preventDefault()
    event.stopPropagation()
    const name = event.currentTarget.dataset.name
    this.removeSkill(name)
  }

  updateSelectedDisplay() {
    this.selectedContainerTarget.innerHTML = ""

    this.selectedSkills.forEach(name => {
      const skill = this.skillsList.find(s => s.name === name)
      const displayTitle = skill ? skill.title : name

      const tag = document.createElement("span")
      tag.className = "inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-medium bg-green-100 text-green-800"
      tag.innerHTML = `
        ${this.escapeHtml(displayTitle)}
        <button type="button"
                class="text-green-600 hover:text-green-800 focus:outline-none"
                data-action="click->editable-catalog-skills#removeSkillFromTag"
                data-name="${this.escapeHtml(name)}">
          <svg class="h-3 w-3" fill="currentColor" viewBox="0 0 20 20">
            <path fill-rule="evenodd" d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z" clip-rule="evenodd" />
          </svg>
        </button>
      `
      this.selectedContainerTarget.appendChild(tag)
    })
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
