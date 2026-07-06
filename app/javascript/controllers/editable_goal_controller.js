import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="editable-goal"
// Inline editor for goal on the session detail page.
// Mirrors the editable-mcp-servers pattern but for a single text value
// with predefined suggestions dropdown.
export default class extends Controller {
  static targets = ["display", "editor", "input", "dropdown", "clearButton", "status", "saveButton", "displayText"]
  static values = {
    sessionId: Number,
    goal: String,
    goals: Array
  }

  connect() {
    this.goalsList = this.goalsValue || []
    this.currentValue = this.goalValue || ""
    this.originalValue = this.currentValue
    this.selectedIndex = -1
    this.filteredGoals = []
    this.isEditing = false

    this.boundHandleClickOutside = this.handleClickOutside.bind(this)
    this.boundHandleScroll = this.handleScroll.bind(this)
    document.addEventListener('click', this.boundHandleClickOutside)
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
    const viewportHeight = window.innerHeight
    const spaceBelow = viewportHeight - inputRect.bottom
    const spaceAbove = inputRect.top
    const dropdownMaxHeight = 384

    this.dropdownTarget.style.position = 'fixed'
    this.dropdownTarget.style.left = `${inputRect.left}px`
    const maxWidth = window.innerWidth - 32
    this.dropdownTarget.style.width = `${Math.min(Math.max(inputRect.width, 350), maxWidth)}px`

    if (spaceBelow < dropdownMaxHeight && spaceAbove > spaceBelow) {
      this.dropdownTarget.style.bottom = `${viewportHeight - inputRect.top}px`
      this.dropdownTarget.style.top = 'auto'
    } else {
      this.dropdownTarget.style.top = `${inputRect.bottom}px`
      this.dropdownTarget.style.bottom = 'auto'
    }
  }

  edit() {
    this.isEditing = true
    this.displayTarget.classList.add("hidden")
    this.editorTarget.classList.remove("hidden")
    this.inputTarget.value = this.currentValue
    this.updateClearButtonVisibility()
    this.inputTarget.focus()
  }

  cancel() {
    this.isEditing = false
    this.currentValue = this.originalValue
    this.editorTarget.classList.add("hidden")
    this.displayTarget.classList.remove("hidden")
    this.hideDropdown()
    this.statusTarget.textContent = ""
  }

  handleInput(event) {
    this.currentValue = event.target.value
    this.updateClearButtonVisibility()
    this.showDropdown()
  }

  handleFocus() {
    this.showDropdown()
  }

  handleKeydown(event) {
    if (!this.dropdownTarget.classList.contains("hidden")) {
      if (event.key === "Escape") {
        event.preventDefault()
        this.hideDropdown()
        return
      } else if (event.key === "ArrowDown") {
        event.preventDefault()
        this.selectNextItem()
        return
      } else if (event.key === "ArrowUp") {
        event.preventDefault()
        this.selectPreviousItem()
        return
      } else if (event.key === "Enter") {
        event.preventDefault()
        if (this.selectedIndex >= 0 && this.filteredGoals[this.selectedIndex]) {
          this.selectGoal(this.filteredGoals[this.selectedIndex])
        }
        this.hideDropdown()
        return
      }
    }

    if (event.key === "Escape" && this.dropdownTarget.classList.contains("hidden")) {
      this.cancel()
      return
    }

    if (event.key === "Enter" && this.dropdownTarget.classList.contains("hidden")) {
      event.preventDefault()
      this.save()
    }
  }

  clear(event) {
    event.preventDefault()
    this.inputTarget.value = ""
    this.currentValue = ""
    this.updateClearButtonVisibility()
    this.hideDropdown()
    this.inputTarget.focus()
  }

