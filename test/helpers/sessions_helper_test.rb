require "test_helper"

class SessionsHelperTest < ActionView::TestCase
  # Tests for goal_display_name
  test "goal_display_name returns name when matching by description" do
    conditions = [
      { id: "e2e-verified-green-pr", name: "E2E Verified Green PR", description: "Full description text" }
    ]
    assert_equal "E2E Verified Green PR", goal_display_name("Full description text", conditions)
  end

  test "goal_display_name returns name when matching by ID" do
    conditions = [
      { id: "e2e-verified-green-pr", name: "E2E Verified Green PR", description: "Full description text" }
    ]
    assert_equal "E2E Verified Green PR", goal_display_name("e2e-verified-green-pr", conditions)
  end

  test "goal_display_name returns Custom for unrecognized value" do
    conditions = [
      { id: "e2e-verified-green-pr", name: "E2E Verified Green PR", description: "Full description text" }
    ]
    assert_equal "Custom", goal_display_name("something completely different", conditions)
  end

  test "goal_display_name returns nil for blank value" do
    conditions = [
      { id: "e2e-verified-green-pr", name: "E2E Verified Green PR", description: "Full description text" }
    ]
    assert_nil goal_display_name("", conditions)
    assert_nil goal_display_name(nil, conditions)
  end

  test "goal_display_name handles nil conditions list" do
    assert_equal "Custom", goal_display_name("some value", nil)
  end

  # Tests for ci_status_color_class
  test "ci_status_color_class returns green for pass" do
    assert_equal "text-green-500", ci_status_color_class("pass")
  end

  test "ci_status_color_class returns red for fail" do
    assert_equal "text-red-500", ci_status_color_class("fail")
  end

  test "ci_status_color_class returns yellow for pending" do
    assert_equal "text-yellow-500", ci_status_color_class("pending")
  end

  test "ci_status_color_class returns gray for cancel" do
    assert_equal "text-gray-400", ci_status_color_class("cancel")
  end

  test "ci_status_color_class returns gray for skipping" do
    assert_equal "text-gray-400", ci_status_color_class("skipping")
  end

  test "ci_status_color_class returns light gray for nil" do
    assert_equal "text-gray-300", ci_status_color_class(nil)
  end

  test "ci_status_color_class returns light gray for unknown status" do
    assert_equal "text-gray-300", ci_status_color_class("unknown")
  end

  # Tests for ci_status_bg_class
  test "ci_status_bg_class returns green background for pass" do
    assert_equal "bg-green-500", ci_status_bg_class("pass")
  end

  test "ci_status_bg_class returns red background for fail" do
    assert_equal "bg-red-500", ci_status_bg_class("fail")
  end

  test "ci_status_bg_class returns yellow background for pending" do
    assert_equal "bg-yellow-500", ci_status_bg_class("pending")
  end

  test "ci_status_bg_class returns gray background for cancel" do
    assert_equal "bg-gray-400", ci_status_bg_class("cancel")
  end

  test "ci_status_bg_class returns gray background for skipping" do
    assert_equal "bg-gray-400", ci_status_bg_class("skipping")
  end

  test "ci_status_bg_class returns light gray background for nil" do
    assert_equal "bg-gray-300", ci_status_bg_class(nil)
  end

  # ---------------------------------------------------------------------------
  # OpenTranscripts display helpers (ot_*)
  # ---------------------------------------------------------------------------
  Types = OpenTranscript::Types

  def event(type, **fields)
    OpenTranscript.event(
      type: type, id: "e1", parent_id: nil, ts: "2025-11-20T10:00:00Z",
      sort_time: Time.parse("2025-11-20T10:00:00Z"), **fields
    )
  end

  # === ot_event_label ===

  test "ot_event_label labels each event type" do
    assert_equal "User", ot_event_label(event(Types::USER_MESSAGE))
    assert_equal "Assistant", ot_event_label(event(Types::ASSISTANT_MESSAGE))
    assert_equal "Thinking", ot_event_label(event(Types::THINKING))
    assert_equal "Tool: Bash", ot_event_label(event(Types::TOOL_CALL, tool_name: "Bash"))
    assert_equal "Tool: unknown", ot_event_label(event(Types::TOOL_CALL, tool_name: nil))
    assert_equal "Tool Result", ot_event_label(event(Types::TOOL_RESULT, is_error: false))
    assert_equal "Tool Result (Error)", ot_event_label(event(Types::TOOL_RESULT, is_error: true))
    assert_equal "Subagent", ot_event_label(event(Types::SUBAGENT_SPAWN))
    assert_equal "Compaction", ot_event_label(event(Types::COMPACTION))
    assert_equal "Error", ot_event_label(event(Types::ERROR))
    assert_equal "Queue Event", ot_event_label(event(Types::SYSTEM_EVENT, subtype: "queue-operation"))
    assert_equal "Git Status", ot_event_label(event(Types::SYSTEM_EVENT, subtype: "git_status"))
  end

  # === ot_icon_kind / badge / color ===

  test "ot_icon_kind maps event type to a glyph" do
    assert_equal :user, ot_icon_kind(event(Types::USER_MESSAGE))
    assert_equal :assistant, ot_icon_kind(event(Types::ASSISTANT_MESSAGE))
    assert_equal :thinking, ot_icon_kind(event(Types::THINKING))
    assert_equal :tool, ot_icon_kind(event(Types::TOOL_CALL))
    assert_equal :tool, ot_icon_kind(event(Types::SUBAGENT_SPAWN))
    assert_equal :error, ot_icon_kind(event(Types::ERROR))
    assert_equal :system, ot_icon_kind(event(Types::SYSTEM_EVENT))
  end

  test "ot_badge_class and ot_icon_color follow icon kind" do
    assert_equal "bg-indigo-100", ot_badge_class(event(Types::USER_MESSAGE))
    assert_equal "bg-green-100", ot_badge_class(event(Types::ASSISTANT_MESSAGE))
    assert_equal "bg-purple-100", ot_badge_class(event(Types::TOOL_CALL))
    assert_equal "text-indigo-600", ot_icon_color(event(Types::USER_MESSAGE))
    assert_equal "text-red-600", ot_icon_color(event(Types::ERROR))
  end

  # === ot_tool_row? ===

  test "ot_tool_row? is true for tool-ish events and false for messages" do
    assert ot_tool_row?(event(Types::THINKING))
    assert ot_tool_row?(event(Types::TOOL_CALL))
    assert ot_tool_row?(event(Types::TOOL_RESULT))
    assert ot_tool_row?(event(Types::SUBAGENT_SPAWN))
    refute ot_tool_row?(event(Types::USER_MESSAGE))
    refute ot_tool_row?(event(Types::ASSISTANT_MESSAGE))
  end

  # === ot_image_count ===

  test "ot_image_count counts image parts in message content" do
    item = event(Types::USER_MESSAGE, content: [
      OpenTranscript.text_part("hi"),
      OpenTranscript.image_part(data: "AAAA", mime_type: "image/png"),
      OpenTranscript.image_part(data: "BBBB", mime_type: "image/png")
    ])
    assert_equal 2, ot_image_count(item)
  end

  test "ot_image_count is zero when content has no images or is not an array" do
    assert_equal 0, ot_image_count(event(Types::USER_MESSAGE, content: [ OpenTranscript.text_part("hi") ]))
    assert_equal 0, ot_image_count(event(Types::THINKING, text: "x"))
  end

  # === ot_content_markdown ===

  test "ot_content_markdown renders message text parts" do
    item = event(Types::ASSISTANT_MESSAGE, content: [ OpenTranscript.text_part("Hello"), OpenTranscript.text_part("World") ])
    assert_equal "Hello\n\nWorld", ot_content_markdown(item)
  end

  test "ot_content_markdown renders an image placeholder" do
    item = event(Types::USER_MESSAGE, content: [ OpenTranscript.image_part(data: "AAAA", mime_type: "image/png") ])
    assert_equal "[Image attached: PNG]", ot_content_markdown(item)
  end

  test "ot_content_markdown renders Thinking text" do
    assert_equal "let me reason", ot_content_markdown(event(Types::THINKING, text: "let me reason"))
  end

  test "ot_content_markdown renders a tool call with parameters" do
    item = event(Types::TOOL_CALL, tool_name: "Bash", arguments: { "command" => "ls -la", "description" => "List files" })
    result = ot_content_markdown(item)

    assert_includes result, "Using tool: Bash"
    assert_includes result, "Parameters:"
    assert_includes result, "command: ls -la"
    assert_includes result, "description: List files"
  end

  test "ot_content_markdown truncates long tool-call string parameters" do
    item = event(Types::TOOL_CALL, tool_name: "Write", arguments: { "content" => "a" * 300 })
    result = ot_content_markdown(item)

    assert_includes result, "Using tool: Write"
    assert_includes result, "..."
    assert result.length < 300
  end

  test "ot_content_markdown renders tool result output parts" do
    item = event(Types::TOOL_RESULT, output: [ OpenTranscript.text_part("done") ], is_error: false)
    assert_equal "done", ot_content_markdown(item)
  end

  test "ot_content_markdown renders a subagent spawn" do
    item = event(Types::SUBAGENT_SPAWN, subagent_type: "Explore", description: "look around", prompt: "go")
    result = ot_content_markdown(item)

    assert_includes result, "**Subagent:** Explore"
    assert_includes result, "look around"
    assert_includes result, "go"
  end

  test "ot_content_markdown renders a compaction with token counts" do
    item = event(Types::COMPACTION, summary: "compacted", trigger: "auto", tokens_before: 1000, tokens_after: 200)
    result = ot_content_markdown(item)

    assert_includes result, "**Context compaction** (auto)"
    assert_includes result, "1000 → 200"
    assert_includes result, "compacted"
  end

  test "ot_content_markdown renders an error message" do
    assert_equal "API Error: boom", ot_content_markdown(event(Types::ERROR, message: "API Error: boom"))
  end

  test "ot_content_markdown renders a system event payload content" do
    item = event(Types::SYSTEM_EVENT, subtype: "system", payload: { "content" => "Tip: use /help" })
    assert_equal "Tip: use /help", ot_content_markdown(item)
  end
end
