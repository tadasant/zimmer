# frozen_string_literal: true

require "test_helper"

class Mcp::Tools::WakeMeUpWhenSessionChangesStateTest < ActiveSupport::TestCase
  def tool(allowed_agent_roots: nil)
    Mcp::Tools::WakeMeUpWhenSessionChangesState.new(
      context: Mcp::Context.new(tool_groups: "self_session", allowed_agent_roots: allowed_agent_roots)
    )
  end

  test "schedules a session-scoped ao_event trigger and sleeps the requester" do
    requester = sessions(:needs_input)
    watched = sessions(:running)

    result = tool.call(
      "session_id" => requester.id,
      "watched_session_id" => watched.id,
      "event_name" => "session_archived",
      "prompt" => "Session you were watching archived — check its output"
    )

    trigger = Trigger.order(:id).last
    assert_equal "Wake session ##{requester.id} on session_archived of session ##{watched.id}", trigger.name
    assert trigger.reuse_session
    assert_equal requester.id, trigger.last_session_id
    assert trigger.one_time_reuse_trigger?

    condition = trigger.trigger_conditions.sole
    assert_equal "ao_event", condition.condition_type
    assert_equal "session_archived", condition.ao_event_name
    assert_equal watched.id, condition.watched_session_id

    # The sleep is a side effect of trigger creation, not a separate call.
    assert requester.reload.waiting?

    assert_match "## Wake-Up Scheduled Successfully", result
    assert_match "- **Requester Session ID:** #{requester.id}", result
    assert_match "- **Watched Session ID:** #{watched.id}", result
    assert_match "- **Event:** session_archived", result
    assert_match "- **Trigger ID:** #{trigger.id}", result
  end

  test "a running requester is marked pending_sleep rather than transitioned mid-turn" do
    requester = sessions(:running)

    tool.call(
      "session_id" => requester.id,
      "watched_session_id" => sessions(:active_session).id,
      "event_name" => "session_failed",
      "prompt" => "Watched session failed"
    )

    requester.reload
    assert requester.running?
    assert_equal true, requester.metadata["pending_sleep"]
  end

  test "refuses to let a session watch itself" do
    requester = sessions(:needs_input)

    error = assert_no_difference "Trigger.count" do
      assert_raises(Mcp::ToolError) do
        tool.call(
          "session_id" => requester.id,
          "watched_session_id" => requester.id,
          "event_name" => "session_needs_input",
          "prompt" => "Self-loop"
        )
      end
    end

    assert_match "A session cannot watch itself for state changes", error.message
    assert requester.reload.needs_input?
  end

  test "refuses a watched session that is already failed for session_failed" do
    error = assert_raises(Mcp::ToolError) do
      tool.call(
        "session_id" => sessions(:needs_input).id,
        "watched_session_id" => sessions(:failed).id,
        "event_name" => "session_failed",
        "prompt" => "Never fires"
      )
    end

    assert_match 'is already in "failed" state', error.message
  end

  test "refuses an archived watched session for any event" do
    error = assert_raises(Mcp::ToolError) do
      tool.call(
        "session_id" => sessions(:needs_input).id,
        "watched_session_id" => sessions(:archived).id,
        "event_name" => "session_needs_input",
        "prompt" => "Never fires"
      )
    end

    assert_match "will not transition further", error.message
  end

  test "refuses a non-wakeable requester" do
    error = assert_raises(Mcp::ToolError) do
      tool.call(
        "session_id" => sessions(:failed).id,
        "watched_session_id" => sessions(:running).id,
        "event_name" => "session_archived",
        "prompt" => "Never"
      )
    end

    assert_match "cannot be scheduled for wake-up", error.message
  end

  test "rejects an unknown watched session" do
    error = assert_raises(Mcp::ToolError) do
      tool.call(
        "session_id" => sessions(:needs_input).id,
        "watched_session_id" => 999_999_999,
        "event_name" => "session_archived",
        "prompt" => "Ghost"
      )
    end

    assert_match "Could not look up watched session 999999999", error.message
  end

  test "rejects a non-positive watched_session_id and an unknown event_name" do
    error = assert_raises(Mcp::ToolError) do
      tool.call(
        "session_id" => sessions(:needs_input).id,
        "watched_session_id" => 0,
        "event_name" => "session_archived",
        "prompt" => "Bad id"
      )
    end
    assert_match "watched_session_id: must be a positive integer", error.message

    error = assert_raises(Mcp::ToolError) do
      tool.call(
        "session_id" => sessions(:needs_input).id,
        "watched_session_id" => sessions(:running).id,
        "event_name" => "session_exploded",
        "prompt" => "Bad event"
      )
    end
    assert_match "event_name: must be one of", error.message
  end

  test "a restricted connection refuses to watch a session outside its allowed roots" do
    error = assert_no_difference "Trigger.count" do
      assert_raises(Mcp::ToolError) do
        tool(allowed_agent_roots: "zimmer").call(
          "session_id" => sessions(:needs_input).id,
          "watched_session_id" => sessions(:running).id,
          "event_name" => "session_archived",
          "prompt" => "Out of scope"
        )
      end
    end

    assert_match "is not in the allowed list [zimmer]", error.message
    assert sessions(:needs_input).reload.needs_input?
  end

  test "a restricted connection may watch a session inside its allowed roots" do
    root = AgentRootsConfig.all.first
    watched = sessions(:running)
    watched.update!(metadata: (watched.metadata || {}).merge("agent_root_key" => root.name))

    result = tool(allowed_agent_roots: root.name).call(
      "session_id" => sessions(:needs_input).id,
      "watched_session_id" => watched.id,
      "event_name" => "session_archived",
      "prompt" => "In scope"
    )

    assert_match "## Wake-Up Scheduled Successfully", result
  end
end