  showDropdown() {
    if (this.goalsList.length === 0) return

    const inputValue = this.inputTarget.value.toLowerCase()

    this.filteredGoals = this.goalsList.filter(goal => {
      return goal.name.toLowerCase().includes(inputValue) ||
             goal.description.toLowerCase().includes(inputValue)
    })

    if (this.filteredGoals.length === 0) {
      this.hideDropdown()
      return
    }

    this.repositionDropdown()

    this.dropdownTarget.innerHTML = this.filteredGoals.map((goal, index) => `
      <div class="goal-item px-3 py-2 cursor-pointer hover:bg-amber-50 border-b border-gray-100 last:border-b-0 ${index === 0 ? 'bg-gray-50' : ''}"
           data-index="${index}"
           data-action="click->editable-goal#selectGoalFromClick">
        <div class="text-sm font-medium text-gray-900">${this.escapeHtml(goal.name)}</div>
        <div class="text-xs text-gray-600 mt-0.5 line-clamp-2">${this.escapeHtml(goal.description)}</div>
      </div>
    `).join('')

    this.dropdownTarget.classList.remove("hidden")
    this.selectedIndex = 0
  }

  hideDropdown() {
    this.dropdownTarget.classList.add("hidden")
    this.selectedIndex = -1
  }

  selectGoalFromClick(event) {
    const index = parseInt(event.currentTarget.dataset.index)
    if (this.filteredGoals[index]) {
      this.selectGoal(this.filteredGoals[index])
    }
  }

  selectGoal(goal) {
    this.inputTarget.value = goal.description
    this.currentValue = goal.description
    this.updateClearButtonVisibility()
    this.hideDropdown()
  }

  selectNextItem() {
    const items = this.dropdownTarget.querySelectorAll('.goal-item')
    if (items.length === 0) return

    if (this.selectedIndex < items.length - 1) {
      if (this.selectedIndex >= 0) items[this.selectedIndex].classList.remove('bg-gray-50')
      this.selectedIndex++
      items[this.selectedIndex].classList.add('bg-gray-50')
      items[this.selectedIndex].scrollIntoView({ block: 'nearest', behavior: 'smooth' })
    }
  }

  selectPreviousItem() {
    const items = this.dropdownTarget.querySelectorAll('.goal-item')
    if (items.length === 0) return

    if (this.selectedIndex > 0) {
      items[this.selectedIndex].classList.remove('bg-gray-50')
      this.selectedIndex--
      items[this.selectedIndex].classList.add('bg-gray-50')
      items[this.selectedIndex].scrollIntoView({ block: 'nearest', behavior: 'smooth' })
    }
  }

  async save() {
    const value = this.inputTarget.value.trim()

    if (this.hasSaveButtonTarget) {
      this.saveButtonTarget.disabled = true
    }

    this.statusTarget.textContent = "Saving..."
    this.statusTarget.classList.remove("text-red-500", "text-green-500")
    this.statusTarget.classList.add("text-gray-500")

    try {
      const response = await fetch(`/sessions/${this.sessionIdValue}/update_goal`, {
        method: 'PATCH',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content,
          'Accept': 'application/json'
        },
        body: JSON.stringify({ goal: value })
      })

      const data = await response.json()

      if (response.ok) {
        const savedValue = data.goal || ""
        this.currentValue = savedValue
        this.originalValue = savedValue
        this.goalValue = savedValue

        this.updateDisplayText(savedValue)

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
      console.error('Failed to update goal:', error)
      this.statusTarget.textContent = `Error: ${error.message || 'Network error'}`
      this.statusTarget.classList.remove("text-gray-500", "text-green-500")
      this.statusTarget.classList.add("text-red-500")
    } finally {
      if (this.hasSaveButtonTarget) {
        this.saveButtonTarget.disabled = false
      }
    }
  }

  updateDisplayText(value) {
    if (this.hasDisplayTextTarget) {
      if (value) {
        const matchingGoal = this.goalsList.find(g => g.description === value || g.id === value)
        const displayLabel = matchingGoal ? matchingGoal.name : "Custom"

        this.displayTextTarget.textContent = displayLabel
        this.displayTextTarget.classList.remove("text-gray-400", "italic")
        this.displayTextTarget.classList.add("text-gray-600")
        this.displayTextTarget.title = value
      } else {
        this.displayTextTarget.textContent = "None"
        this.displayTextTarget.classList.add("text-gray-400", "italic")
        this.displayTextTarget.classList.remove("text-gray-600")
        this.displayTextTarget.title = ""
      }
    }
  }

  updateClearButtonVisibility() {
    if (!this.hasClearButtonTarget) return

    if (this.inputTarget.value.trim().length > 0) {
      this.clearButtonTarget.classList.remove('hidden')
    } else {
      this.clearButtonTarget.classList.add('hidden')
    }
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
