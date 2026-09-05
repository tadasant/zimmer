// The one way a Stimulus controller reads Rails' CSRF token.
//
// `csrf_meta_tags` renders `<meta name="csrf-token" content="...">` into
// app/views/layouts/application.html.erb, the only HTML layout, so the tag is
// present on every normally-rendered page — but only when forgery protection is
// on. The test environment turns it off (config/environments/test.rb), and then
// `csrf_meta_tags` renders nothing at all. Both are normal, so reading the token
// is allowed to come up empty and must never throw.
//
// One guard policy, deliberately: a missing tag yields `""` and the request goes
// out anyway. The alternative — bailing out client-side — turns a misconfigured
// page into a button that silently does nothing, which is strictly harder to
// diagnose than a 422 from the server.

// Always meta-qualified. An unqualified `[name='csrf-token']` matches the first
// element in document order carrying that name, `<meta>` or not.
const SELECTOR = 'meta[name="csrf-token"]'

// The token, or "" when the page carries no CSRF meta tag.
export function csrfToken() {
  return document.querySelector(SELECTOR)?.content || ""
}

// Headers for a JSON request body. Anything sending FormData wants the browser
// to set Content-Type itself (it carries the multipart boundary), so those call
// sites use `csrfToken()` directly instead.
export function csrfHeaders(extra = {}) {
  return { "Content-Type": "application/json", "X-CSRF-Token": csrfToken(), ...extra }
}
