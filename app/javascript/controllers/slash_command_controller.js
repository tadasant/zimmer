import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="slash-command"
// Inline typeahead for Claude skills/commands when typing "/" in a textarea.
//
// Receives the full catalog skills list via catalogSkillsValue and dynamically
// derives the typeahead from the skills-select controller's current selection.
// Listens for skills-select:skillsChanged events to rebuild the list.
// Only user-invocable skills appear in the typeahead.
//
// When user types "/" at the start of a line or after whitespace, the dropdown appears.
// Typing more filters the results. Tab or Enter selects the highlighted option.
export default class extends Controller {
  static targets = ["textarea", "dropdown"]
  static values = {
    skills: Array,        // Direct skills list for follow-up form ({name, description, type, user_invocable})
    catalogSkills: Array  // Full catalog for session creation ({name, title, description, category, user_invocable})
  }

  connect() {
    this.catalogSkillsMap = new Map()
    ;(this.catalogSkillsValue || []).forEach(s => this.catalogSkillsMap.set(s.name, s))
    this.selectedSkillNames = new Set()

    // If skills are provided directly (follow-up form), use them immediately.
    // Otherwise, wait for skills-select events (session creation page).
    this.skillsList = this.filterUserInvocableSkills(this.skillsValue)
    this.filteredItems = []
    this.selectedIndex = -1
    this.slashPosition = -1 // Position where "/" was typed
    this.isOpen = false
    this.scrollAnimationFrame = null // For throttled scroll handling

    // Close dropdown when clicking outside
    this.boundHandleClickOutside = this.handleClickOutside.bind(this)
    document.addEventListener('click', this.boundHandleClickOutside)

    // Handle scroll to reposition dropdown
    this.boundHandleScroll = this.handleScroll.bind(this)
    window.addEventListener('scroll', this.boundHandleScroll, true)
  }

  disconnect() {
    document.removeEventListener('click', this.boundHandleClickOutside)
    window.removeEventListener('scroll', this.boundHandleScroll, true)
  }

  get combinedItems() {
    return this.skillsList
  }

  // Called on input to the textarea
  handleInput(event) {
    const textarea = event.target
    const value = textarea.value
    const cursorPos = textarea.selectionStart

    // Check if we're in a slash command context
    const slashContext = this.findSlashContext(value, cursorPos)

    if (slashContext) {
      this.slashPosition = slashContext.slashPosition
      this.filterAndShowDropdown(slashContext.query, textarea)
    } else {
      this.hideDropdown()
    }
  }

  // Called on keydown in the textarea
  handleKeydown(event) {
    if (!this.isOpen) {
      return
    }

    if (event.key === "Escape") {
      event.preventDefault()
      this.hideDropdown()
    } else if (event.key === "ArrowDown") {
      event.preventDefault()
      this.selectNextItem()
    } else if (event.key === "ArrowUp") {
      event.preventDefault()
      this.selectPreviousItem()
    } else if (event.key === "Tab" || event.key === "Enter") {
      if (this.selectedIndex >= 0 && this.filteredItems[this.selectedIndex]) {
        event.preventDefault()
        this.selectItem(this.filteredItems[this.selectedIndex])
      }
    }
  }

  // Find if we're in a slash command context (after "/" at start of line or after whitespace)
  findSlashContext(value, cursorPos) {
    // Look backwards from cursor to find "/"
    for (let i = cursorPos - 1; i >= 0; i--) {
      const char = value[i]

      // If we hit whitespace or start of string before finding "/", no context
      if (char === '\n' || char === ' ' || char === '\t') {
        return null
      }

      // Found "/"
      if (char === '/') {
        // Check that "/" is at start of line or after whitespace
        const prevChar = i > 0 ? value[i - 1] : null
        if (prevChar === null || prevChar === '\n' || prevChar === ' ' || prevChar === '\t') {
          // Extract the query (text after "/" up to cursor)
          const query = value.substring(i + 1, cursorPos)
          return { slashPosition: i, query }
        }
        return null
      }
    }
    return null
  }

