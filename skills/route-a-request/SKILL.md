---
name: route-a-request
title: Route a Request
description: >
  You are the session a quick-router / chat-bubble submission landed in — a human
  typed freeform text into Zimmer's dashboard and it started you. Decide where the
  request belongs — answer it here, or start a session on the agent root that owns
  it — and then get out of the way. Covers how to pick the root, what to put in
  the spawned session's prompt, and how this session comes to rest afterwards. NOT
  for a work-backlog start: a session whose prompt is an issue URL plus "please
  implement this" was spawned to DO that issue, not to route it.
user-invocable: false
---

# Route a Request

A human typed something into Zimmer's dashboard and it landed here, on the
baseline router root. Your job is to decide **where the work belongs** and put it
there. You are a dispatcher, not the implementer — this clone is
`tadasant/zimmer` at its root, which is the right place for a Zimmer code change
and the wrong place for almost everything else.

## First: is this actually a routing job?

The router root is also where **work-backlog starts** run — `WorkBacklog::Start`
spawns on `AgentRootsConfig.router_root_name`, so an item the groomer pulled, or
one promoted from the Issues page, arrives on this root looking like every other
session here. Its prompt is an issue URL followed by "Please implement this."

**That session is the implementer, and this skill does not apply to it.** The
backlog item records *your* session id as the one that started it, so dispatching
the work elsewhere and archiving leaves the item pointing at a session that did
nothing and the real work running where the backlog cannot see it. If your prompt
is a work-backlog start, stop reading and go implement the issue here.

The same goes for any prompt that arrives already scoped to this repo with a goal
attached. Routing is for freeform human text that has not yet been aimed at
anything.

## Decide first: answer, or dispatch

Three outcomes, in the order you should consider them.

1. **Answer it here.** A question about the fleet, a status lookup, a small
   read-only investigation. `quick_search_sessions` and `get_session` reach the
   whole deployment. Answer in your final message and archive — do not spawn a
   session to say something you already know.
2. **Dispatch it.** Anything that is a piece of *work*: a change to a repo, an
   investigation that needs its own clone, a task with a deliverable. Start one
   session on the root that owns it (below) and archive.
3. **Do it here.** Only when the request is a Zimmer change *and* it is small
   enough that dispatching costs more than doing it. When in doubt, dispatch to
   `zimmer` — that root ships the Zimmer working skills (`zimmer-run-tests`,
   `open-pr`, `wait-for-ci`, `sync-docs`) and this one does not.

## Picking the root

`get_configs` lists the agent roots this connection can reach, each with the
description that says what it is for. **Read that list rather than guessing a
name** — the catalog is a separate artifact and the roots move.

Match on what the request is *about*, not on the words it uses. A prompt naming
a repository belongs on the root that clones that repository. A prompt about
Zimmer's own behaviour belongs on `zimmer`. If nothing matches, `general-agent`
is the catch-all — note in your final message that you fell back to it, so the
gap is visible. It is a weak fallback rather than a neutral one: every root this
catalog ships clones `tadasant/zimmer`, so `general-agent` gets the same clone
you already have, minus the working skills. Dispatching there buys a fresh
session and a clean prompt, not a different repository.

## Writing the spawned session's prompt

The session you start sees **only the prompt you give it**. It does not inherit
your context, so:

- **Carry the human's words through verbatim.** Quote the original request
  rather than paraphrasing it — your paraphrase is the most common way a routed
  request arrives having lost the thing that mattered.
- Add what you learned that they did not say: the issue URL you found, the
  session that is already working on it, the repo you concluded they meant.
- Set the goal deliberately. Work that should end in a reviewed PR wants
  `open-reviewed-green-pr`; a question wants a goal that lets the session answer
  and stop.
- Pass `parent_session_id` (your own session id) so the provenance tree records
  where the work came from.

## After you dispatch

Say what you did and where it went — **the session URL, in full**, because the
human reading this is often on a phone and cannot scroll back for it. Then
**archive yourself.** The session you started now holds the work; a router that
parks in `needs_input` after successfully dispatching puts a row in the human's
action queue that nothing can act on.

Stay unarchived only if you are still orchestrating several sessions you started,
or if the request itself was a question the human is waiting on an answer to.

## What not to do

- **Do not spawn more than one session per request** unless the request is
  genuinely two independent jobs. Fan-out is the router's characteristic
  failure: three sessions racing the same file, three PRs to reconcile.
- **Do not start a session to review, watch, or babysit another session.**
  Zimmer's own pollers do that.
- **Do not implement a change in a repo this root did not clone.** If the work
  belongs somewhere else, that is exactly the case this skill exists for.
