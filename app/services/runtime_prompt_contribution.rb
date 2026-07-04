# frozen_string_literal: true

# Per-runtime contribution to the Agent Orchestrator system prompt.
#
# Most of the orchestrator system prompt is runtime-agnostic — the operating
# principles, session URL, MCP server list, and autonomous problem-solving
# guidance apply to every runtime AO can drive. A small slice is specific to a
# given runtime's tool surface, though: Claude Code ships an `EnterPlanMode`
# tool, a `/schedule` skill, and an `AskUserQuestion` tool that AO needs to
# steer agents away from. Other runtimes (e.g. Codex) have no analog for those
# tools, so repeating Claude's "never use EnterPlanMode" guidance to them would
# be noise at best and confusing at worst.
#
# This class is the seam: `OrchestratorSystemPromptBuilder` composes the shared
# sections and asks the runtime's contribution for the runtime-specific slices.
# The base implementation contributes nothing, so a runtime without an
# implementation gets the shared AO principles and no runtime-specific tool
# guidance. `ClaudeRuntimePromptContribution` overrides the slices with Claude's
# tool opinions; `CodexRuntimePromptContribution` does the same for Codex.
#
# Beyond the tool-guidance slices, the contribution also owns two delivery facts
# that differ by runtime: how the prompt reaches the agent (Claude appends it via
# `--append-system-prompt`; Codex has no such flag, so AO writes it to the
# runtime's project-instructions file at prepare time) and which file holds the
# repo's project instructions (`CLAUDE.md` vs `AGENTS.md`). `AirPrepareService`
# reads `delivered_via_file?`/`system_prompt_filename` to decide whether to write
# the prompt to disk, and `OrchestratorSystemPromptBuilder` reads
# `project_instructions_filename` / `dynamic_resources_section_override` to wrap
# shared sections in the right file references per runtime.
class RuntimePromptContribution
  # Resolve the contribution for a runtime identifier.
  #
  # @param runtime [String, Symbol, nil] Runtime identifier (e.g. "claude").
  #   nil/blank defaults to Claude, since that is AO's only runtime today and
  #   keeps the prompt byte-identical when no runtime is specified.
  # @return [RuntimePromptContribution]
  def self.for(runtime)
    case runtime&.to_s
    when nil, "", "claude", "claude_code"
      ClaudeRuntimePromptContribution.new
    when "codex", "codex_cli"
      CodexRuntimePromptContribution.new
    else
      new
    end
  end

  # Runtime-specific bullets inserted into the "Agent Orchestrator Guidelines"
  # list, after the shared intro bullets and before the remote-filesystem
  # bullet. Each array element is a complete bullet block (a leading "- ..."
  # line, optionally followed by indented sub-bullets).
  #
  # @return [Array<String>]
  def guidelines_bullets
    []
  end

  # Text appended to the shared "avoid asking the user clarifying questions"
  # bullet. Claude uses this to name the now-blocked `AskUserQuestion` tool;
  # runtimes without such a tool contribute nothing (the bullet stays generic).
  #
  # @return [String]
  def clarifying_questions_suffix
    ""
  end

  # The repo's project-instructions filename for this runtime, interpolated into
  # shared prompt sections that reference it ("follow any CLAUDE.md instructions",
  # "Domain-specific CLAUDE.md files ..."). Claude reads `CLAUDE.md`; Codex reads
  # `AGENTS.md`. Defaults to `CLAUDE.md` — the monorepo's canonical instruction
  # file — so the prompt is byte-identical for the default runtime.
  #
  # @return [String]
  def project_instructions_filename
    "CLAUDE.md"
  end

  # Optional replacement for the shared "## Dynamic Skills and MCP Servers"
  # section, which describes where AO injects skills and MCP config. Those paths
  # are runtime-specific (`.claude/skills/` + `.mcp.json` for Claude;
  # `.agents/skills/` + `.codex/config.toml` for Codex). Returning nil keeps the
  # builder's default (Claude-flavored) section, so the default runtime is
  # unchanged; Codex overrides it with its own paths.
  #
  # @return [String, nil] full section text including its `##` header, or nil
  def dynamic_resources_section_override
    nil
  end

  # Whether AO delivers the orchestrator system prompt by writing it to a file in
  # the working directory rather than passing it as a CLI flag. Claude appends it
  # via `--append-system-prompt` (false); Codex has no such flag, so AO writes the
  # prompt to `system_prompt_filename` during prepare (true).
  #
  # @return [Boolean]
  def delivered_via_file?
    false
  end

  # The working-directory file the orchestrator system prompt is written to when
  # #delivered_via_file? is true (e.g. `AGENTS.md` for Codex). nil when the prompt
  # is delivered via a CLI flag instead.
  #
  # @return [String, nil]
  def system_prompt_filename
    nil
  end
end