  // Filter items and show dropdown
  filterAndShowDropdown(query, textarea) {
    const lowerQuery = query.toLowerCase()
    const allItems = this.combinedItems

    // Filter items that match the query
    this.filteredItems = allItems.filter(item => {
      const searchText = `${item.name} ${item.description || ''}`.toLowerCase()
      return searchText.includes(lowerQuery)
    })

    // If query is not empty, prioritize exact prefix matches
    if (lowerQuery.length > 0) {
      this.filteredItems.sort((a, b) => {
        const aStartsWith = a.name.toLowerCase().startsWith(lowerQuery)
        const bStartsWith = b.name.toLowerCase().startsWith(lowerQuery)

        // Exact prefix matches first
        if (aStartsWith && !bStartsWith) return -1
        if (!aStartsWith && bStartsWith) return 1

        // Then by name length (shorter first)
        if (a.name.length !== b.name.length) {
          return a.name.length - b.name.length
        }

        // Then alphabetically
        return a.name.toLowerCase().localeCompare(b.name.toLowerCase())
      })
    }

    // Limit to 10 results
    const displayItems = this.filteredItems.slice(0, 10)

    if (displayItems.length === 0) {
      this.hideDropdown()
      return
    }

    // Position dropdown near the cursor
    this.positionDropdown(textarea)

    // Render dropdown
    this.dropdownTarget.innerHTML = displayItems.map((item, index) => `
      <div class="skill-item px-3 py-2 cursor-pointer hover:bg-indigo-50 border-b border-gray-100 last:border-b-0 ${index === 0 ? 'bg-gray-50' : ''}"
           data-index="${index}"
           data-action="click->slash-command#selectItemFromClick mouseenter->slash-command#highlightItem">
        <div class="flex items-center justify-between gap-2">
          <span class="text-sm font-medium text-gray-900">/${this.escapeHtml(item.name)}</span>
          <span class="text-xs text-gray-400">${this.itemTypeLabel(item)}</span>
        </div>
        ${item.description ? `<div class="text-xs text-gray-500 mt-0.5">${this.escapeHtml(item.description)}</div>` : ''}
      </div>
    `).join('') + (this.filteredItems.length > 10 ? `
      <div class="px-3 py-2 text-xs text-gray-400 text-center border-t border-gray-200">
        +${this.filteredItems.length - 10} more (keep typing to narrow)
      </div>
    ` : '')

    this.dropdownTarget.classList.remove("hidden")
    this.isOpen = true
    this.selectedIndex = 0
  }

  // Get a display label for the item type
  itemTypeLabel(item) {
    if (item.type === 'command') return 'command'
    return 'skill'
  }

  // Filter skills to only include those that are user-invocable.
  // Used for the follow-up form where skills are passed directly via skillsValue.
  filterUserInvocableSkills(skills) {
    return (skills || []).filter(skill => skill.user_invocable !== false)
  }

  // Get the cursor coordinates within a textarea by creating a mirror element
  getCursorCoordinates(textarea, position) {
    // Create a mirror div to measure text position
    const mirror = document.createElement('div')
    const computed = window.getComputedStyle(textarea)

    // Copy relevant styles to the mirror to match text rendering
    const stylesToCopy = [
      'fontFamily', 'fontSize', 'fontWeight', 'fontStyle',
      'letterSpacing', 'textTransform', 'wordSpacing', 'textIndent',
      'whiteSpace', 'wordBreak', 'overflowWrap', 'lineHeight',
      'paddingTop', 'paddingRight', 'paddingBottom', 'paddingLeft',
      'borderTopWidth', 'borderRightWidth', 'borderBottomWidth', 'borderLeftWidth',
      'boxSizing', 'textAlign'
    ]

    mirror.style.position = 'absolute'
    mirror.style.top = '-9999px'
    mirror.style.left = '-9999px'
    mirror.style.visibility = 'hidden'
    mirror.style.whiteSpace = 'pre-wrap'
    mirror.style.wordWrap = 'break-word'
    mirror.style.width = `${textarea.clientWidth}px`

    stylesToCopy.forEach(style => {
      mirror.style[style] = computed[style]
    })

    document.body.appendChild(mirror)

    try {
      // Get text up to position, and add a marker span
      const textBeforeCursor = textarea.value.substring(0, position)
      mirror.textContent = textBeforeCursor

      // Create a marker span to get the position
      const marker = document.createElement('span')
      marker.textContent = '|' // Just need something to measure
      mirror.appendChild(marker)

      // Get the marker position relative to the mirror
      const markerRect = marker.getBoundingClientRect()
      const mirrorRect = mirror.getBoundingClientRect()

      // Calculate relative position within the textarea's content area
      const relativeTop = markerRect.top - mirrorRect.top
      const relativeLeft = markerRect.left - mirrorRect.left

      return { top: relativeTop, left: relativeLeft }
    } finally {
      // Ensure cleanup even if an error occurs
      document.body.removeChild(mirror)
    }
  }

