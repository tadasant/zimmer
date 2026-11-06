// Gives a same-origin POST form the page's CSRF token when it arrived without one.
//
// A partial broadcast over a Turbo Stream is rendered by a job or a callback, with
// no user and no session. Rails cannot mint a token for nobody, so `form_with` and
// `button_to` leave the hidden field out of that render and the form lands in the
// page tokenless. A Turbo submission never notices: Turbo sends the meta tag's token
// as a header. A `data-turbo="false"` form has only its own fields, so it reached
// the server with nothing and got the bare 422 page, on the form's own URL.
//
// The page always holds the right token, so this adds it where a submission is
// assembled. `formdata` fires for a click, for `requestSubmit()` and for
// `form.submit()` alike, which a `submit` listener would not. Nothing is relaxed:
// the server checks this token exactly as it checks an embedded one.
//
// A form that already carries a token keeps it, so an in-request render still sends
// its per-form token. A form aimed at another origin is left alone: the token must
// not leave this site.

import { csrfToken } from "lib/csrf"

const DEFAULT_PARAM = "authenticity_token"

function targetsThisOrigin(form) {
  // getAttribute, because a field named "action" shadows `form.action`.
  const action = form.getAttribute("action") || window.location.href
  return new URL(action, window.location.href).origin === window.location.origin
}

export function fillMissingToken(event) {
  const form = event.target
  if ((form.getAttribute("method") || "get").toLowerCase() !== "post") return

  const param = document.querySelector('meta[name="csrf-param"]')?.content || DEFAULT_PARAM
  if (event.formData.has(param) || !targetsThisOrigin(form)) return

  const token = csrfToken()
  if (token) event.formData.set(param, token)
}

document.addEventListener("formdata", fillMissingToken)
