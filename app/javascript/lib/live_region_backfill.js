// Bring a page back up to date without navigating.
//
// Turbo Stream broadcasts are fire-and-forget. A page whose ActionCable socket
// died missed every update sent while it was away, and re-subscribing cannot
// replay them — only the server can say what the page should look like now.
// Re-rendering the whole document does recover that content, at the cost of
// everything the reader had accumulated on screen: scroll position, open
// disclosures, expanded items, the drawer. On iOS the socket dies on every
// reopen of a standalone PWA, so that cost was being paid every single time the
// user switched back to the app.
//
// This recovers the same content by fetching the page the server would render
// now and reconciling only the regions broadcasts actually target. Everything
// else — the document the reader was looking at — is left untouched.
//
// Regions declare how they reconcile with `data-live-region`, and the values
// mirror what the broadcasts do to them (see BroadcastService):
//
//   append   Broadcasts only add children — the timeline, elicitation banners.
//            Children the live page lacks are appended in server order and
//            nothing already on screen is touched, so older pages pulled in by
//            infinite scroll and any expanded item survive. A child marked
//            `data-live-transient` (the empty-state placeholder) is dropped once
//            the server stops rendering it.
//   replace  Broadcasts swap the whole element — status badge, header actions,
//            metadata, the composer. Swapped only when the server's copy differs.
//   sync     Broadcasts add, replace AND remove children — the dashboard's
//            session grids. Reconciled by id, in the server's order.
//
// Nothing the reader is currently using is ever swapped: see `inUse`.

// A region holding an edit in progress is left alone, whatever the server says.
// Losing an update is recoverable — the next broadcast carries it, and the user
// can pull to refresh. Losing half-typed text is not.
function inUse(element) {
  if (element.contains(document.activeElement)) return true

  return Array.from(element.querySelectorAll("input, textarea")).some((field) => {
    if (field.type === "checkbox" || field.type === "radio") {
      return field.checked !== field.defaultChecked
    }
    return field.value !== field.defaultValue
  })
}

function childrenWithIds(element) {
  return Array.from(element.children).filter((child) => child.id)
}

function liveChildById(parent, id) {
  return Array.from(parent.children).find((child) => child.id === id)
}

function appendMissing(live, source) {
  let changed = 0

  for (const child of childrenWithIds(source)) {
    // Anywhere in the document, not just this region: an item that moved is
    // still on screen, and importing a second copy would duplicate it.
    if (document.getElementById(child.id)) continue
    live.appendChild(document.importNode(child, true))
    changed += 1
  }

  // A placeholder the server has stopped rendering ("No activity yet") would
  // otherwise sit above the items that just arrived.
  for (const child of Array.from(live.querySelectorAll("[data-live-transient][id]"))) {
    if (source.querySelector(`[data-live-transient][id="${child.id}"]`)) continue
    child.remove()
    changed += 1
  }

  return changed
}

function replaceElement(live, source) {
  if (live.isEqualNode(source)) return null
  if (inUse(live)) return null

  const replacement = document.importNode(source, true)
  live.replaceWith(replacement)
  return replacement
}

function syncChildren(live, source) {
  let changed = 0
  const sourceChildren = childrenWithIds(source)
  const sourceIds = new Set(sourceChildren.map((child) => child.id))

  for (const child of Array.from(live.children)) {
    if (!child.id || sourceIds.has(child.id) || inUse(child)) continue
    child.remove()
    changed += 1
  }

  // Walk the server's order and pull each child into place behind the last one,
  // so a card broadcast as a prepend lands at the top rather than the bottom.
  let previous = null

  for (const sourceChild of sourceChildren) {
    const existing = liveChildById(live, sourceChild.id)
    let node = existing

    if (!existing) {
      node = document.importNode(sourceChild, true)
      changed += 1
    } else {
      const replacement = replaceElement(existing, sourceChild)
      if (replacement) {
        node = replacement
        changed += 1
      }
    }

    const slot = previous ? previous.nextSibling : live.firstChild
    if (node !== slot) live.insertBefore(node, slot)
    previous = node
  }

  return changed
}

// Reconcile every marked region in `document` against the same region in a
// freshly fetched copy of the page. Returns the number of regions changed.
export function backfillLiveRegions(freshDocument) {
  let changed = 0

  for (const live of document.querySelectorAll("[data-live-region][id]")) {
    // A region nested inside one that was just replaced is already current, and
    // its node is no longer in the document.
    if (!live.isConnected) continue

    const source = freshDocument.getElementById(live.id)
    if (!source) continue

    switch (live.dataset.liveRegion) {
      case "append":
        changed += appendMissing(live, source) > 0 ? 1 : 0
        break
      case "sync":
        changed += syncChildren(live, source) > 0 ? 1 : 0
        break
      default:
        changed += replaceElement(live, source) ? 1 : 0
    }
  }

  return changed
}
