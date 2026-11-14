// The hand-off between the dashboard drawer's provisional composer and the
// session's real one.
//
// The drawer's detail body is one lazy frame (SessionsController#drawer), and the
// real composer arrives with it. Until it does, the drawer's loading skeleton
// carries a provisional composer (_drawer_composer.html.erb) so a reader who
// already knows what to say can type at once. When the body lands, Turbo throws
// the skeleton away — the provisional textarea, its caret and its focus with it.
// session-drawer stashes those here just before the render, and the real
// composer (follow_up_prompt_controller.js) takes them as it connects, so the
// text, the caret and the focus carry over with nothing visible in between.
//
// The text itself also goes to the session's draft in localStorage on every
// keystroke, which is what the real composer restores from in any case; the
// hand-off adds what storage does not hold — where the caret was and whether
// the field had focus — and covers a browser where storage is unavailable.
//
// One slot, one session, one take: a stash for any other session, or one older
// than MAX_AGE_MS (a body that never connected a composer — an archived
// session), is never applied.

const MAX_AGE_MS = 30 * 1000

let pending = null

export function stashComposerHandoff({ sessionId, value, selectionStart, selectionEnd, focused }, now = Date.now()) {
  if (!sessionId) return
  pending = { sessionId, value, selectionStart, selectionEnd, focused, at: now }
}

export function takeComposerHandoff(sessionId, now = Date.now()) {
  const handoff = pending
  if (!handoff || handoff.sessionId !== sessionId) return null
  pending = null
  if (now - handoff.at > MAX_AGE_MS) return null
  return handoff
}
