import { Controller } from "@hotwired/stimulus"
import { csrfHeaders } from "lib/csrf"
import { accentClasses, MISSING, MISSING_TITLE, UNAVAILABLE } from "lib/catalog_multiselect_accents"
import { byAvailabilityThenOrder, unavailableRowMarkup, unavailableTitle } from "lib/mcp_server_availability"

// Connects to data-controller="catalog-multiselect"
//
// The one catalog multi-select in Zimmer — skills, hooks, plugins and MCP
// servers, on the session detail page and on the new-session and trigger forms.
// It replaced eight copy-pasted controllers that differed only in an accent
// colour, an identity field and where the selection went (zimmer#456).
//
// TWO MODES, chosen by whether `persistUrl` is set:
//
//   * INLINE EDIT (persistUrl present) — the session detail page. A display
//     region and an editor region that swap, with an optimistic PATCH behind
//     Save.
//
//   * FORM (persistUrl absent) — the new-session and trigger forms. Always
//     open, no Save; the selection is mirrored into hidden inputs named
//     `inputName` and submits with the surrounding form. `agentRootDefaults`
//     repopulates it when the operator picks a different agent root.
//
// Two things are deliberately NOT parameterised here:
//
//   * The identity field. Skills and hooks key on `name`, plugins and MCP
//     servers key on `id`/`name` — but that split is resolved at the VIEW layer:
//     `CatalogMultiselectHelper#catalog_multiselect_items` normalises every
//     artifact to `{ key, title, ... }` before it reaches `data-*`. This file
//     knows about `key` and nothing else.
//
//   * The accent colour. It arrives as a token ("green") and is resolved through
//     a static class table, never interpolated — see lib/catalog_multiselect_accents.js
//     for why the tidier version silently ships an unstyled widget.
export default class extends Controller {
  static targets = ["display", "editor", "input", "dropdown", "selectedContainer", "status", "saveButton", "hiddenInputs"]

  static values = {
    // [{ key, title, description, category, unavailable, unavailable_reason }]
    items: Array,
    // Currently selected keys.
    selected: Array,
    // Keys Zimmer attached on the session's behalf. Rendered as read-only chips
    // with no remove button; only MCP servers have them today.
    injected: { type: Array, default: [] },
    accent: { type: String, default: "green" },
    // Skills are the only catalog with a category taxonomy worth grouping by.
    groupByCategory: { type: Boolean, default: false },
    // Whether a dropdown row gets a second line with the artifact's description.
    showDescription: { type: Boolean, default: false },
    // Classes for a chip in the DISPLAY region, which the two layouts style
    // differently (the mobile card outlines its chips, the desktop meta row
    // does not). A literal string from the ERB, so Tailwind sees it there.
    displayChipClass: { type: String, default: "" },
    // Where an optimistic save PATCHes to. Its PRESENCE is what selects inline-
    // edit mode; a widget that submits with a form leaves it empty.
    persistUrl: String,
    // The key the save endpoint wraps the array in — and, in form mode, the name
    // this widget announces itself under. Always set: it is how a listener tells
    // the four widgets on one form apart.
    payloadKey: String,
    // MCP servers re-render their region server-side, because the display half
    // carries per-server connection status this controller cannot reconstruct.
    turboStream: { type: Boolean, default: false },

    // --- Form mode only ----------------------------------------------------
    // The `name` on every hidden input this widget writes, e.g.
    // "session[catalog_skills][]".
    inputName: String,
    // Whether `selected` is a STORED selection (a trigger's own column) rather
    // than an agent root's defaults. A stored selection may name an artifact the
    // catalog no longer carries — a rename or a removal — and that name has to
    // survive the round-trip: the form posts the whole list, so a name this
    // control drops is a name the next save deletes from the row (zimmer#853).
    // It is kept, and marked. A root's defaults are filtered instead, because a
    // root naming an unknown artifact is a catalog-authoring bug rather than the
    // operator's configuration.
    preserveUnknown: { type: Boolean, default: false },
    // Whether an empty selection still posts one blank input, so the param key
    // is present. Only MCP servers need it: SessionsController reads
    // `session_params.key?(:mcp_servers)` to tell "deliberately none" from "the
    // form never said", and records the former so McpServerBackfill does not
    // restore the root's defaults over it.
    emitEmptyInput: { type: Boolean, default: false },
    // { agentRootName => [key, ...] } — what to reset the selection to when the
    // operator picks a different agent root.
    agentRootDefaults: { type: Object, default: {} }
  }

