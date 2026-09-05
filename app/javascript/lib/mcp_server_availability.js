// Shared rendering for the availability flag both MCP-server pickers carry.
//
// The server options handed to `mcp-server-select` (new session / trigger forms)
// and `editable-mcp-servers` (session detail) come from the same Ruby builder,
// `McpServerOptions`, so each option may carry `unavailable` and
// `unavailable_reason`. Zimmer knows in advance that such a server cannot start
// — an unresolved `${VAR}` raises at prepare time and fails the whole session,
// not just that server — and the picker's job is to say so at pick time.
//
// Flagged, not hidden, and not blocked. A human is the one who can *fix* most of
// these ("OAuth authorization not completed" is one click away at /connectors),
// which is exactly what an agent reading `get_configs` cannot do, so where that
// surface omits the entry this one shows it and says why. Refusing the pick
// outright is the write path and belongs to its own change.

// Escape for interpolation into the picker markup. Its own copy rather than the
// callers' method, so this module cannot be handed an unbound one.
//
// The `textContent` round trip escapes `&`, `<` and `>` — everything a TEXT node
// needs — and deliberately leaves quotes alone, because a text node does not need
// them escaped. Quotes are added here anyway: this string is written in a
// different repository, and one that reached an `attr="..."` interpolation could
// close the attribute and add an event handler to the row.
function escapeHtml(text) {
  const div = document.createElement("div")
  div.textContent = text
  return div.innerHTML.replace(/"/g, "&quot;").replace(/'/g, "&#39;")
}

// Sort unavailable options after available ones, preserving catalog order within
// each group. The flag should not make a usable server harder to find.
export function byAvailabilityThenOrder(servers) {
  const available = []
  const unavailable = []
  servers.forEach(server => (server.unavailable ? unavailable : available).push(server))
  return available.concat(unavailable)
}

// The dropdown row's badge and reason line. Empty string for an available
// server, so the row's markup is unchanged for the common case.
export function unavailableRowMarkup(server) {
  if (!server.unavailable) return ""

  const reason = server.unavailable_reason
  return `
        <div class="flex items-center gap-1.5 mt-0.5">
          <span class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-amber-100 text-amber-800 flex-shrink-0">Unavailable</span>
          ${reason ? `<span class="text-xs text-amber-700 truncate">${escapeHtml(reason)}</span>` : ""}
        </div>`
}

// Title-attribute text for a row or a selected tag, so the reason survives
// truncation and is reachable by hover and by a screen reader.
export function unavailableTitle(server) {
  if (!server.unavailable) return ""
  const reason = server.unavailable_reason
  return `Unavailable${reason ? `: ${reason}` : ""} — attaching this server will fail the session at startup.`
}
