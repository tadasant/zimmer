# Zimmer brand and philosophy

The single source of truth for what Zimmer is, who it's for, and the opinions
that follow. Read this before writing anything user-facing — docs, README, UI
copy, marketing. When a wording or design choice is ambiguous, this decides it.

## What Zimmer is

Zimmer is self-hostable orchestration for AI coding agents. You hand it a task
and a repository; it runs a real coding agent against a real clone, closes the
loop on its own, and hands you back a pull request to approve.

## The five things it stands for

### 1. Open source and standards-driven

Zimmer is built on open standards, not a proprietary stack you rent. Model
Context Protocol for tools, OAuth 2.0 with PKCE for credentials, the public AIR
catalog format for agent context, git and pull requests for everything else.
Every line is readable, every part is swappable, and nothing phones home. If a
standard exists, Zimmer uses it rather than inventing a lock-in of its own.

### 2. Flexible, with the human in control

Runtimes are pluggable, context is catalog-resolved, extensions are removable.
You can reshape almost any part of it. But the decisions that matter stay with
the human: which tasks run, which tools an agent gets, and whether a pull
request merges. Agents propose; you dispose. Zimmer never merges its own work,
and a session that needs a human sits in your queue until you deal with it.

### 3. It handles the toil

The point of an orchestrator is to do the tedious part. Zimmer spawns the agent,
watches it, waits for CI, runs the review, retries transient failures, refreshes
tokens, and cleans up clones. What comes back to you is a finished, verified pull
request or a specific question about why it couldn't finish. Not a terminal to
babysit.

### 4. Built for a single circle of trust

Zimmer is designed for one person automating their own work, or a couple, or
business partners: people who trust each other completely and answer to one
ultimate authority. Input going in is trusted uniformly. That assumption is the
whole design premise, and it's a feature, not a limitation.

It is **not** built for teams, for friends, or for the enterprise. There is no
notion of "another user you don't fully trust." If your situation needs that,
Zimmer is the wrong tool, and we would rather say so than bolt on half of an
access-control system.

### 5. Secure where it counts, simple where it doesn't

Because trust at the top is uniform, Zimmer skips the machinery that only exists
to mediate distrust: accounts, roles, RBAC, per-user gates, enterprise SSO.
Leaving that out is a deliberate choice that buys a cleaner product, not a
corner cut.

What Zimmer does not skip is downstream blast-radius control. Each session gets
exactly the tools it needs and no more; the MCP server list is a per-session
permission boundary; credentials follow the tools that need them; the pull
request is the review gate. The boundary Zimmer defends is *"what can this agent
break,"* never *"which teammate is allowed to click this."*

## The perimeter is the boundary

The uniform-trust model implies a **network perimeter, not a login wall.** The
intended deployment is self-hosted behind your own private network (Zimmer's own
infrastructure puts it on a Tailscale tailnet with the public port closed). That
is why there is no sign-in screen: adding one would tax the UX for every session
to guard against a threat the trust model says isn't there.

This is deliberate, and it is load-bearing. The perimeter *is* the authentication
boundary, so breaking it — exposing the app to the open internet — removes the
only wall there is. Say that plainly wherever it's relevant. We would rather name
the sharp edge than hide it behind a half-measure login that implies a security
guarantee we don't make.

## What this means when you write or design

- **Frame the trust model as intent, not apology.** "No user accounts" is a
  design stance for a single circle of trust — write it that way. Still name the
  genuine sharp edges honestly (a misconfigured public perimeter is a real risk).
- **Lead with self-hostable, open, standards-built.** Those are the differentiators.
- **Show the human staying in control**: the PR gate, the needs-input queue, the
  per-session tool boundary. Never imply the agent has the final say.
- **Sell the toil it removes**, not the agent's cleverness. The promise is a
  verified PR with no babysitting, not magic.
- **Don't reach for enterprise vocabulary** — no "teams," "workspaces,"
  "organizations," "seats," "roles," "compliance." That's a different product.
- **Be honest.** Zimmer's docs name real bugs and real limitations on purpose.
  Confidence and candor are the same voice here, not opposites.