  // How many rows the dropdown shows before it says "keep typing".
  static MAX_SHOWN = 10

  // The margin kept between the dropdown and the edge it is nearest.
  static GAP = 8

  // The shortest a dropdown is ever made, even where there is no room for it:
  // a two-row list a person can scroll beats a sliver they cannot read.
  static MIN_HEIGHT = 120

  connect() {
    this.itemsList = this.itemsValue || []
    this.filteredItems = []
    this.selectedIndex = -1

    // Form mode has no display/editor swap: the widget is open from the moment
    // it connects, which is also what makes `handleClickOutside` behave.
    this.isEditing = this.formMode

    const initial = this.formMode ? this.retained(this.selectedValue || []) : (this.selectedValue || [])
    this.selectedKeys = new Set(initial)
    this.originalKeys = new Set(initial)

    if (this.formMode) this.syncForm()

    this.boundHandleClickOutside = this.handleClickOutside.bind(this)
    document.addEventListener("click", this.boundHandleClickOutside)

    // The dropdown is position:fixed, so it does not follow its anchor on scroll.
    this.boundHandleScroll = this.handleScroll.bind(this)
    window.addEventListener("scroll", this.boundHandleScroll, true)
  }

  disconnect() {
    document.removeEventListener("click", this.boundHandleClickOutside)
    window.removeEventListener("scroll", this.boundHandleScroll, true)
  }

  get accent() {
    return accentClasses(this.accentValue)
  }

  // No save endpoint means the selection submits with the surrounding form.
  get formMode() {
    return this.persistUrlValue === ""
  }

  // --- Mode -----------------------------------------------------------------

  edit() {
    this.isEditing = true
    this.displayTarget.classList.add("hidden")
    this.editorTarget.classList.remove("hidden")
    this.updateSelectedDisplay()
    this.inputTarget.focus()
  }

  cancel() {
    // Form mode has nothing to revert to and no display region to fall back on.
    // Reached from Escape with the dropdown already closed.
    if (this.formMode) return

    this.isEditing = false
    this.selectedKeys = new Set(this.originalKeys)
    this.editorTarget.classList.add("hidden")
    this.displayTarget.classList.remove("hidden")
    this.hideDropdown()
    this.setStatus("")
  }

  async save() {
    const keys = Array.from(this.selectedKeys)

    if (this.hasSaveButtonTarget) this.saveButtonTarget.disabled = true
    this.setStatus("Saving...", "pending")

    try {
      const response = await fetch(this.persistUrlValue, {
        method: "PATCH",
        headers: csrfHeaders({
          Accept: this.turboStreamValue ? "text/vnd.turbo-stream.html, application/json" : "application/json"
        }),
        body: JSON.stringify({ [this.payloadKeyValue]: keys })
      })

      if (response.ok) {
        await this.handleSaved(response, keys)
      } else {
        this.setStatus(await this.errorMessage(response), "error")
      }
    } catch (error) {
      console.error(`Failed to update ${this.payloadKeyValue}:`, error)
      this.setStatus(`Error: ${error.message || "Network error"}`, "error")
    } finally {
      if (this.hasSaveButtonTarget) this.saveButtonTarget.disabled = false
    }
  }

  async handleSaved(response, keys) {
    const contentType = response.headers.get("Content-Type") || ""

    if (this.turboStreamValue && contentType.includes("text/vnd.turbo-stream.html")) {
      // The server replaced this whole region. This controller instance is being
      // detached by the swap, so there is no local state left worth updating —
      // the replacement renders in display mode and connects fresh.
      Turbo.renderStreamMessage(await response.text())
      return
    }

    this.originalKeys = new Set(keys)
    this.selectedValue = keys
    this.updateDisplayText(keys)

    this.isEditing = false
    this.editorTarget.classList.add("hidden")
    this.displayTarget.classList.remove("hidden")
    this.hideDropdown()
    this.setStatus("")
  }

  // The JSON endpoints answer `{ error: "..." }`; the turbo-stream one may not
  // answer JSON at all. Read defensively rather than per-endpoint.
  async errorMessage(response) {
    try {
      const data = await response.json()
      return data.error || "Save failed"
    } catch (_e) {
      return "Save failed"
    }
  }

  setStatus(text, tone) {
    this.statusTarget.textContent = text
    this.statusTarget.classList.remove("text-gray-500", "text-red-500")
    this.statusTarget.classList.add(tone === "error" ? "text-red-500" : "text-gray-500")
  }

