# frozen_string_literal: true

# The Pi coding agent's runtime-specific contribution to the orchestrator system
# prompt.
#
# Pi's capability surface differs from both Claude Code's and Codex's, so its
# slice of the Zimmer system prompt differs too:
#
# - No `EnterPlanMode`/`ExitPlanMode`, no `/schedule` skill, no
#   `AskUserQuestion` — the Claude contribution's guidance about steering away
#   from those is irrelevant noise here, so Pi omits it.
# - No subagent primitive at all. Claude has Task/Agent and Codex has
#   `spawn_agent`; Pi has neither, so the "delegate to your in-process subagent"
#   bullet the other two carry would point at a tool that does not exist. What
#   Pi has instead is skills, so the guidance points self-review at the
#   `/code-review` skill and keeps the load-bearing half of the rule — do not
#   spin up a separate Zimmer session to review your own work.
# - Pi's MCP tools do not appear as individual tools. The pi-mcp-adapter
#   extension deliberately exposes ONE proxy tool that the agent searches and
#   calls through, to keep a dozen servers from consuming the context window.
#   An agent that expects `mcp__server__tool` to be directly callable will
#   conclude its MCP servers are missing, so the prompt says how to reach them.
#
# Delivery: Pi HAS an `--append-system-prompt` flag (unlike Codex), so
# #delivered_via_file? is false and PiRuntimeAdapter passes the prompt on the
# command line — staged through a file for size, but as a flag, not as a
# convention-read project file. Pi reads `AGENTS.md` from the working directory
# on its own, which is precisely why the orchestrator prompt must NOT also be
# written there: it would land in the model's context twice.
class PiRuntimePromptContribution < RuntimePromptContribution
  def guidelines_bullets
    [
      <<~BULLET.strip,
        - **Reach MCP servers through the `mcp` proxy tool, not as individual tools.** Zimmer configures your MCP servers in `.mcp.json`, and Pi exposes them through a single `mcp` tool rather than registering every server's tools individually — that is deliberate, so a dozen servers do not consume your context window before you start. Discover what is available with `mcp({ search: "<what you need>" })` and then call it with `mcp({ tool: "<name>", args: { ... } })`. If a tool you expected is not in the search results, say so rather than assuming the server is missing.
      BULLET
      <<~BULLET.strip,
        - **Use Zimmer-native primitives for "wait for X before doing Y" patterns** (wait for an npm publish, wait for CI, wait for another Zimmer session) instead of blocking on long sleeps:
            - **`wake_me_up_when_session_changes_state`** (self-session MCP server) — wait on a specific Zimmer session transitioning to `needs_input` or `failed`. Fires the moment the transition happens. Pair with `wake_me_up_later` as a deadline backstop.
            - **`wake_me_up_later`** (self-session MCP server) — time-based waits ("check back in N minutes"). The session sleeps and resumes automatically. Use this to **poll an external deploy or CI run** (e.g. a GitHub Actions run in a non-Zimmer repo): sleep the session, resume, run a one-shot status check (`gh run view …`), repeat. Do NOT background a Bash watch loop (`gh run watch`, `until …; do sleep …; done &`) for this — a background process is lost when the session is torn down (a routine deploy recreates the worker), so the wait silently dies, whereas a `wake_me_up_later` poll lives in Zimmer's trigger system and survives teardown.
            - **Spawn a fresh Zimmer session** (or self-wake on `needs_input`) only when re-testing depends on refreshed external state — not as a way to delegate review of your own work (see the next bullet). Most Zimmer-managed MCP servers are pinned to `@latest`, so a new session re-runs the package at `@latest` and picks up newly-published versions.
      BULLET
      <<~BULLET.strip
        - **Do not spin up a separate Zimmer session to review your own work.** Pi has no in-process subagent primitive, so for a fresh-eyes review of your own PR use the `/code-review` skill in this session. A separate Zimmer session is a full clone + container + MCP cold-start (minutes) and clutters the user's homepage. Reserve `start_session` for genuinely independent downstream tasks.
      BULLET
    ]
  end

  # Pi reads both `AGENTS.md` and `CLAUDE.md` from the working directory. AGENTS.md
  # is the name to report: it is the cross-vendor convention, and naming CLAUDE.md
  # to a non-Claude runtime invites an agent to write Claude-specific instructions
  # into a repo shared with other runtimes.
  def project_instructions_filename
    "AGENTS.md"
  end

  def dynamic_resources_section_override
    <<~SECTION.strip
      ## Dynamic Skills and MCP Servers

      Zimmer dynamically injects resources into your working directory at session start:

      - **`.pi/skills/`** — Skills (SKILL.md files) are translated from a centralized catalog into Pi's native skill layout based on the session's configured skill set. Pi treats any directory containing a `SKILL.md` as a skill. These appear as regular files but are managed by Zimmer, not checked into the repo — do not commit, modify, or delete them. If a skill already exists in the repo at the same path, the repo version takes priority.
      - **`.mcp.json`** — MCP server configurations are generated from the session's configured MCP servers. Pi reads this file through the `pi-mcp-adapter` extension and exposes the servers through the single `mcp` proxy tool described above. This file is also managed by Zimmer.

      Treat both as read-only runtime resources. If you need to understand what skills or MCP servers are available, read the files — but do not attempt to version-control or modify them.
    SECTION
  end

  # False: Pi accepts `--append-system-prompt`, so the orchestrator prompt is
  # delivered as a flag rather than by writing a project-instructions file the
  # runtime reads by convention. See the class docstring on why writing AGENTS.md
  # here would double the prompt.
  def delivered_via_file?
    false
  end
end
