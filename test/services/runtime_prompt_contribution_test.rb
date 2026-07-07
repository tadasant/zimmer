require "test_helper"

class RuntimePromptContributionTest < ActiveSupport::TestCase
  test "for(nil) resolves to the Claude contribution" do
    assert_instance_of ClaudeRuntimePromptContribution, RuntimePromptContribution.for(nil)
  end

  test "for blank string resolves to the Claude contribution" do
    assert_instance_of ClaudeRuntimePromptContribution, RuntimePromptContribution.for("")
  end

  test "for claude/claude_code resolves to the Claude contribution" do
    assert_instance_of ClaudeRuntimePromptContribution, RuntimePromptContribution.for("claude")
    assert_instance_of ClaudeRuntimePromptContribution, RuntimePromptContribution.for(:claude)
    assert_instance_of ClaudeRuntimePromptContribution, RuntimePromptContribution.for("claude_code")
  end

  test "for codex/codex_cli resolves to the Codex contribution" do
    assert_instance_of CodexRuntimePromptContribution, RuntimePromptContribution.for("codex")
    assert_instance_of CodexRuntimePromptContribution, RuntimePromptContribution.for(:codex)
    assert_instance_of CodexRuntimePromptContribution, RuntimePromptContribution.for("codex_cli")
  end

  test "for an unknown runtime resolves to the generic base contribution" do
    contribution = RuntimePromptContribution.for("aider")

    assert_instance_of RuntimePromptContribution, contribution
    refute_instance_of ClaudeRuntimePromptContribution, contribution
    refute_instance_of CodexRuntimePromptContribution, contribution
  end

  test "base contribution contributes no runtime-specific content" do
    contribution = RuntimePromptContribution.new

    assert_equal [], contribution.guidelines_bullets
    assert_equal "", contribution.clarifying_questions_suffix
    assert_equal "CLAUDE.md", contribution.project_instructions_filename
    assert_nil contribution.dynamic_resources_section_override
    refute contribution.delivered_via_file?
    assert_nil contribution.system_prompt_filename
  end

  test "Claude contribution supplies EnterPlanMode and /schedule bullets" do
    bullets = ClaudeRuntimePromptContribution.new.guidelines_bullets

    assert_equal 2, bullets.size
    assert_includes bullets[0], "NEVER use the `EnterPlanMode` or `ExitPlanMode` tools"
    assert_includes bullets[1], "Don't offer `/schedule` follow-ups"
    # The /schedule bullet carries its Zimmer-native wake-tool sub-bullets.
    assert_includes bullets[1], "wake_me_up_when_session_changes_state"
    assert_includes bullets[1], "wake_me_up_later"
    assert_includes bullets[1], "Spawn a fresh Zimmer session"
  end

  test "Claude contribution's /schedule sub-bullets keep their 4-space indentation" do
    schedule_bullet = ClaudeRuntimePromptContribution.new.guidelines_bullets[1]

    assert_includes schedule_bullet, "\n    - **`wake_me_up_when_session_changes_state`**",
      "sub-bullets must keep 4-space indentation when spliced into the guidelines list"
  end

  test "Claude contribution names the blocked AskUserQuestion tool" do
    suffix = ClaudeRuntimePromptContribution.new.clarifying_questions_suffix

    assert suffix.start_with?(" "),
      "suffix must lead with a space so it appends cleanly to the autonomy bullet"
    assert_includes suffix, "`AskUserQuestion` tool is blocked at the tool layer"
    assert_includes suffix, "interactive prompts stall autonomous sessions"
  end

  test "Claude contribution uses CLAUDE.md and delivers the prompt via CLI flag" do
    contribution = ClaudeRuntimePromptContribution.new

    assert_equal "CLAUDE.md", contribution.project_instructions_filename
    assert_nil contribution.dynamic_resources_section_override
    refute contribution.delivered_via_file?,
      "Claude appends the prompt via --append-system-prompt, not a file"
    assert_nil contribution.system_prompt_filename
  end

  test "Codex contribution supplies sandbox + Zimmer-native wait guidance" do
    bullets = CodexRuntimePromptContribution.new.guidelines_bullets

    assert_equal 3, bullets.size
    assert_includes bullets[0], "Work within the Codex sandbox"
    assert_includes bullets[1], "wake_me_up_when_session_changes_state"
    assert_includes bullets[1], "wake_me_up_later"
  end

  test "Codex contribution points self-review at native spawn_agent, not start_session" do
    bullets = CodexRuntimePromptContribution.new.guidelines_bullets

    assert_includes bullets[2], "spawn_agent",
      "Codex should be told to use its native in-process subagent for in-session work"
    assert_includes bullets[2], "Do NOT call `start_session`",
      "Codex must be barred from spinning up a review-only Zimmer session"
    # The wait bullet's fresh-session sub-bullet stays scoped to refreshed external state.
    assert_includes bullets[1], "not as a way to delegate review of your own work"
  end

  test "Codex contribution omits Claude-only tool guidance" do
    contribution = CodexRuntimePromptContribution.new
    blob = (contribution.guidelines_bullets + [ contribution.clarifying_questions_suffix, contribution.dynamic_resources_section_override.to_s ]).join("\n")

    refute_includes blob, "EnterPlanMode"
    refute_includes blob, "/schedule"
    refute_includes blob, "AskUserQuestion"
  end

  test "Codex contribution uses AGENTS.md and delivers the prompt via file" do
    contribution = CodexRuntimePromptContribution.new

    assert_equal "AGENTS.md", contribution.project_instructions_filename
    assert contribution.delivered_via_file?,
      "Codex has no --append-system-prompt flag; the prompt is written to a file"
    assert_equal "AGENTS.md", contribution.system_prompt_filename
    assert_equal "", contribution.clarifying_questions_suffix
  end

  test "Codex contribution's dynamic-resources override describes Codex-native paths" do
    section = CodexRuntimePromptContribution.new.dynamic_resources_section_override

    assert_includes section, "## Dynamic Skills and MCP Servers"
    assert_includes section, ".agents/skills/"
    assert_includes section, ".codex/config.toml"
    refute_includes section, ".claude/skills/"
  end
end