  // --- Display region -------------------------------------------------------

  // Rewrite the read-only chips behind the editor after a save, so the page does
  // not have to reload to show what was just persisted. Chips the SERVER owns —
  // a skill a plugin brings in, say — live outside `catalog-selected` and are
  // left alone.
  updateDisplayText(keys) {
    const tags = this.displayTarget.querySelector('[data-role="catalog-tags"]')
    const selected = this.displayTarget.querySelector('[data-role="catalog-selected"]')
    const empty = this.displayTarget.querySelector('[data-role="catalog-empty"]')
    if (!tags || !selected) return

    selected.innerHTML = keys
      .map(key => `<span data-chip class="inline-flex items-center ${this.displayChipClassValue}">${this.escapeHtml(key)}</span>`)
      .join("")

    const hasChips = tags.querySelector("[data-chip]") !== null
    tags.classList.toggle("hidden", !hasChips)
    tags.classList.toggle("flex", hasChips)
    if (empty) empty.classList.toggle("hidden", hasChips)
  }

  // --- Dropdown -------------------------------------------------------------

  showDropdown() {
    this.filter()
  }

  filter() {
    const query = this.inputTarget.value.toLowerCase().trim()
    const terms = query ? query.split(/\s+/).filter(t => t.length > 0) : []

    this.filteredItems = this.itemsList.filter(item => {
      if (this.selectedKeys.has(item.key)) return false
      if (terms.length === 0) return true
      // AND matching: every term has to appear somewhere in the item's text.
      const haystack = `${item.title} ${item.description || ""} ${item.key} ${item.category || ""}`.toLowerCase()
      return terms.every(term => haystack.includes(term))
    })

    // An item the catalog declares unavailable stays in the list — a human can
    // usually fix why — but sorts below the usable ones so the flag never buries
    // something you can pick. A no-op for catalogs that carry no flag.
    this.filteredItems = byAvailabilityThenOrder(this.filteredItems)

    if (this.filteredItems.length === 0) {
      this.hideDropdown()
      return
    }

    this.dropdownTarget.style.position = "fixed"
    this.dropdownTarget.innerHTML = this.dropdownMarkup()

    // Titles go on as DOM properties rather than into the markup above: the
    // reason is catalog-authored text, and a property assignment cannot be
    // broken out of the way an `attr="..."` interpolation can.
    this.dropdownTarget.querySelectorAll(".catalog-multiselect-item").forEach(row => {
      const item = this.filteredItems.find(i => i.key === row.dataset.key)
      if (item?.unavailable) row.title = unavailableTitle(item)
    })

    this.dropdownTarget.classList.remove("hidden")
    // After the rows are in and the element is displayed, so it can be measured.
    this.repositionDropdown()
    this.selectedIndex = 0
  }

  dropdownMarkup() {
    const max = this.constructor.MAX_SHOWN
    let html = ""

    if (this.groupByCategoryValue) {
      // Group EVERY match, then walk the categories alphabetically and stop at
      // the cap — so the cap falls on whole categories in order rather than on
      // whatever the catalog happened to list first.
      const grouped = {}
      this.filteredItems.forEach(item => {
        const category = item.category || "uncategorized"
        ;(grouped[category] ||= []).push(item)
      })

      let shown = 0
      for (const category of Object.keys(grouped).sort()) {
        if (shown >= max) break
        // A header is not a `.catalog-multiselect-item`, so keyboard nav skips it.
        html += `<div data-role="catalog-category" class="px-3 py-1.5 text-xs font-semibold uppercase tracking-wider border-b ${this.accent.categoryHeader}">${this.escapeHtml(category)}</div>`
        for (const item of grouped[category]) {
          if (shown >= max) break
          html += this.rowMarkup(item, shown++)
        }
      }
    } else {
      this.filteredItems.slice(0, max).forEach((item, index) => (html += this.rowMarkup(item, index)))
    }

    if (this.filteredItems.length > max) {
      html += `
        <div class="px-3 py-2 text-xs text-gray-400 text-center border-t border-gray-200">
          +${this.filteredItems.length - max} more results (keep typing to narrow)
        </div>`
    }

    return html
  }

