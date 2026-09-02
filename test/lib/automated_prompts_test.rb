require "test_helper"
require "automated_prompts"

class AutomatedPromptsTest < ActiveSupport::TestCase
  test "system_recovery with no reason is byte-identical to the bare constant" do
    assert_equal AutomatedPrompts::SYSTEM_RECOVERY, AutomatedPrompts.system_recovery
    assert_equal AutomatedPrompts::SYSTEM_RECOVERY, AutomatedPrompts.system_recovery(reason: nil)
    assert_equal AutomatedPrompts::SYSTEM_RECOVERY, AutomatedPrompts.system_recovery(reason: "")
    assert_equal AutomatedPrompts::SYSTEM_RECOVERY, AutomatedPrompts.system_recovery(reason: "   ")
  end

  test "system_recovery appends the reason after the standing instructions" do
    prompt = AutomatedPrompts.system_recovery(reason: "an orphan sweep resumed this session")

    assert prompt.start_with?(AutomatedPrompts::SYSTEM_RECOVERY),
      "the reasoned variant must not alter the prompt an agent already knows"
    assert_includes prompt, "an orphan sweep resumed this session"
    assert_includes prompt, "No human sent it."
  end

  test "system_recovery? recognises both the bare and the reasoned prompt" do
    assert AutomatedPrompts.system_recovery?(AutomatedPrompts::SYSTEM_RECOVERY)
    assert AutomatedPrompts.system_recovery?(AutomatedPrompts.system_recovery(reason: "a deploy"))
  end

  # #815: the generic nudge is accurate and useless here — "a system event" invites the
  # agent to re-run the exact command that just exhausted the session's memory bound.
  test "memory_limit_recovery names the bound and what to do differently" do
    prompt = AutomatedPrompts.memory_limit_recovery(limit: "4 GB", peak: "4 GB")

    assert_includes prompt, "memory limit of 4 GB"
    assert_includes prompt, "peak usage: 4 GB"
    assert_includes prompt, "NOT USER INPUT"
    assert_match(/nothing outside this session was affected/, prompt,
      "an agent told only that it was killed will reasonably assume the box is broken")
    assert_match(/same limit again/, prompt,
      "the actionable part is 'do it differently', not 'you were killed'")
  end

  # It is not a SYSTEM_RECOVERY variant, and must not be mistaken for one: the paths that
  # treat a recovery nudge specially (preserving scheduled wake-ups, say) are reasoning
  # about a different kind of interruption.
  test "system_recovery? does not claim the memory-limit prompt" do
    assert_not AutomatedPrompts.system_recovery?(
      AutomatedPrompts.memory_limit_recovery(limit: "4 GB", peak: "4 GB")
    )
  end

  test "system_recovery? rejects anything else" do
    assert_not AutomatedPrompts.system_recovery?(nil)
    assert_not AutomatedPrompts.system_recovery?(:symbol)
    assert_not AutomatedPrompts.system_recovery?("go fix the build")
    assert_not AutomatedPrompts.system_recovery?(AutomatedPrompts::HEARTBEAT)
    assert_not AutomatedPrompts.system_recovery?(AutomatedPrompts.pr_merged_message("https://example.com/pull/1"))
  end
end
