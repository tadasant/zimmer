---
name: recover-from-compaction-thrashing
description: >
  Avoid and recover from compaction thrashing by delegating verbose tool calls to inline subagents.
  Consult this skill when a "Conversation compacted" boundary appears in your own transcript, when an
  autocompact warning fires, or when you are about to make a tool call that is likely to dump >3k
  tokens of raw output (large file reads, SSH log streams, browser/Playwright sessions, verbose
  1Password reads, multi-input PR body drafts, big `gh` outputs). Delegating those calls to a
  subagent — which returns distilled findings instead of raw output — keeps your main thread lean
  so the next compaction does not erase the work you just did.
user-invocable: true
---

# Recover From Compaction Thrashing

Compaction thrashing happens when a session's context window keeps filling up faster than it can do useful work. Each compaction loses information, the agent gets dumber, and eventually the task gets abandoned or done wrong. The lever you control is **what work happens inside your main context** — verbose tool calls that you do not need to reason over directly should be delegated to your runtime's in-process subagent (the `Task` / `Agent` tool in Claude Code, `spawn_agent` in Codex), which returns only its distilled summary.

This skill is preventative AND reactive. Consult it before you make a verbose call you can foresee, and consult it after you observe a compaction event so the next call does not push you into the next one.

## When to use this skill

Auto-consult any time **one or more** of these is true:

- A compaction summary appears at the top of your context (the harness compacted the prior conversation), or the user mentions that a compaction just happened, or an autocompact warning fires in your session
- You are about to call a tool that is likely to produce **>3k tokens** of output (see "Patterns to delegate" below)
- A previous attempt at the same task hit context limits or compacted, and you are about to retry it

Compaction events are harness-driven and you may not always see them as discrete boundaries — the more reliable trigger in practice is the second bullet (anticipating a verbose call). Treat the first bullet as "if you have any signal a compaction occurred."

If none of these apply, you do **not** need this skill — proceed normally. Over-delegating turns simple work into slow work; the trigger conditions above are the discriminator.

## The three-strike rule

After observing **2 compaction boundaries** in a single session, the **3rd verbose tool call MUST go through a subagent** rather than be retried in the main thread. Two compactions is the signal that the main thread is the bottleneck — running the same kind of call again will cost you another compaction. Delegate it.

## Patterns to delegate

Wrap these in an in-process subagent call (the `Task` / `Agent` tool in Claude Code, `spawn_agent` in Codex) — do not run them in the main thread when a trigger condition above is active:

- **Large file reads** end-to-end — long `README.md` files, vendored lockfiles (`package-lock.json`, `yarn.lock`), full `docker-compose.yml`, multi-thousand-line config files, sprawling JSON dumps
- **SSH command output** that streams — `docker compose up`, `docker compose logs -f`, `journalctl`, anything that tails. The subagent runs the command, watches the output, and returns the relevant snippet plus a one-line verdict
- **Browser / Playwright UI navigation** — page interactions, screenshot capture flows, element discovery. UI sessions are intrinsically verbose; the parent rarely needs the full transcript
- **Verbose 1Password reads** — vault listings, item dumps with all fields, share-link creation flows
- **Verbose `gh` output** — `gh pr view <huge PR>`, `gh run view --log` (full CI logs), `gh api` calls that return large response bodies
- **PR body drafting from many inputs** — when composing a PR description requires combining several files, sessions, or reference docs, hand the inputs to a subagent and ask it to return a finished draft
- **Large MCP server reads** that you know return long payloads (e.g., dumping every row of a table, listing every artifact in a registry)

## Patterns NOT to delegate

Do **not** delegate these — over-correcting makes simple tasks slow:

- **Small, targeted reads** — a known file under ~500 lines, a few specific fields from a config, a single function definition. Just read it.
- **Quick CLI calls with predictable short output** — `git status`, `git log --oneline -10`, `gh pr view --json state`, `wc -l`, `ls`. Run them directly.
- **Tool calls whose output the parent NEEDS to reason over directly** to make the next decision. If you have to compare values across the output, weigh tradeoffs the subagent cannot anticipate, or hold the output in working memory while you do something else, do it yourself. Distillation loses information; only delegate when you can articulate a tight prompt for what the subagent should return.
- **The action you are routing toward** — if the *task itself* is "read file X and report findings," delegating the read is redundant; you are already the reporter. This skill is about offloading verbose intermediate steps, not the deliverable.

## How to delegate well

Use your runtime's in-process subagent — in Claude Code this is the `Task` / `Agent` tool (`subagent_type: "general-purpose"` for general work, `subagent_type: "Explore"` for pure read/search); in Codex it is `spawn_agent`. The subagent prompt MUST do two things:

1. **State the goal narrowly** — what specific question the subagent is answering, or what specific output the parent needs back
2. **Bound the return shape** — explicitly say "do not return raw output, return distilled findings only" (or the equivalent for the task), and cap the return at a sentence count or bullet count if it helps

### Example: delegate a verbose file read

> Read `infrastructure/obs-droplet/README.md` and `infrastructure/obs-droplet/docker-compose.yml`. Report:
> - Which services run on the droplet (one bullet each)
> - Which ports they expose
> - Any gotchas the README calls out about Sentry/GlitchTip integration
>
> Do not return raw file contents. Distilled findings only, under 200 words.

### Example: delegate an SSH log stream

> SSH into `obs-droplet-prod` and run `docker compose up glitchtip` for ~60 seconds. Watch the output for: (a) successful "Listening on" lines, (b) errors, (c) restart loops. Kill the process after the boot sequence settles or after 60s, whichever comes first. Report:
> - Did GlitchTip boot cleanly? (yes/no)
> - Any errors observed (verbatim, but only the relevant lines)
> - One-line verdict
>
> Do not paste the full log stream.

### Example: delegate a Playwright navigation

> Open the staging admin dashboard at `https://admin.example.com/runs`, log in if prompted, find the most recent failed run, and capture the error message displayed in the UI. Report just the error text and the run ID. Do not narrate the navigation.

### Example: delegate a PR body draft

> Compose a PR body for the changes on the current branch. Inputs to combine: (1) `git diff main...HEAD`, (2) the linked issue at `https://github.com/example/app/issues/N`, (3) the relevant CLAUDE.md sections at `agents/agent-roots/<root>/CLAUDE.md`. Follow the format in `agents/references/GIT_WORKFLOW.md` (Summary + Verification with checked boxes). Return the finished markdown only.

## Operating notes

- Subagents inherit the working directory and tools but **not your conversation context**. Your prompt is the only thing they see — make it self-contained.
- Distillation is lossy by design. If you later realize you needed something the subagent did not surface, ask a follow-up subagent rather than re-doing the verbose call yourself.
- This skill is a **complement**, not a replacement, for spawning a separate Zimmer action session. Inline subagents handle work *within* the current task; Zimmer sub-sessions handle work that warrants its own session lifecycle (a different domain, a different goal, a result the user needs to see directly). The router CLAUDE.md (`agent-roots/zimmer-router/CLAUDE.md`) covers when investigation sub-sessions are the right tool — read it when you are unsure.
- If you are already deep into a thrashing session, do not retry the same heavy approach a fourth time. Either delegate via subagent (per the three-strike rule) or stop, summarize where you are, and surface the situation to the user so they can decide whether to fork a fresh session.

## Output

There is no formal output for this skill — it is consulted as guidance, not invoked as a workflow. The behavioral signal that you used it correctly is that subsequent tool calls of the kinds listed above happen inside in-process subagent calls and return short distilled summaries to the main thread.