  rowMarkup(item, index) {
    return `
      <div class="catalog-multiselect-item px-3 py-2 cursor-pointer border-b border-gray-100 last:border-b-0 ${this.accent.row} ${index === 0 ? "bg-gray-50" : ""}"
           data-key="${this.escapeHtml(item.key)}"
           data-action="click->catalog-multiselect#selectItemFromClick">
        <div class="flex items-center justify-between gap-3">
          <span class="text-sm font-medium ${item.unavailable ? "text-gray-500" : "text-gray-900"} truncate">${this.escapeHtml(item.title)}</span>
          <span class="text-xs text-gray-500 font-mono flex-shrink-0">${this.escapeHtml(item.key)}</span>
        </div>${unavailableRowMarkup(item)}${this.showDescriptionValue && item.description ? `
        <div data-role="catalog-description" class="text-xs text-gray-500 mt-0.5 truncate">${this.escapeHtml(item.description)}</div>` : ""}
      </div>`
  }

  hideDropdown() {
    this.dropdownTarget.classList.add("hidden")
    this.selectedIndex = -1
  }

  // The `max-h-*` the partial put on the element, read once — after the first
  // reposition writes an inline `max-height` it would shadow the class.
  get cssMaxHeight() {
    if (this.readCssMaxHeight === undefined) {
      const parsed = parseFloat(getComputedStyle(this.dropdownTarget).maxHeight)
      this.readCssMaxHeight = Number.isFinite(parsed) ? parsed : Infinity
    }
    return this.readCssMaxHeight
  }

  // Size against the viewport, then shift left if that width would not fit where
  // the input sits — this picker can live in a `flex-wrap` meta row, so its
  // anchor moves as the items before it wrap. Capping against the space to the
  // right instead would shrink it below its 400px minimum on a wide screen.
  // `clientWidth`, not `innerWidth`, which counts an in-flow scrollbar.
  //
  // Vertically it FLIPS ABOVE the input when the space below will not hold it,
  // and is clamped into the viewport either way. That is not a nicety: the
  // dropdown is position:fixed, so one opening past the bottom of the viewport
  // cannot be scrolled to at all — the page moves and it does not. The
  // bottom-most picker on the new-session form is always in that position.
  repositionDropdown() {
    const { GAP, MIN_HEIGHT } = this.constructor
    const inputRect = this.inputTarget.getBoundingClientRect()
    const viewportWidth = document.documentElement.clientWidth
    const viewportHeight = document.documentElement.clientHeight

    const width = Math.min(Math.max(inputRect.width, 400), Math.max(viewportWidth - 16, 0))
    const left = Math.max(8, Math.min(inputRect.left, viewportWidth - width - 8))
    this.dropdownTarget.style.left = `${left}px`
    this.dropdownTarget.style.width = `${width}px`

    const roomBelow = viewportHeight - inputRect.bottom - GAP
    const roomAbove = inputRect.top - GAP
    const flip = roomBelow < MIN_HEIGHT && roomAbove > roomBelow

    const room = Math.max(flip ? roomAbove : roomBelow, MIN_HEIGHT)
    this.dropdownTarget.style.maxHeight = `${Math.min(room, this.cssMaxHeight)}px`

    // Measured after the cap, so a flipped list sits ON the input's top edge
    // rather than wherever its uncapped height would have put it.
    const height = this.dropdownTarget.offsetHeight
    const preferred = flip ? inputRect.top - height - GAP : inputRect.bottom

    // Clamped into the viewport unconditionally, which is what actually makes
    // the guarantee above true. Neither side has MIN_HEIGHT to spare on a very
    // short viewport — a phone with the keyboard up — and there the floor wins
    // over the fit: the list is drawn over its own input rather than off the
    // bottom edge, because overlapping is recoverable and unreachable is not.
    const lowest = Math.max(GAP, viewportHeight - height - GAP)
    this.dropdownTarget.style.top = `${Math.min(Math.max(preferred, GAP), lowest)}px`
  }

  handleScroll() {
    // The dashboard and index render this controller read-only — no `*_for_select`,
    // so the editor partial and its dropdown are never emitted. Without the guard
    // the first scroll throws `Missing target element "dropdown"` once per widget
    // per event. (The four controllers this replaces all had the same hole.)
    if (!this.hasDropdownTarget) return

    if (!this.dropdownTarget.classList.contains("hidden")) this.repositionDropdown()
  }

  // --- Keyboard and mouse ---------------------------------------------------

