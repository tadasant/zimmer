import { Controller } from "@hotwired/stimulus"

// Single-select autocomplete for the agent root field on the new session form.
// Renders hidden radio inputs so existing change-event listeners on other
// controllers (goal, mcp-server-select, skills-select, hooks-select,
// plugins-select, model-select) keep working unchanged.
//
// The root list is intentionally NOT filtered by the selected runtime: a
// session's runtime is a per-session override (sessions.agent_runtime), so any
// agent root is launchable under any registered runtime. The runtime selector
// only swaps the model catalog (handled by model-select), never the roots.
export default class extends Controller {
  static targets = ["input", "dropdown", "selectedDisplay", "radio", "nameField"]
  static values = {
    roots: Array // [{ name, displayName, url, path }, ...]
  }

  connect() {
    this.rootsList = this.rootsValue || []
    this.selectedIndex = -1
    this.filteredRoots = []
    this.hideDropdown()
    this.renderSelected()

    this.boundHandleClickOutside = this.handleClickOutside.bind(this)
    document.addEventListener("click", this.boundHandleClickOutside)
  }

  disconnect() {
    document.removeEventListener("click", this.boundHandleClickOutside)
  }

  get selectedRoot() {
    const checkedRadio = this.radioTargets.find(r => r.checked)
    if (!checkedRadio) return null
    const name = checkedRadio.dataset.agentRootName
    return this.rootsList.find(r => r.name === name) || null
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
        const displayRoots = this.filteredRoots.slice(0, 10)
        if (this.selectedIndex >= 0 && displayRoots[this.selectedIndex]) {
          this.selectRoot(displayRoots[this.selectedIndex].name)
        }
      }
    } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault()
      this.showDropdown()
    }
  }

  showDropdown() {
    const inputValue = this.inputTarget.value.toLowerCase().trim()
    const searchTerms = inputValue ? inputValue.split(/\s+/).filter(t => t.length > 0) : []
    const selectedName = this.selectedRoot?.name

    this.filteredRoots = this.rootsList.filter(root => {
      if (root.name === selectedName) {
        return false
      }
      if (searchTerms.length === 0) {
        return true
      }
      const haystack = `${root.displayName} ${root.name} ${root.path || ""}`.toLowerCase()
      return searchTerms.every(term => haystack.includes(term))
    })

    if (this.filteredRoots.length === 0) {
      this.hideDropdown()
      return
    }

    const inputRect = this.inputTarget.getBoundingClientRect()
    const scrollTop = window.pageYOffset || document.documentElement.scrollTop
    const scrollLeft = window.pageXOffset || document.documentElement.scrollLeft

    this.dropdownTarget.style.position = "absolute"
    this.dropdownTarget.style.top = `${inputRect.bottom + scrollTop}px`
    this.dropdownTarget.style.left = `${inputRect.left + scrollLeft}px`
    const maxWidth = window.innerWidth - 32
    this.dropdownTarget.style.width = `${Math.min(Math.max(inputRect.width, 400), maxWidth)}px`

    const displayRoots = this.filteredRoots.slice(0, 10)
    this.dropdownTarget.innerHTML = displayRoots.map((root, index) => `
      <div class="root-item px-3 py-2 cursor-pointer hover:bg-indigo-50 border-b border-gray-100 last:border-b-0 ${index === 0 ? "bg-gray-50" : ""}"
           data-name="${this.escapeHtml(root.name)}"
           data-action="click->agent-root-select#selectItemFromClick">
        <div class="flex items-center justify-between gap-3">
          <span class="text-sm font-medium text-gray-900 truncate">${this.escapeHtml(root.displayName)}</span>
          <code class="text-xs text-gray-500 bg-gray-100 px-1.5 py-0.5 rounded flex-shrink-0">${this.escapeHtml(root.path || root.name)}</code>
        </div>
      </div>
    `).join("") + (this.filteredRoots.length > 10 ? `
      <div class="px-3 py-2 text-xs text-gray-400 text-center border-t border-gray-200">
        +${this.filteredRoots.length - 10} more results (keep typing to narrow)
      </div>
    ` : "")

    this.dropdownTarget.classList.remove("hidden")
    this.selectedIndex = 0
  }

  hideDropdown() {
    this.dropdownTarget.classList.add("hidden")
    this.selectedIndex = -1
  }

  selectItemFromClick(event) {
    const name = event.currentTarget.dataset.name
    this.selectRoot(name)
    event.stopPropagation()
  }

  selectRoot(name) {
    const radio = this.radioTargets.find(r => r.dataset.agentRootName === name)
    if (!radio) return

    this.radioTargets.forEach(r => { r.checked = false })
    radio.checked = true

    if (this.hasNameFieldTarget) {
      this.nameFieldTarget.value = name
    }

    radio.dispatchEvent(new Event("change", { bubbles: true }))

    // Broadcast so the model selector (a sibling subtree) can adopt this root's
    // default model when it is valid for the active runtime.
    document.dispatchEvent(
      new CustomEvent("ao:agent-root-changed", { detail: { agentRootName: name } })
    )

    this.inputTarget.value = ""
    this.renderSelected()
    this.hideDropdown()
  }

  renderSelected() {
    const root = this.selectedRoot
    if (!root) {
      this.selectedDisplayTarget.classList.add("hidden")
      this.selectedDisplayTarget.innerHTML = ""
      return
    }

    this.selectedDisplayTarget.classList.remove("hidden")
    this.selectedDisplayTarget.innerHTML = `
      <div class="flex items-center justify-between gap-3 px-3 py-2 bg-indigo-50 border border-indigo-200 rounded-md">
        <div class="flex items-center gap-3 min-w-0 flex-1">
          <span class="text-sm font-medium text-gray-900 truncate">${this.escapeHtml(root.displayName)}</span>
          <code class="text-xs text-gray-600 bg-white px-1.5 py-0.5 rounded flex-shrink-0">${this.escapeHtml(root.path || root.name)}</code>
        </div>
        <button type="button"
                class="text-indigo-600 hover:text-indigo-800 focus:outline-none flex-shrink-0"
                data-action="click->agent-root-select#changeSelection"
                title="Change selection">
          <svg class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
            <path stroke-linecap="round" stroke-linejoin="round" d="M4 6h16M4 12h16M4 18h7" />
          </svg>
        </button>
      </div>
    `
  }

  changeSelection(event) {
    event.preventDefault()
    event.stopPropagation()
    this.inputTarget.focus()
    this.showDropdown()
  }

  selectNextItem() {
    const items = this.dropdownTarget.querySelectorAll(".root-item")
    if (items.length === 0) return

    if (this.selectedIndex < items.length - 1) {
      if (this.selectedIndex >= 0) {
        items[this.selectedIndex].classList.remove("bg-gray-50")
      }
      this.selectedIndex++
      items[this.selectedIndex].classList.add("bg-gray-50")
      items[this.selectedIndex].scrollIntoView({ block: "nearest", behavior: "smooth" })
    }
  }

  selectPreviousItem() {
    const items = this.dropdownTarget.querySelectorAll(".root-item")
    if (items.length === 0) return

    if (this.selectedIndex > 0) {
      items[this.selectedIndex].classList.remove("bg-gray-50")
      this.selectedIndex--
      items[this.selectedIndex].classList.add("bg-gray-50")
      items[this.selectedIndex].scrollIntoView({ block: "nearest", behavior: "smooth" })
    }
  }

  handleClickOutside(event) {
    if (!this.element.contains(event.target)) {
      this.hideDropdown()
    }
  }

  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text == null ? "" : text
    return div.innerHTML
  }
}
