import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="goal"
export default class extends Controller {
  static targets = ["input", "dropdown", "hiddenField", "displayName", "clearButton"]
  static values = {
    goals: Array,
    defaultGoal: String,
    agentRootDefaults: Object
  }

  connect() {
    // goalsValue is an array of {id, name, description} objects
    this.goalsList = this.goalsValue || []
    this.selectedIndex = -1
    this.hideDropdown()

    // Set default value if provided
    if (this.defaultGoalValue) {
      const defaultGoal = this.goalsList.find(g => g.id === this.defaultGoalValue)
      if (defaultGoal) {
        this.inputTarget.value = defaultGoal.description
        this.hiddenFieldTarget.value = defaultGoal.description
      }
    }

    this.updateDisplayName()
    this.updateClearButtonVisibility()

    this.boundHandleClickOutside = this.handleClickOutside.bind(this)
    this.boundHandleScroll = this.handleScroll.bind(this)

    document.addEventListener('click', this.boundHandleClickOutside)
    window.addEventListener('scroll', this.boundHandleScroll, true)
  }

  disconnect() {
    document.removeEventListener('click', this.boundHandleClickOutside)
    window.removeEventListener('scroll', this.boundHandleScroll, true)
  }

  handleFocus() {
    this.showDropdown()
  }

  handleInput(event) {
    this.hiddenFieldTarget.value = event.target.value
    this.updateDisplayName()
    this.updateClearButtonVisibility()
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
        if (this.selectedIndex >= 0) {
          this.selectItem(this.selectedIndex)
        }
        this.hideDropdown()
      }
    }
  }

  showDropdown() {
    if (this.goalsList.length === 0) {
      return
    }

    const inputValue = this.inputTarget.value.toLowerCase()

    const filteredGoals = this.goalsList.filter(goal => {
      return goal.name.toLowerCase().includes(inputValue) ||
             goal.description.toLowerCase().includes(inputValue)
    })

    if (filteredGoals.length === 0) {
      this.hideDropdown()
      return
    }

    // Position dropdown using fixed positioning so it works both in normal-flow
    // containers (sessions/new) and inside fixed-positioned containers (follow-up form).
    const inputRect = this.inputTarget.getBoundingClientRect()
    const viewportHeight = window.innerHeight
    const spaceBelow = viewportHeight - inputRect.bottom
    const spaceAbove = inputRect.top
    const dropdownMaxHeight = 384 // max-h-96 = 24rem = 384px

    this.dropdownTarget.style.position = 'fixed'
    this.dropdownTarget.style.left = `${inputRect.left}px`
    this.dropdownTarget.style.width = `${inputRect.width}px`

    if (spaceBelow < dropdownMaxHeight && spaceAbove > spaceBelow) {
      this.dropdownTarget.style.bottom = `${viewportHeight - inputRect.top}px`
      this.dropdownTarget.style.top = 'auto'
    } else {
      this.dropdownTarget.style.top = `${inputRect.bottom}px`
      this.dropdownTarget.style.bottom = 'auto'
    }

    this.dropdownTarget.innerHTML = filteredGoals.map((goal, index) => `
      <div class="goal-item px-4 py-3 cursor-pointer hover:bg-indigo-50 border-b border-gray-100 last:border-b-0 ${index === 0 ? 'bg-gray-50' : ''}"
           data-index="${index}"
           data-description="${this.escapeHtml(goal.description)}"
           data-action="click->goal#selectItemFromClick">
        <div class="text-sm font-medium text-gray-900">${this.escapeHtml(goal.name)}</div>
        <div class="text-xs text-gray-600 mt-1">${this.escapeHtml(goal.description)}</div>
      </div>
    `).join('')

    this.dropdownTarget.classList.remove("hidden")
    this.selectedIndex = 0
    this.filteredGoals = filteredGoals
  }

  hideDropdown() {
    this.dropdownTarget.classList.add("hidden")
    this.selectedIndex = -1
  }

  selectItemFromClick(event) {
    const index = parseInt(event.currentTarget.dataset.index)
    this.selectItem(index)
  }

  selectItem(index) {
    if (!this.filteredGoals || index < 0 || index >= this.filteredGoals.length) {
      return
    }

    const goal = this.filteredGoals[index]
    this.inputTarget.value = goal.description
    this.hiddenFieldTarget.value = goal.description
    this.hideDropdown()

    this.updateDisplayName()
    this.updateClearButtonVisibility()

    this.inputTarget.dispatchEvent(new Event('input', { bubbles: true }))
  }

  selectNextItem() {
    const items = this.dropdownTarget.querySelectorAll('.goal-item')
    if (this.selectedIndex < items.length - 1) {
      items[this.selectedIndex].classList.remove('bg-gray-50')
      this.selectedIndex++
      items[this.selectedIndex].classList.add('bg-gray-50')
      this.scrollItemIntoView(items[this.selectedIndex])
    }
  }

  selectPreviousItem() {
    const items = this.dropdownTarget.querySelectorAll('.goal-item')
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
    if (!this.element.contains(event.target)) {
      this.hideDropdown()
    }
  }

  handleScroll(event) {
    // Ignore scroll events originating from inside the dropdown itself —
    // the list has its own internal scroll (max-h-96 + overflow-y-auto).
    // Only hide on outer page/container scrolls so the fixed-positioned
    // dropdown doesn't visually detach from its input.
    if (this.dropdownTarget.contains(event.target) || event.target === this.dropdownTarget) {
      return
    }
    this.hideDropdown()
  }

  escapeHtml(text) {
    const div = document.createElement('div')
    div.textContent = text
    return div.innerHTML
  }

  handleAgentRootChange(event) {
    // Get the selected agent root name from the radio button's data attribute,
    // or from the select element's value (for triggers form).
    // We use agent root name instead of URL because multiple agent roots can share
    // the same URL (e.g., monorepo with different subdirectories)
    const selectedAgentRootName = event.target.dataset.agentRootName || event.target.value

    const agentRootDefaults = this.agentRootDefaultsValue || {}
    const defaultGoal = agentRootDefaults[selectedAgentRootName]

    if (defaultGoal) {
      this.inputTarget.value = defaultGoal
      this.hiddenFieldTarget.value = defaultGoal
    } else {
      this.inputTarget.value = ''
      this.hiddenFieldTarget.value = ''
    }

    this.updateDisplayName()
    this.updateClearButtonVisibility()
    this.hideDropdown()
  }

  updateDisplayName() {
    if (!this.hasDisplayNameTarget) {
      return
    }

    const currentValue = this.inputTarget.value.trim()

    if (!currentValue) {
      this.displayNameTarget.textContent = ''
      return
    }

    const matchingGoal = this.goalsList.find(goal =>
      goal.description === currentValue || goal.id === currentValue
    )

    if (matchingGoal) {
      this.displayNameTarget.textContent = matchingGoal.name
    } else {
      this.displayNameTarget.textContent = 'Custom'
    }
  }

  updateClearButtonVisibility() {
    if (!this.hasClearButtonTarget) {
      return
    }

    const hasValue = this.inputTarget.value.trim().length > 0
    if (hasValue) {
      this.clearButtonTarget.classList.remove('hidden')
    } else {
      this.clearButtonTarget.classList.add('hidden')
    }
  }

  clear(event) {
    event.preventDefault()

    this.inputTarget.value = ''
    this.hiddenFieldTarget.value = ''

    this.updateDisplayName()
    this.updateClearButtonVisibility()
    this.hideDropdown()

    this.inputTarget.focus()
  }
}
