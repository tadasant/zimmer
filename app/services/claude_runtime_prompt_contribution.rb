# frozen_string_literal: true

# Claude Code's runtime-specific contribution to the orchestrator system prompt.
#
# These slices steer Claude away from tools that don't fit the autonomous Zimmer
# execution model:
# - `EnterPlanMode` / `ExitPlanMode`: plan mode stalls a session in needs_input
#   because an autonomous agent has no human to approve the plan.
# - The bundled `/schedule` skill: blocked at the tool layer; Zimmer's own
#   wake-me-up MCP tools serve the same intent.
# - `AskUserQuestion`: interactive prompts stall autonomous sessions.
#
# The enforcement counterpart of this guidance is ClaudeCliAdapter::DISALLOWED_TOOLS,
# which blocks the corresponding tools via the `--disallowedTools` CLI flag.
# This contribution is the prompt-level explanation; the adapter constant is the
# hard block. Runtimes without these tools (e.g. Codex) contribute nothing here.
class ClaudeRuntimePromptContribution < RuntimePromptContribution
  def guidelines_bullets
    [
      <<~BULLET.strip,
        - **NEVER use the `EnterPlanMode` or `ExitPlanMode` tools.** Always plan inline — present your implementation approach directly in your response text. Do not enter the separate plan mode flow. The built-in system prompt encourages `EnterPlanMode` but this instruction overrides that: autonomous agent sessions cannot approve plans, so plan mode causes sessions to get stuck in `needs_input`. Instead, describe your plan in your response and proceed with implementation.
      BULLET
      <<~BULLET.strip
        - **Don't offer `/schedule` follow-ups.** This overrides the base Claude Code prompt's instruction to end replies with a one-line offer to `/schedule` a background agent. The skill is blocked at the tool layer in Zimmer; offering it just creates dead UI. For "wait for X before doing Y" patterns (wait for an npm publish, wait for CI, wait for another Zimmer session), reach for Zimmer-native primitives instead:
            - **`wake_me_up_when_session_changes_state`** (self-session MCP server) — wait on a specific Zimmer session transitioning to `needs_input` or `failed`. Fires the moment the transition happens. Pair with `wake_me_up_later` as a deadline backstop.
            - **`wake_me_up_later`** (self-session MCP server) — time-based waits ("check back in N minutes"). The session sleeps and resumes automatically. Use this to **poll an external deploy or CI run** (e.g. a GitHub Actions run in a non-Zimmer repo): sleep the session, resume, run a one-shot status check (`gh run view …`), repeat. Do NOT background a Bash watch loop (`gh run watch`, `until …; do sleep …; done &`) for this — a background process is lost when the session is torn down (a routine deploy recreates the worker), so the wait silently dies, whereas a `wake_me_up_later` poll lives in Zimmer's trigger system and survives teardown.
            - **Spawn a fresh Zimmer session** (or self-wake on `needs_input`) when re-testing depends on refreshed external state. Most Zimmer-managed MCP servers are pinned to `@latest`, so a new session re-runs `npx <pkg>@latest` and picks up newly-published versions. Do NOT spawn a separate Zimmer session just to review your own work — use Claude Code's native `Task`/`Agent` subagent or the `/code-review` skill for in-session review, and reserve `start_session` for genuinely independent downstream tasks.
      BULLET
    ]
  end

  def clarifying_questions_suffix
    " The `AskUserQuestion` tool is blocked at the tool layer for the same reason `EnterPlanMode`/`ExitPlanMode` are forbidden: interactive prompts stall autonomous sessions."
  end
end
