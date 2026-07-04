import { Controller } from "@hotwired/stimulus"

// Edit a category's name, description and frozen state from a modal on the dashboard.
//
// Each category section's Edit (pencil) button carries the category's id, name,
// description and frozen flag as action params. Clicking it opens a single shared modal
// (the "modal" target) prefilled with those values. Submitting PATCHes /categories/:id;
// on success the section header's name, frozen indicator, AND the Edit button's stored
// params are patched in place — we deliberately avoid re-rendering the whole section so
// the drag-and-drop grid and any in-flight broadcasts are left untouched. Patching the
// button's params keeps a second edit (without a page reload) prefilled with the
// freshly-saved values rather than the stale ones. The description is not shown on the
// dashboard, so nothing else updates visually.
export default class extends Controller {
  static targets = ["modal", "nameInput", "descriptionInput", "frozenInput", "error", "submit"]
  static values = { updateUrlTemplate: String }

  open(event) {
    const { id, name, description, frozen } = event.params
    // Stimulus JSON-coerces data-*-param values, so a category named "123" arrives as a
    // Number and "0" would be falsy. Coerce back to strings and avoid `|| ""` blanking.
    this.currentId = id
    this.nameInputTarget.value = name == null ? "" : String(name)
    this.descriptionInputTarget.value = description == null ? "" : String(description)
    // `frozen` arrives already coerced to a Boolean by Stimulus (the attribute holds
    // "true"/"false"); default to unchecked when the param is absent.
    this.frozenInputTarget.checked = frozen === true
    this.hideError()
    this.modalTarget.classList.remove("hidden")
    this.nameInputTarget.focus()
    this.nameInputTarget.select()
  }

  close(event) {
    if (event) event.preventDefault()
    this.modalTarget.classList.add("hidden")
  }

  // Close on Escape while the modal is open (bound on the modal container; the focused
  // input bubbles its keydown up to here). Matches the Escape affordance other overlays
  // on this dashboard provide.
  closeOnEscape(event) {
    if (event.key === "Escape" && !this.modalTarget.classList.contains("hidden")) {
      this.close(event)
    }
  }

  submit(event) {
    event.preventDefault()
    if (this.currentId == null) return

    const name = this.nameInputTarget.value.trim()
    if (!name) {
      this.showError("Name can't be blank")
      return
    }

    this.submitTarget.disabled = true

    this.patchCategory(this.currentId, {
      name,
      description: this.descriptionInputTarget.value,
      is_frozen: this.frozenInputTarget.checked
    })
      .then((data) => {
        this.applySaved(data.id, data.name, data.description, data.is_frozen)
        this.close()
      })
      .catch((error) => {
        this.showError(error.message)
      })
      .finally(() => {
        this.submitTarget.disabled = false
      })
  }

  // Toggle a category's frozen state directly from its header snowflake button, without
  // opening the modal. PATCHes only is_frozen (name/description are left untouched), then
  // restyles the button and syncs the Edit button's frozen param via applySaved.
  toggleFrozen(event) {
    const button = event.currentTarget
    // Read the id from the snowflake's own data-category-frozen-id rather than a
    // category-edit-id-param: that param attribute belongs solely to the Edit button so
    // applySaved's [data-category-edit-id-param] lookup keeps targeting the Edit button.
    const id = button.getAttribute("data-category-frozen-id")
    if (id == null) return

    const next = button.getAttribute("aria-pressed") !== "true"
    button.disabled = true

    this.patchCategory(id, { is_frozen: next })
      .then((data) => {
        this.applySaved(data.id, data.name, data.description, data.is_frozen)
      })
      .catch((error) => {
        // Re-read the server's truth on failure: leave the button as-is and surface the
        // error in the console; the dashboard has no inline error slot for this control.
        console.error("Failed to toggle frozen state:", error.message)
      })
      .finally(() => {
        button.disabled = false
      })
  }

  // Shared PATCH /categories/:id helper. Resolves to the parsed JSON on success and
  // rejects with the server-provided error (or an HTTP status) otherwise.
  patchCategory(id, attributes) {
    const url = this.updateUrlTemplateValue.replace("__ID__", id)

    return fetch(url, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        "X-CSRF-Token": this.csrfToken
      },
      body: JSON.stringify({ category: attributes })
    }).then((response) =>
      response.json().then((data) => {
        if (!response.ok) throw new Error(data.error || `HTTP ${response.status}`)
        return data
      })
    )
  }

  // After a successful save, patch the section header's name and frozen indicator in
  // place and refresh the Edit button's stored params so a subsequent edit (no reload)
  // prefills fresh values.
  applySaved(id, name, description, isFrozen) {
    const heading = this.element.querySelector(`[data-category-name-id="${id}"]`)
    if (heading) heading.textContent = name

    const indicator = this.element.querySelector(`[data-category-frozen-id="${id}"]`)
    this.setFrozenIndicator(indicator, isFrozen === true)

    const button = this.element.querySelector(`[data-category-edit-id-param="${id}"]`)
    if (button) {
      button.setAttribute("data-category-edit-name-param", name)
      button.setAttribute("data-category-edit-description-param", description == null ? "" : description)
      button.setAttribute("data-category-edit-frozen-param", isFrozen === true)
    }
  }

  // Restyle the always-visible header snowflake to reflect the frozen state: muted gray
  // when not frozen, sky-blue when frozen, with title/aria-label/aria-pressed updated to
  // match. Mirrors the initial render in _category_section.html.erb.
  setFrozenIndicator(el, isFrozen) {
    if (!el) return
    el.classList.toggle("text-sky-500", isFrozen)
    el.classList.toggle("hover:text-sky-600", isFrozen)
    el.classList.toggle("text-gray-300", !isFrozen)
    el.classList.toggle("hover:text-gray-500", !isFrozen)
    el.setAttribute("aria-pressed", isFrozen ? "true" : "false")
    const label = isFrozen
      ? "Frozen — excluded from refresh-all and automatic recovery. Click to unfreeze."
      : "Not frozen — included in refresh-all and automatic recovery. Click to freeze."
    el.setAttribute("title", label)
    el.setAttribute("aria-label", label)
  }

  showError(message) {
    this.errorTarget.textContent = message
    this.errorTarget.classList.remove("hidden")
  }

  hideError() {
    this.errorTarget.textContent = ""
    this.errorTarget.classList.add("hidden")
  }

  get csrfToken() {
    const meta = document.querySelector('meta[name="csrf-token"]')
    return meta ? meta.content : ""
  }
}
