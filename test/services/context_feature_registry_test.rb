# frozen_string_literal: true

require "test_helper"

class ContextFeatureRegistryTest < ActiveSupport::TestCase
  def block(**attrs)
    ContextFeatureRegistry::Block.new(**{ role: "user", type: "text", text: "", tool_name: nil }.merge(attrs))
  end

  test "every character of a block lands on exactly one feature" do
    # This is what makes the residual meaningful. If classification could drop
    # bytes, "unattributed" would silently mix "we cannot see it" with "we lost it".
    text = "Do the work.\n\nThe user has indicated the goal for this task is: ship it.\n" \
           "<session-hierarchy>\n- #1\n</session-hierarchy>"
    claimed = ContextFeatureRegistry.classify(block(text: text))

    assert_equal text.length, claimed.values.sum
    assert_operator claimed["goal"], :>, 0
    assert_operator claimed["session_hierarchy"], :>, 0
    assert_operator claimed["prompt"], :>, 0
  end

  test "a block nothing claims falls to the named fallback rather than vanishing" do
    claimed = ContextFeatureRegistry.classify(block(role: "assistant", type: "image", text: "xxxx"))

    assert_equal({ ContextFeatureRegistry::FALLBACK => 4 }, claimed)
  end

  test "an empty block claims nothing" do
    assert_empty ContextFeatureRegistry.classify(block(text: ""))
  end

  test "MCP traffic is distinguished from built-in tool traffic" do
    mcp = ContextFeatureRegistry.classify(block(type: "tool_result", text: "abc", tool_name: "mcp__zimmer__get_session"))
    builtin = ContextFeatureRegistry.classify(block(type: "tool_result", text: "abc", tool_name: "Bash"))

    assert_equal({ "mcp_result" => 3 }, mcp)
    assert_equal({ "tool_result" => 3 }, builtin)
  end

  test "the features Zimmer itself injects are identifiable as such" do
    # The page marks these because they are the ones this repository can decide to
    # stop injecting, shrink, or serve from a cheaper model.
    assert_includes ContextFeatureRegistry.zimmer_keys, "goal"
    assert_includes ContextFeatureRegistry.zimmer_keys, "mcp_result"
    assert_includes ContextFeatureRegistry.zimmer_keys, "skill_body"
    assert_not_includes ContextFeatureRegistry.zimmer_keys, "prompt"
  end

  test "the goal detector matches what AgentSessionJob actually appends" do
    # Pinned against the producing code rather than a paraphrase: if the prompt is
    # reworded, this fails here instead of the line quietly going to zero on the page.
    suffix = "\n\nThe user has indicated the goal for this task is: finish the PR.\n\n" \
             "Hand back control to the user AS SOON as the goal is satisfied."
    claimed = ContextFeatureRegistry.classify(block(text: "Task.#{suffix}"))

    assert_operator claimed["goal"], :>, suffix.length / 2
  end

  test "every registered feature has a label and a blurb the page can render" do
    ContextFeatureRegistry.all.each do |feature|
      assert feature.label.present?, "#{feature.key} needs a label"
      assert feature.blurb.present?, "#{feature.key} needs a blurb"
      assert_includes %i[zimmer harness work], feature.owner, "#{feature.key} needs a known owner"
    end
  end
end
