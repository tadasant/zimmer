# frozen_string_literal: true

# OpenAI Codex's runtime-specific contribution to the orchestrator system prompt.
#
# Codex's tool surface differs from Claude's, so its slice of the Zimmer system
# prompt differs too:
# - No `EnterPlanMode`/`ExitPlanMode`, no `/schedule` skill, no `AskUserQuestion`
#   tool — the Claude contribution's guidance about steering away from those is
#   irrelevant noise here, so Codex simply omits it.
# - Codex runs inside its own sandbox with an approval policy. Zimmer spawns it in an
#   automated mode so the agent can work without interactive approval prompts, so
#   the guidance reminds the agent not to disable or bypass that sandbox.
# - Codex has a native in-process subagent primitive (`spawn_agent`), so the
#   guidance points self-review and parallel exploration at that primitive and
#   explicitly bars spinning up a separate Zimmer session via `start_session` just to
#   review its own work — a review-only Zimmer session is a full clone + container +
#   MCP cold-start and clutters the user's homepage. `start_session` is reserved
#   for genuinely independent downstream work.
# - Codex reads project instructions from `AGENTS.md` (its analog to `CLAUDE.md`)
#   and Zimmer injects skills/MCP config in Codex's native layout (`.agents/skills/`,
#   `.codex/config.toml`).
#
# Delivery also differs: Codex has no `--append-system-prompt` flag, so the
# orchestrator prompt is written to `AGENTS.md` at prepare time (see
# #delivered_via_file? / #system_prompt_filename, consumed by AirPrepareService)
# rather than passed on the command line.
class CodexRuntimePromptContribution < RuntimePromptContribution
  def guidelines_bullets
    [
      <<~BULLET.strip,
        - **Work within the Codex sandbox.** Zimmer runs you in an automated sandbox so you can edit files and run commands without interactive approval prompts. Do not try to disable, widen, or bypass the sandbox (e.g. requesting full-access mode or bypassing approvals) unless the user explicitly asks — the autonomous Zimmer execution model expects you to operate inside the provided sandbox.
      BULLET
      <<~BULLET.strip,
        - **Use Zimmer-native primitives for "wait for X before doing Y" patterns** (wait for an npm publish, wait for CI, wait for another Zimmer session) instead of blocking on long sleeps:
            - **`wake_me_up_when_session_changes_state`** (self-session MCP server) — wait on a specific Zimmer session transitioning to `needs_input` or `failed`. Fires the moment the transition happens. Pair with `wake_me_up_later` as a deadline backstop.
            - **`wake_me_up_later`** (self-session MCP server) — time-based waits ("check back in N minutes"). The session sleeps and resumes automatically. Use this to **poll an external deploy or CI run** (e.g. a GitHub Actions run in a non-Zimmer repo): sleep the session, resume, run a one-shot status check (`gh run view …`), repeat. Do NOT background a Bash watch loop (`gh run watch`, `until …; do sleep …; done &`) for this — a background process is lost when the session is torn down (a routine deploy recreates the worker), so the wait silently dies, whereas a `wake_me_up_later` poll lives in Zimmer's trigger system and survives teardown.
            - **Spawn a fresh Zimmer session** (or self-wake on `needs_input`) only when re-testing depends on refreshed external state — not as a way to delegate review of your own work (see the next bullet). Most Zimmer-managed MCP servers are pinned to `@latest`, so a new session re-runs the package at `@latest` and picks up newly-published versions.
      BULLET
      <<~BULLET.strip
        - **Delegate in-session work to your native `spawn_agent` subagent, not a new Zimmer session.** For work that belongs inside this session — a fresh-eyes self-review of your own PR, parallel exploration, etc. — use Codex's native `spawn_agent` subagent (or the `/code-review` skill) so the review runs in-process. Do NOT call `start_session` to spin up a separate Zimmer session just to review your own work: a separate Zimmer session is a full clone + container + MCP cold-start (minutes) and clutters the user's homepage. Reserve `start_session` for genuinely independent downstream tasks.
      BULLET
    ]
  end

  def project_instructions_filename
    "AGENTS.md"
  end

  def dynamic_resources_section_override
    <<~SECTION.strip
      ## Dynamic Skills and MCP Servers

      Zimmer dynamically injects resources into your working directory at session start:

      - **`.agents/skills/`** — Skills (SKILL.md files) are translated from a centralized catalog into Codex's native skill layout based on the session's configured skill set. Invoke them with `/skills` or `$skill-name`. These appear as regular files but are managed by Zimmer, not checked into the repo — do not commit, modify, or delete them. If a skill already exists in the repo at the same path, the repo version takes priority.
      - **`.codex/config.toml`** — MCP server configurations are generated from the session's configured MCP servers and written to Codex's config file. This file is also managed by Zimmer.

      Treat both as read-only runtime resources. If you need to understand what skills or MCP servers are available, read the files — but do not attempt to version-control or modify them.
    SECTION
  end

  def delivered_via_file?
    true
  end

  def system_prompt_filename
    "AGENTS.md"
  end
end
