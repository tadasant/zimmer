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

  # The experiment must not be able to look free on the cost page: when the
  # blocks stop being injected the bytes reappear as a tool call, and they land
  # on their own line rather than disappearing into "MCP responses".
  test "provenance fetched on demand is attributed to itself, not to MCP responses" do
    fetched = ContextFeatureRegistry.classify(
      block(type: "tool_result", text: "abc", tool_name: "mcp__zimmer-self-session__get_session_provenance")
    )
    called = ContextFeatureRegistry.classify(
      block(role: "assistant", type: "tool_use", text: "ab", tool_name: "mcp__zimmer-self-session__get_session_provenance")
    )

    assert_equal({ "provenance_tool" => 3 }, fetched)
    assert_equal({ "provenance_tool" => 2 }, called)
    assert_includes ContextFeatureRegistry.zimmer_keys, "provenance_tool"
  end

  # Zimmer no longer injects either block, but ingestion re-scans the ~30 days of
  # transcripts still on disk. Keeping the detectors is what makes the change
  # read as these two lines trending to zero rather than as history falling into
  # the residual, so both shapes they were ever written in still have to match.
  test "the retired provenance detectors still match what historical turns carry" do
    pointer = "<session-hierarchy>\n<info>This session sits in a lineage graph of 2 sessions, rooted at origin session #7.</info>\n</session-hierarchy>\n" \
              "<human-messages>\n<info>Call the `get_session_provenance` MCP tool. Authored in this session: 0.</info>\n</human-messages>"
    claimed = ContextFeatureRegistry.classify(block(text: pointer))

    assert_equal pointer.length, claimed.values.sum
    assert_operator claimed["session_hierarchy"], :>, 0
    assert_operator claimed["human_messages"], :>, 0

    full = "<session-hierarchy>\n<info>The lineage graph this session belongs to.</info>\n- #7 router\n</session-hierarchy>\n" \
           "<human-messages>\n<info>Absence is meaningful.</info>\n<message origin=\"here\">ship it</message>\n</human-messages>"
    claimed = ContextFeatureRegistry.classify(block(text: full))

    assert_equal full.length, claimed.values.sum
    assert_operator claimed["session_hierarchy"], :>, 0
    assert_operator claimed["human_messages"], :>, 0
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

  # With the provenance blocks gone, <unavailable-mcp-servers> and
  # <attached-files> are what can follow the goal suffix. A lookahead missing
  # either would let the goal region swallow that block and bill it as goal text.
  test "the goal detector stops at every block that can follow it" do
    goal = "\n\nThe user has indicated the goal for this task is: finish the PR."

    {
      "unavailable_mcp_servers" => "\n\n<unavailable-mcp-servers>\n<info>pulse-fetch did not connect.</info>\n</unavailable-mcp-servers>",
      "attached_files" => "\n\n<attached-files>\nThe user has attached the following file(s) to this message:\n- /tmp/a.png\n</attached-files>"
    }.each do |key, trailer|
      text = "Task.#{goal}#{trailer}"
      claimed = ContextFeatureRegistry.classify(block(text: text))

      assert_equal text.length, claimed.values.sum, "every byte should still land somewhere alongside #{key}"
      assert_operator claimed["goal"].to_i, :>, 0, "the goal itself should still be claimed alongside #{key}"
      # The goal stops at the block boundary, and the trailing block lands on its
      # own line rather than being billed as goal text or as the user's task.
      assert_operator claimed["goal"].to_i, :<=, goal.length, "the goal region swallowed the #{key} block"
      assert_operator claimed[key].to_i, :>, trailer.length / 2, "the #{key} block was not claimed by its own detector"
    end
  end

  # Both blocks are Zimmer's own bytes. Without a detector they fall through to
  # `prompt`, whose owner is :work — which would bill a block this repository
  # chose to inject to the user's task instead.
  test "the blocks that follow the goal are owned by Zimmer, not by the work" do
    assert_includes ContextFeatureRegistry.zimmer_keys, "unavailable_mcp_servers"
    assert_includes ContextFeatureRegistry.zimmer_keys, "attached_files"
  end

  test "every registered feature has a label and a blurb the page can render" do
    ContextFeatureRegistry.all.each do |feature|
      assert feature.label.present?, "#{feature.key} needs a label"
      assert feature.blurb.present?, "#{feature.key} needs a blurb"
      assert_includes %i[zimmer harness work], feature.owner, "#{feature.key} needs a known owner"
    end
  end
end