  // Position dropdown near the cursor in the textarea
  positionDropdown(textarea) {
    const textareaRect = textarea.getBoundingClientRect()

    this.dropdownTarget.style.position = 'fixed'
    this.dropdownTarget.style.zIndex = '9999'

    // Calculate cursor position within the textarea
    const cursorCoords = this.getCursorCoordinates(textarea, this.slashPosition)

    // Account for textarea scroll position
    const scrollTop = textarea.scrollTop
    const scrollLeft = textarea.scrollLeft

    // Calculate absolute position of cursor
    // We position at the slash character location
    const computed = window.getComputedStyle(textarea)
    const paddingTop = parseFloat(computed.paddingTop)
    const paddingLeft = parseFloat(computed.paddingLeft)
    const borderTop = parseFloat(computed.borderTopWidth)
    const borderLeft = parseFloat(computed.borderLeftWidth)

    // Get the line height to position below the current line
    const lineHeight = parseFloat(computed.lineHeight) || parseFloat(computed.fontSize) * 1.2

    // Calculate the cursor's screen position
    const cursorTop = textareaRect.top + borderTop + paddingTop + cursorCoords.top - scrollTop + lineHeight
    const cursorLeft = textareaRect.left + borderLeft + paddingLeft + cursorCoords.left - scrollLeft

    const viewportHeight = window.innerHeight
    const viewportWidth = window.innerWidth
    const maxDropdownHeight = 400

    // Determine dropdown width
    const dropdownWidth = Math.min(Math.max(textareaRect.width, 300), 400)

    // Determine vertical position
    let dropdownTop = cursorTop + 4 // 4px gap below cursor line

    if (dropdownTop + maxDropdownHeight > viewportHeight) {
      // Try positioning above the cursor
      const topPosition = cursorTop - lineHeight - maxDropdownHeight - 4

      if (topPosition >= 0) {
        this.dropdownTarget.style.top = `${topPosition}px`
        this.dropdownTarget.style.maxHeight = `${maxDropdownHeight}px`
      } else {
        // Not enough room above - position below and limit height
        this.dropdownTarget.style.top = `${dropdownTop}px`
        this.dropdownTarget.style.maxHeight = `${Math.max(100, viewportHeight - dropdownTop - 8)}px`
      }
    } else {
      this.dropdownTarget.style.top = `${dropdownTop}px`
      this.dropdownTarget.style.maxHeight = `${maxDropdownHeight}px`
    }

    // Determine horizontal position - start at cursor, but ensure it stays in viewport
    let finalLeft = cursorLeft

    if (finalLeft + dropdownWidth > viewportWidth) {
      finalLeft = Math.max(4, viewportWidth - dropdownWidth - 4)
    }
    if (finalLeft < 4) {
      finalLeft = 4
    }

    this.dropdownTarget.style.left = `${finalLeft}px`
    this.dropdownTarget.style.width = `${dropdownWidth}px`
  }

  hideDropdown() {
    this.dropdownTarget.classList.add("hidden")
    this.isOpen = false
    this.selectedIndex = -1
    this.slashPosition = -1
    this.filteredItems = []
  }

