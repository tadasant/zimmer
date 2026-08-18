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

  test "system_recovery? rejects anything else" do
    assert_not AutomatedPrompts.system_recovery?(nil)
    assert_not AutomatedPrompts.system_recovery?(:symbol)
    assert_not AutomatedPrompts.system_recovery?("go fix the build")
    assert_not AutomatedPrompts.system_recovery?(AutomatedPrompts::HEARTBEAT)
    assert_not AutomatedPrompts.system_recovery?(AutomatedPrompts.pr_merged_message("https://example.com/pull/1"))
  end
end
