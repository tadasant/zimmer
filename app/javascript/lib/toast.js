// A toast the client shows itself, into the layout's one `#flash` container.
//
// Every server action that answers a Turbo request streams its notice or alert
// into `#flash` (TurboFlash#flash_stream). An action the client shows at the
// click — a row taken away, a switch flipped, a message put under the
// conversation — has nothing from the server yet, and when the server then
// refuses or cannot be reached, the client is the one that has to say so. This
// draws the same card `shared/_flash.html.erb` draws, so a refusal the client
// reports reads exactly like one the server streamed, and the `flash` Stimulus
// controller dismisses it the same way.
//
// `type` is "notice" (green rule) or "alert" (red rule). `actions` are inline
// buttons under the text, as the server's Undo and "Archive anyway" are:
// `{ label, onClick }` runs a function; `{ label, href, method }` posts a form
// through Turbo, as `button_to` does.

import { csrfToken } from "lib/csrf"

const CONTAINER_ID = "flash"
// Matches ApplicationHelper#flash_duration_ms for a bare notice or alert.
const DEFAULT_DURATION = 5000

export function showToast({ type = "notice", message, duration = DEFAULT_DURATION, actions = [] }) {
  const container = flashContainer()
  const card = document.createElement("div")
  card.dataset.controller = "flash"
  card.dataset.flashDurationValue = String(duration)
  card.className = `bg-white shadow-lg rounded-lg px-6 py-4 max-w-md transform transition-all duration-300 ease-in-out ${type === "notice" ? "border-l-4 border-green-500" : "border-l-4 border-red-500"}`
  card.setAttribute("role", type === "alert" ? "alert" : "status")
  card.dataset.clientToast = type

  const row = document.createElement("div")
  row.className = "flex items-start"
  const body = document.createElement("div")
  body.className = "flex-1"

  const heading = document.createElement("p")
  heading.className = "text-sm font-medium text-gray-900"
  heading.textContent = type === "alert" ? "Alert" : "Notice"
  const text = document.createElement("p")
  text.className = "text-sm text-gray-600 mt-1"
  text.textContent = message
  body.append(heading, text)

  if (actions.length > 0) {
    const bar = document.createElement("div")
    bar.className = "mt-3 flex flex-wrap gap-2"
    actions.forEach((action) => bar.appendChild(actionButton(action, card)))
    body.appendChild(bar)
  }

  const dismiss = document.createElement("button")
  dismiss.type = "button"
  dismiss.dataset.action = "click->flash#dismiss"
  dismiss.className = "ml-4 text-gray-400 hover:text-gray-600 focus:outline-none"
  dismiss.innerHTML = '<span class="sr-only">Dismiss</span><svg class="h-5 w-5" viewBox="0 0 20 20" fill="currentColor" aria-hidden="true"><path fill-rule="evenodd" d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z" clip-rule="evenodd" /></svg>'

  row.append(body, dismiss)
  card.appendChild(row)
  container.appendChild(card)
  return card
}

export function showAlert(message, options = {}) {
  return showToast({ type: "alert", message, ...options })
}

export function showNotice(message, options = {}) {
  return showToast({ type: "notice", message, ...options })
}

// The layout renders `#flash` on every page; a page that somehow lacks it (a
// bare error page) gets one made in the same place, so a toast is never lost.
function flashContainer() {
  let container = document.getElementById(CONTAINER_ID)
  if (!container) {
    container = document.createElement("div")
    container.id = CONTAINER_ID
    container.className = "fixed top-4 right-4 z-50 space-y-2"
    document.body.appendChild(container)
  }
  return container
}

function actionButton({ label, onClick, href, method = "post", tone = "indigo", confirm }, card) {
  const classes = tone === "red"
    ? "text-white bg-red-600 hover:bg-red-700 focus:ring-red-500"
    : "text-white bg-indigo-600 hover:bg-indigo-700 focus:ring-indigo-500"
  const base = `inline-flex items-center px-3 py-1.5 border border-transparent text-xs font-medium rounded-md shadow-sm focus:outline-none focus:ring-2 focus:ring-offset-2 ${classes}`

  if (href) {
    // The shape `button_to` renders, so Turbo submits it and the server answers
    // with the stream it answers every other such button with.
    const form = document.createElement("form")
    form.method = "post"
    form.action = href
    form.className = "inline"
    if (confirm) form.dataset.turboConfirm = confirm
    if (method !== "post") {
      const override = document.createElement("input")
      override.type = "hidden"
      override.name = "_method"
      override.value = method
      form.appendChild(override)
    }
    const input = document.createElement("input")
    input.type = "hidden"
    input.name = "authenticity_token"
    input.value = csrfToken()
    form.appendChild(input)
    const button = document.createElement("button")
    button.type = "submit"
    button.className = base
    button.textContent = label
    form.appendChild(button)
    return form
  }

  const button = document.createElement("button")
  button.type = "button"
  button.className = base
  button.textContent = label
  button.addEventListener("click", () => {
    onClick?.()
    card.remove()
  })
  return button
}
