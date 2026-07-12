# frozen_string_literal: true

require "test_helper"

class Mcp::Tools::ActionSessionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tool = Mcp::Tools::ActionSession.new(context: Mcp::Context.new(tool_groups: "sessions"))
  end

  test "rejects an unknown action" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "self_destruct", "session_id" => sessions(:needs_input).id) }
    assert_match(/Unknown action/, error.message)
  end

  test "requires session_id for session-scoped actions" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "pause") }
    assert_match(/"session_id" parameter is required/, error.message)
  end

  test "follow_up sends the prompt immediately to an idle session" do
    session = sessions(:needs_input)

    result = nil
    assert_enqueued_with(job: AgentSessionJob, args: [ session.id, "Keep going" ]) do
      result = @tool.call("action" => "follow_up", "session_id" => session.id, "prompt" => "Keep going")
    end

    assert_includes result, "## Follow-up Sent"
    assert_includes result, "- **Message:** Follow-up prompt sent"
    assert_equal "running", session.reload.status
    assert_equal "Keep going", session.prompt
  end

  test "follow_up queues the prompt for a running session" do
    session = sessions(:running)

    result = assert_difference "session.enqueued_messages.count", 1 do
      @tool.call("action" => "follow_up", "session_id" => session.id, "prompt" => "Queued work")
    end

    assert_includes result, "## Follow-up Sent"
    assert_includes result, "Message queued (session is running)"
    assert_equal "running", session.reload.status
  end

  test "follow_up requires a prompt" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "follow_up", "session_id" => sessions(:needs_input).id) }
    assert_match(/"prompt" parameter is required/, error.message)
  end

  test "pause pauses a running session and marks it user-paused" do
    session = sessions(:running)

    result = @tool.call("action" => "pause", "session_id" => session.id)

    assert_includes result, "## Session Paused"
    session.reload
    assert_equal "needs_input", session.status
    assert_equal "user", session.metadata["paused_by"]
  end

  test "pause refuses a session that is not running" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "pause", "session_id" => sessions(:needs_input).id) }
    assert_match(/not running/, error.message)
  end

  test "archive archives a session" do
    session = sessions(:needs_input)

    result = @tool.call("action" => "archive", "session_id" => session.id)

    assert_includes result, "## Session Archived"
    assert_includes result, "- **New Status:** archived"
    assert_equal "archived", session.reload.status
    assert session.archived_at.present?
  end

  test "archive refuses an already archived session" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "archive", "session_id" => sessions(:archived).id) }
    assert_match(/cannot be trashed/, error.message)
  end

  test "change_mcp_servers replaces the session's servers" do
    session = sessions(:needs_input)

    result = @tool.call("action" => "change_mcp_servers", "session_id" => session.id, "mcp_servers" => [ "context7" ])

    assert_includes result, "## MCP Servers Updated"
    assert_includes result, "- **MCP Servers:** context7"
    assert_equal [ "context7" ], session.reload.mcp_servers
  end

  test "change_mcp_servers rejects servers outside the catalog" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "change_mcp_servers", "session_id" => sessions(:needs_input).id, "mcp_servers" => [ "not-a-server" ])
    end
    assert_match(/Invalid MCP servers/, error.message)
  end

  test "change_mcp_servers is refused on a restricted connection" do
    restricted = Mcp::Tools::ActionSession.new(
      context: Mcp::Context.new(tool_groups: "sessions", allowed_agent_roots: "zimmer")
    )

    error = assert_raises(Mcp::ToolError) do
      restricted.call("action" => "change_mcp_servers", "session_id" => sessions(:needs_input).id, "mcp_servers" => [ "context7" ])
    end
    assert_match(/not allowed when this connection is restricted/, error.message)
    assert_equal [], sessions(:needs_input).reload.mcp_servers
  end

  test "change_model updates the model and rejects models outside the runtime catalog" do
    session = sessions(:needs_input)

    result = @tool.call("action" => "change_model", "session_id" => session.id, "model" => "sonnet")
    assert_includes result, "## Model Updated"
    assert_includes result, "- **Model:** sonnet"
    assert_equal "sonnet", session.reload.config["model"]

    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "change_model", "session_id" => session.id, "model" => "gpt-imaginary")
    end
    assert_match(/is not valid for runtime/, error.message)
  end

  test "set_heartbeat toggles the heartbeat and sets the interval" do
    session = sessions(:needs_input)

    result = @tool.call("action" => "set_heartbeat", "session_id" => session.id, "enabled" => true, "interval_seconds" => 120)

    assert_includes result, "## Heartbeat Updated"
    assert_includes result, "- **Heartbeat Enabled:** Yes"
    assert_includes result, "- **Interval:** 120 seconds"
    session.reload
    assert session.heartbeat_enabled
    assert_equal 120, session.heartbeat_interval_seconds
  end

  test "set_heartbeat requires at least one setting and a valid interval" do
    session = sessions(:needs_input)

    missing = assert_raises(Mcp::ToolError) { @tool.call("action" => "set_heartbeat", "session_id" => session.id) }
    assert_match(/at least one of/, missing.message)

    out_of_range = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "set_heartbeat", "session_id" => session.id, "interval_seconds" => 5)
    end
    assert_match(/must be between/, out_of_range.message)
  end

  test "update_notes and update_title write to the session" do
    session = sessions(:needs_input)

    notes_result = @tool.call("action" => "update_notes", "session_id" => session.id, "session_notes" => "Blocked on review")
    assert_includes notes_result, "## Session Notes Updated"
    assert_equal "Blocked on review", session.reload.session_notes
    assert session.session_notes_updated_at.present?

    title_result = @tool.call("action" => "update_title", "session_id" => session.id, "title" => "New title")
    assert_includes title_result, "## Session Title Updated"
    assert_equal "New title", session.reload.title
  end

  test "update_notes and update_title require their parameter" do
    session = sessions(:needs_input)

    notes_error = assert_raises(Mcp::ToolError) { @tool.call("action" => "update_notes", "session_id" => session.id) }
    assert_match(/"session_notes" parameter is required/, notes_error.message)

    title_error = assert_raises(Mcp::ToolError) { @tool.call("action" => "update_title", "session_id" => session.id) }
    assert_match(/"title" parameter is required/, title_error.message)
  end

  test "toggle_favorite flips the favorited flag" do
    session = sessions(:needs_input)

    result = @tool.call("action" => "toggle_favorite", "session_id" => session.id)

    assert_includes result, "- **Favorited:** Yes"
    assert session.reload.favorited
  end

  test "bulk_archive archives the given sessions and reports failures" do
    archivable = sessions(:needs_input)
    already_archived = sessions(:archived)

    result = @tool.call("action" => "bulk_archive", "session_ids" => [ archivable.id, already_archived.id ])

    assert_includes result, "## Bulk Archive Complete"
    assert_includes result, "- **Archived:** 1"
    assert_equal "archived", archivable.reload.status
  end

  test "bulk_archive requires session_ids" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "bulk_archive", "session_ids" => []) }
    assert_match(/"session_ids" parameter is required/, error.message)
  end

  test "fork requires a message_index" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "fork", "session_id" => sessions(:with_transcript).id) }
    assert_match(/"message_index" parameter is required/, error.message)
  end

  test "refresh reports when the session has no clone path" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "refresh", "session_id" => sessions(:needs_input).id) }
    assert_match(/No clone path/, error.message)
  end

  test "refresh_all reports its counters and needs no session_id" do
    result = @tool.call("action" => "refresh_all")

    assert_includes result, "## All Sessions Refreshed"
    assert_includes result, "- **Restarted:**"
    assert_includes result, "- **Errors:** 0"
  end
end