  handleKeydown(event) {
    // Read the dropdown's state ONCE. Escape is meant to be two steps — close the
    // list, then leave the editor — and re-reading the class after `hideDropdown`
    // collapsed them into one, so a single Escape threw away the selection you had
    // just made. All four controllers this replaced had that shape.
    const dropdownOpen = !this.dropdownTarget.classList.contains("hidden")

    if (dropdownOpen) {
      if (event.key === "Escape") {
        event.preventDefault()
        this.hideDropdown()
      } else if (event.key === "ArrowDown") {
        event.preventDefault()
        this.moveSelection(1)
      } else if (event.key === "ArrowUp") {
        event.preventDefault()
        this.moveSelection(-1)
      } else if (event.key === "Enter") {
        event.preventDefault()
        const rows = this.rows
        if (this.selectedIndex >= 0 && rows[this.selectedIndex]) this.addItem(rows[this.selectedIndex].dataset.key)
      }
    } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault()
      this.showDropdown()
    }

    if (event.key === "Backspace" && this.inputTarget.value === "" && this.selectedKeys.size > 0) {
      this.removeItem(Array.from(this.selectedKeys).pop())
    }

    if (event.key === "Escape" && !dropdownOpen) {
      this.cancel()
    }
  }

  get rows() {
    return this.dropdownTarget.querySelectorAll(".catalog-multiselect-item")
  }

  moveSelection(delta) {
    const rows = this.rows
    if (rows.length === 0) return

    const next = this.selectedIndex + delta
    if (next < 0 || next > rows.length - 1) return

    if (this.selectedIndex >= 0) rows[this.selectedIndex].classList.remove("bg-gray-50")
    this.selectedIndex = next
    rows[this.selectedIndex].classList.add("bg-gray-50")
    rows[this.selectedIndex].scrollIntoView({ block: "nearest", behavior: "smooth" })
  }

  selectItemFromClick(event) {
    this.addItem(event.currentTarget.dataset.key)
    event.stopPropagation()
  }

  removeItemFromTag(event) {
    event.preventDefault()
    event.stopPropagation()
    this.removeItem(event.currentTarget.dataset.key)
  }

  addItem(key) {
    this.selectedKeys.add(key)
    this.formMode ? this.syncForm() : this.updateSelectedDisplay()
    this.inputTarget.value = ""
    this.inputTarget.focus()
    this.filter()
  }

  removeItem(key) {
    this.selectedKeys.delete(key)
    this.formMode ? this.syncForm() : this.updateSelectedDisplay()
    this.inputTarget.focus()
    if (!this.dropdownTarget.classList.contains("hidden")) this.filter()
  }

  // --- Form mode ------------------------------------------------------------

  // Keys the catalog still carries, unless this selection is a stored column
  // whose unknown entries have to survive the round-trip.
  retained(keys) {
    if (this.preserveUnknownValue) return keys
    return keys.filter(key => this.itemsList.some(item => item.key === key))
  }

  // Everything that has to follow a selection change in form mode: the chips,
  // the inputs that actually submit, and the announcement other controllers
  // (slash-command) build on.
  syncForm() {
    this.updateSelectedDisplay()
    this.updateHiddenInputs()
    this.announceSelection()
  }

  updateHiddenInputs() {
    if (!this.hasHiddenInputsTarget) return

    this.hiddenInputsTarget.innerHTML = ""
    const keys = Array.from(this.selectedKeys)

    if (keys.length === 0 && this.emitEmptyInputValue) {
      this.hiddenInputsTarget.appendChild(this.hiddenInput(""))
      return
    }

    keys.forEach(key => this.hiddenInputsTarget.appendChild(this.hiddenInput(key)))
  }

  hiddenInput(value) {
    const input = document.createElement("input")
    input.type = "hidden"
    input.name = this.inputNameValue
    input.value = value
    return input
  }

  // One event for all four widgets on a form; `payloadKey` is how a listener
  // tells them apart. slash-command derives its "/" typeahead from the skills
  // one — see handleSelectedSkillsChanged there.
  announceSelection() {
    this.dispatch("selectionChanged", {
      detail: { payloadKey: this.payloadKeyValue, selected: Array.from(this.selectedKeys) }
    })
  }

  // Picking an agent root replaces the selection wholesale with that root's
  // defaults — the operator is choosing a starting point, not merging into one.
  // Reached from a document-level `ao:agent-root-changed`, because the agent-root
  // control lives outside this widget's element and Stimulus actions only reach
  // controllers on an ancestor.
  handleAgentRootChange(event) {
    const rootName = event.detail?.agentRootName ?? event.target?.dataset?.agentRootName ?? event.target?.value
    const defaults = (this.agentRootDefaultsValue || {})[rootName] || []

    // Filtered against the catalog whatever `preserveUnknown` says: a root
    // naming an artifact that does not exist is a catalog bug, not a selection
    // worth preserving.
    this.selectedKeys = new Set(defaults.filter(key => this.itemsList.some(item => item.key === key)))

    this.syncForm()
    this.hideDropdown()
  }

  handleClickOutside(event) {
    if (!this.isEditing) return

    // "Outside" means outside the WIDGET, not outside the editor. Testing the
    // editor alone read the display region's own Edit button as outside — so the
    // click that opened the editor immediately closed the dropdown that opening it
    // had just shown, and the list only appeared once you typed. The display region
    // is hidden while editing, so widening the test costs nothing.
    if (!this.element.contains(event.target)) this.hideDropdown()
  }

  // --- Editor chips ---------------------------------------------------------

  // Both layouts' chip geometry, written out in full so Tailwind's scanner sees
  // every class. Form chips sit in a full-width field and are finger-sized; the
  // inline editor's sit in a dense meta row.
  get chipLayout() {
    return this.formMode
      ? "inline-flex items-center gap-1 px-2.5 py-1 rounded-md text-sm font-medium mr-2 mb-2"
      : "inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-medium"
  }

  get chipIconClass() {
    return this.formMode ? "h-3.5 w-3.5" : "h-3 w-3"
  }

  get chipRemoveIconClass() {
    return this.formMode ? "h-4 w-4" : "h-3 w-3"
  }

  updateSelectedDisplay() {
    this.selectedContainerTarget.innerHTML = ""

    this.selectedKeys.forEach(key => {
      const item = this.itemsList.find(i => i.key === key)
      // A selected key the catalog does not carry at all is a stored reference
      // that has gone unresolvable. It is MARKED, not dropped — see
      // `preserveUnknown`, which is the only thing that lets one get this far.
      const missing = !item && this.preserveUnknownValue
      // An unavailable item can still be selected — its credential may have
      // lapsed since the session was created — so the flag has to reach the
      // chips, not just the dropdown.
      const unavailable = Boolean(item?.unavailable)
      const tone = missing ? MISSING : unavailable ? UNAVAILABLE : this.accent

      const tag = document.createElement("span")
      tag.className = `${this.chipLayout} ${tone.chip}`
      if (missing) tag.title = MISSING_TITLE
      else if (unavailable) tag.title = unavailableTitle(item)
      tag.innerHTML = `
        ${missing || unavailable ? `<svg class="${this.chipIconClass} flex-shrink-0" fill="currentColor" viewBox="0 0 20 20" aria-hidden="true"><path fill-rule="evenodd" d="M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z" clip-rule="evenodd" /></svg>` : ""}
        ${this.escapeHtml(item ? item.title : key)}${missing ? " (not in catalog)" : ""}${item?.scope ? `<span class="text-xs font-mono opacity-70">${this.escapeHtml(item.scope)}</span>` : ""}
        <button type="button"
                class="${tone.chipRemove} focus:outline-none"
                data-action="click->catalog-multiselect#removeItemFromTag"
                data-key="${this.escapeHtml(key)}">
          <svg class="${this.chipRemoveIconClass}" fill="currentColor" viewBox="0 0 20 20">
            <path fill-rule="evenodd" d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z" clip-rule="evenodd" />
          </svg>
        </button>
      `
      this.selectedContainerTarget.appendChild(tag)
    })

    // Injected entries are Zimmer's, not the operator's: shown so the list is
    // honest about what will attach, with no remove button because removing one
    // here would not stick.
    this.injectedValue.forEach(key => {
      if (this.selectedKeys.has(key)) return
      const tag = document.createElement("span")
      tag.className = "inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-medium bg-gray-100 text-gray-500 italic border border-dashed border-gray-300"
      tag.title = `${key} (auto-injected, read-only)`
      tag.textContent = key
      this.selectedContainerTarget.appendChild(tag)
    })
  }

  // The `textContent` round trip escapes `&`, `<` and `>`; quotes are added
  // because several call sites above interpolate into an `attr="..."`, where an
  // unescaped quote would close the attribute and add an event handler.
  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML.replace(/"/g, "&quot;").replace(/'/g, "&#39;")
  }
}