  selectItemFromClick(event) {
    const index = parseInt(event.currentTarget.dataset.index, 10)
    if (this.filteredItems[index]) {
      this.selectItem(this.filteredItems[index])
    }
  }

  highlightItem(event) {
    const index = parseInt(event.currentTarget.dataset.index, 10)
    this.updateHighlight(index)
  }

  updateHighlight(newIndex) {
    const items = this.dropdownTarget.querySelectorAll('.skill-item')
    items.forEach((item, i) => {
      if (i === newIndex) {
        item.classList.add('bg-gray-50')
      } else {
        item.classList.remove('bg-gray-50')
      }
    })
    this.selectedIndex = newIndex
  }

  selectNextItem() {
    const displayCount = Math.min(this.filteredItems.length, 10)
    if (this.selectedIndex < displayCount - 1) {
      this.updateHighlight(this.selectedIndex + 1)
      this.scrollItemIntoView()
    }
  }

  selectPreviousItem() {
    if (this.selectedIndex > 0) {
      this.updateHighlight(this.selectedIndex - 1)
      this.scrollItemIntoView()
    }
  }

  scrollItemIntoView() {
    const items = this.dropdownTarget.querySelectorAll('.skill-item')
    if (items[this.selectedIndex]) {
      items[this.selectedIndex].scrollIntoView({ block: 'nearest', behavior: 'smooth' })
    }
  }

  selectItem(item) {
    const textarea = this.textareaTarget
    const value = textarea.value

    // Replace from slashPosition to cursor with the item name
    const beforeSlash = value.substring(0, this.slashPosition)
    const afterCursor = value.substring(textarea.selectionStart)

    const insertion = '/' + item.name + ' '
    const newCursorPos = this.slashPosition + insertion.length

    const newValue = beforeSlash + insertion + afterCursor
    textarea.value = newValue

    // Position cursor after the inserted text
    textarea.setSelectionRange(newCursorPos, newCursorPos)

    // Trigger input event so other controllers (like character-counter) update
    textarea.dispatchEvent(new Event('input', { bubbles: true }))

    this.hideDropdown()
    textarea.focus()
  }

  handleClickOutside(event) {
    if (!this.hasTextareaTarget || !this.hasDropdownTarget) return

    const isOutsideTextarea = !this.textareaTarget.contains(event.target)
    const isOutsideDropdown = !this.dropdownTarget.contains(event.target)

    if (isOutsideTextarea && isOutsideDropdown) {
      this.hideDropdown()
    }
  }

  handleScroll() {
    // Throttle scroll handling using requestAnimationFrame to prevent jank
    if (this.scrollAnimationFrame) return

    this.scrollAnimationFrame = requestAnimationFrame(() => {
      this.scrollAnimationFrame = null
      if (this.isOpen && this.hasTextareaTarget) {
        this.positionDropdown(this.textareaTarget)
      }
    })
  }

  escapeHtml(text) {
    if (!text) return ''
    const div = document.createElement('div')
    div.textContent = text
    return div.innerHTML
  }

  // Handle skills-select controller dispatching skillsChanged event.
  // Derives the typeahead list from the currently-selected catalog skills,
  // filtered to only user-invocable ones.
  handleSelectedSkillsChanged(event) {
    const selectedNames = event.detail?.selectedSkills || []
    this.selectedSkillNames = new Set(selectedNames)
    this.rebuildSkillsList()

    if (this.isOpen) {
      this.hideDropdown()
    }
  }

  // Rebuild the typeahead skills list from the current selection.
  // Only includes user-invocable catalog skills that are currently selected.
  rebuildSkillsList() {
    this.skillsList = []
    this.selectedSkillNames.forEach(name => {
      const catalogSkill = this.catalogSkillsMap.get(name)
      if (catalogSkill && catalogSkill.user_invocable) {
        this.skillsList.push({
          name: catalogSkill.name,
          description: catalogSkill.description || '',
          type: 'skill'
        })
      }
    })
    this.skillsList.sort((a, b) => a.name.localeCompare(b.name))
  }

}
