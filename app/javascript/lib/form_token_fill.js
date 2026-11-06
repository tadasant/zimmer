// Gives a same-origin POST form the page's CSRF token when it has none.
//
// A partial broadcast over a Turbo Stream is rendered by a job or a callback, with
// no user and no session. Rails cannot mint a token for nobody, so `form_with` and
// `button_to` leave the hidden field out of that render and the form lands in the
// page tokenless. A Turbo submission is unaffected, because Turbo sends the meta
// tag's token as a header. A `data-turbo="false"` form sends only its own fields.
//
// The page always holds the right token, so this adds it as the form submits. The
// server checks it exactly as it checks an embedded one. A form that already has a
// token keeps it, so an in-request render still sends its per-form token.
//
// The token must never leave this site or land in a URL, so the check reads where
// the submission is really going: a submitter's `formaction` and `formmethod` beat
// the form's own attributes. That is why this listens to `submit`, the one event
// that names the submitter. `form.submit()` fires no event, so a form built in
// JavaScript and sent that way adds its own token, as every one in this app does.

import { csrfParam, csrfToken } from "lib/csrf"

function submitsByPost(form, submitter) {
  const method = submitter?.getAttribute("formmethod") || form.getAttribute("method") || "get"
  return method.toLowerCase() === "post"
}

function targetsThisOrigin(form, submitter) {
  // getAttribute, because a field named "action" shadows `form.action`.
  const action = submitter?.getAttribute("formaction") || form.getAttribute("action") || window.location.href
  return new URL(action, document.baseURI).origin === window.location.origin
}

function fillMissingToken(event) {
  const form = event.target
  const param = csrfParam()
  const token = csrfToken()
  if (!param || !token || form.elements.namedItem(param)) return
  if (!submitsByPost(form, event.submitter) || !targetsThisOrigin(form, event.submitter)) return

  const input = document.createElement("input")
  input.type = "hidden"
  input.name = param
  input.value = token
  form.append(input)
}

// Capture, so the field is in place before any other `submit` listener reads the form.
document.addEventListener("submit", fillMissingToken, true)
