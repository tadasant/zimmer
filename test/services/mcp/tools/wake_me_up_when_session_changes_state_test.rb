# frozen_string_literal: true

require "test_helper"

class Mcp::Tools::WakeMeUpWhenSessionChangesStateTest < ActiveSupport::TestCase
  def tool(allowed_agent_roots: nil, session_id: nil)
    Mcp::Tools::WakeMeUpWhenSessionChangesState.new(
      context: Mcp::Context.new(
        tool_groups: "self_session",
        allowed_agent_roots: allowed_agent_roots,
        session_id: session_id
      )
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
    assert_match "- **Events:** session_archived", result
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
    assert_match "event_names: session_exploded is not a valid event", error.message
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

  # === event_names: one trigger over a set of events ===

  test "event_names creates ONE trigger carrying one condition per event" do
    requester = sessions(:needs_input)
    watched = sessions(:running)

    result = assert_difference "Trigger.count", 1 do
      tool.call(
        "session_id" => requester.id,
        "watched_session_id" => watched.id,
        "event_names" => %w[session_archived session_needs_input session_failed],
        "prompt" => "The session you were watching reached a resting state"
      )
    end

    trigger = Trigger.order(:id).last
    assert_equal 3, trigger.trigger_conditions.count
    assert_equal %w[session_archived session_failed session_needs_input],
      trigger.trigger_conditions.map(&:ao_event_name).sort
    trigger.trigger_conditions.each do |condition|
      assert_equal "ao_event", condition.condition_type
      assert_equal watched.id, condition.watched_session_id
    end

    # Still recognised as the one-time wake shape, which is what makes the
    # auto-sleep, the auto-delete and the sibling cleanup all apply.
    assert trigger.one_time_reuse_trigger?
    assert requester.reload.waiting?
    assert_match "- **Events:** session_archived, session_needs_input, session_failed", result
  end

  test "the whole triple-wake costs one trigger where it used to cost three" do
    requester = sessions(:needs_input)
    watched = sessions(:running)

    assert_difference "Trigger.count", 1 do
      tool.call(
        "session_id" => requester.id,
        "watched_session_id" => watched.id,
        "event_names" => Mcp::Tools::WakeMeUpWhenSessionChangesState::AO_EVENT_NAMES,
        "prompt" => "Watched session reached a resting state"
      )
    end
  end

  test "event_names deduplicates and rejects an empty list" do
    requester = sessions(:needs_input)
    watched = sessions(:running)

    tool.call(
      "session_id" => requester.id,
      "watched_session_id" => watched.id,
      "event_names" => %w[session_failed session_failed],
      "prompt" => "Dupes"
    )
    assert_equal 1, Trigger.order(:id).last.trigger_conditions.count

    error = assert_no_difference "Trigger.count" do
      assert_raises(Mcp::ToolError) do
        tool.call(
          "session_id" => sessions(:running).id,
          "watched_session_id" => watched.id,
          "event_names" => [],
          "prompt" => "Nothing to watch"
        )
      end
    end
    assert_match "Missing required parameter: event_names", error.message
  end

  test "passing both event_name and event_names is refused rather than silently merged" do
    error = assert_no_difference "Trigger.count" do
      assert_raises(Mcp::ToolError) do
        tool.call(
          "session_id" => sessions(:needs_input).id,
          "watched_session_id" => sessions(:running).id,
          "event_name" => "session_failed",
          "event_names" => %w[session_archived],
          "prompt" => "Both"
        )
      end
    end
    assert_match "not both", error.message
  end

  test "an unfireable event in the set rejects the whole call" do
    watched = sessions(:running)
    watched.update!(status: :archived)

    error = assert_no_difference "Trigger.count" do
      assert_raises(Mcp::ToolError) do
        tool.call(
          "session_id" => sessions(:needs_input).id,
          "watched_session_id" => watched.id,
          "event_names" => %w[session_needs_input session_archived],
          "prompt" => "Already archived"
        )
      end
    end
    assert_match "is archived and will not transition further", error.message
    assert sessions(:needs_input).reload.needs_input?
  end

  # === session_id defaults to the connection's own session ===

  test "session_id may be omitted when the connection names the calling session" do
    requester = sessions(:needs_input)
    watched = sessions(:running)

    tool(session_id: requester.id).call(
      "watched_session_id" => watched.id,
      "event_names" => %w[session_archived],
      "prompt" => "Watched archived"
    )

    trigger = Trigger.order(:id).last
    assert_equal requester.id, trigger.last_session_id
    assert requester.reload.waiting?
  end

  test "an explicit session_id still wins over the connection's own session" do
    connection_session = sessions(:needs_input)
    explicit = sessions(:running)

    tool(session_id: connection_session.id).call(
      "session_id" => explicit.id,
      "watched_session_id" => sessions(:active_session).id,
      "event_names" => %w[session_failed],
      "prompt" => "Explicit wins"
    )

    assert_equal explicit.id, Trigger.order(:id).last.last_session_id
    assert connection_session.reload.needs_input?
  end

  test "omitting session_id on a connection that names nobody says exactly what to pass" do
    error = assert_no_difference "Trigger.count" do
      assert_raises(Mcp::ToolError) do
        tool.call(
          "watched_session_id" => sessions(:running).id,
          "event_names" => %w[session_archived],
          "prompt" => "Who am I"
        )
      end
    end

    assert_match "Missing required parameter: session_id", error.message
    assert_match "does not name a calling session", error.message
  end
  test "a defaulted requester is named in the receipt so a mis-aimed wake is recoverable" do
    requester = sessions(:needs_input)

    result = tool(session_id: requester.id).call(
      "watched_session_id" => sessions(:running).id,
      "event_names" => %w[session_archived],
      "prompt" => "Watched archived"
    )

    assert_match "No `session_id` was given, so this acted on the calling session (##{requester.id})", result
  end

  test "an explicit session_id produces no defaulting notice" do
    result = tool(session_id: sessions(:needs_input).id).call(
      "session_id" => sessions(:running).id,
      "watched_session_id" => sessions(:active_session).id,
      "event_names" => %w[session_failed],
      "prompt" => "Explicit"
    )

    assert_no_match(/No `session_id` was given/, result)
  end

  test "an explicit but blank session_id is an error, not a silent fallback to the caller" do
    error = assert_no_difference "Trigger.count" do
      assert_raises(Mcp::ToolError) do
        tool(session_id: sessions(:needs_input).id).call(
          "session_id" => "",
          "watched_session_id" => sessions(:running).id,
          "event_names" => %w[session_archived],
          "prompt" => "Blank"
        )
      end
    end

    assert_match "Missing required parameter: session_id", error.message
    assert sessions(:needs_input).reload.needs_input?, "the caller must not have been slept by mistake"
  end

  test "a connection naming a session that no longer exists says so rather than defaulting elsewhere" do
    error = assert_no_difference "Trigger.count" do
      assert_raises(Mcp::ToolError) do
        tool(session_id: 999_999_999).call(
          "watched_session_id" => sessions(:running).id,
          "event_names" => %w[session_archived],
          "prompt" => "Ghost caller"
        )
      end
    end

    assert_match "names session 999999999 as the caller", error.message
    assert_match "no such session exists", error.message
  end
end
