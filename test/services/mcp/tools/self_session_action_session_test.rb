# frozen_string_literal: true

require "test_helper"

class Mcp::Tools::SelfSessionActionSessionTest < ActiveSupport::TestCase
  setup do
    @tool = Mcp::Tools::SelfSessionActionSession.new(context: Mcp::Context.new(tool_groups: "self_session"))
  end

  test "keeps the action_session name but exposes only the self-management actions" do
    definition = Mcp::Tools::SelfSessionActionSession.definition

    assert_equal "action_session", definition["name"]
    assert_equal %w[update_notes update_title set_heartbeat archive], definition["inputSchema"]["properties"]["action"]["enum"]
    assert_equal %w[session_id action], definition["inputSchema"]["required"]
    assert_match(/self-management/, definition["description"])
  end

  test "refuses an action outside the self-management subset" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "follow_up", "session_id" => sessions(:needs_input).id, "prompt" => "hi")
    end

    assert_match(/Unknown action "follow_up"/, error.message)
    assert_equal "needs_input", sessions(:needs_input).reload.status
  end

  test "archives the session" do
    session = sessions(:needs_input)

    result = @tool.call("action" => "archive", "session_id" => session.id)

    assert_includes result, "## Session Archived"
    assert_equal "archived", session.reload.status
  end

  test "updates notes, title, and the heartbeat" do
    session = sessions(:needs_input)

    assert_includes @tool.call("action" => "update_notes", "session_id" => session.id, "session_notes" => "Progress"), "## Session Notes Updated"
    assert_equal "Progress", session.reload.session_notes

    assert_includes @tool.call("action" => "update_title", "session_id" => session.id, "title" => "Self title"), "## Session Title Updated"
    assert_equal "Self title", session.reload.title

    result = @tool.call("action" => "set_heartbeat", "session_id" => session.id, "enabled" => false)
    assert_includes result, "- **Heartbeat Enabled:** No"
    assert_not session.reload.heartbeat_enabled
  end

  test "still requires session_id" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "archive") }
    assert_match(/"session_id" parameter is required/, error.message)
  end
end
