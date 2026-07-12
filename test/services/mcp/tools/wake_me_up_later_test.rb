# frozen_string_literal: true

require "test_helper"

class Mcp::Tools::WakeMeUpLaterTest < ActiveSupport::TestCase
  def tool
    Mcp::Tools::WakeMeUpLater.new(context: Mcp::Context.new(tool_groups: "self_session"))
  end

  def future_wake_at(offset = 1.hour)
    offset.from_now.utc.strftime("%Y-%m-%dT%H:%M:%S")
  end

  test "schedules a one-time trigger and sleeps a needs_input session" do
    session = sessions(:needs_input)
    wake_at = future_wake_at

    result = tool.call("session_id" => session.id, "wake_at" => wake_at, "prompt" => "Check on the build")

    trigger = Trigger.order(:id).last
    assert_equal "Wake session ##{session.id} at #{wake_at}", trigger.name
    assert_equal "Check on the build", trigger.prompt_template
    assert trigger.reuse_session
    assert_equal session.id, trigger.last_session_id

    condition = trigger.trigger_conditions.sole
    assert_equal "schedule", condition.condition_type
    assert_equal wake_at, condition.scheduled_at
    assert_equal "UTC", condition.schedule_timezone
    assert condition.one_time_schedule?

    # The sleep is a side effect of trigger creation, not a separate call.
    assert session.reload.waiting?

    assert_match "## Wake-Up Scheduled Successfully", result
    assert_match "- **Session ID:** #{session.id}", result
    assert_match "- **Wake At:** #{wake_at} (UTC)", result
    assert_match "- **Trigger ID:** #{trigger.id}", result
  end

  test "a running session is marked pending_sleep rather than transitioned mid-turn" do
    session = sessions(:running)

    tool.call("session_id" => session.id, "wake_at" => future_wake_at, "prompt" => "Resume")

    session.reload
    assert session.running?
    assert_equal true, session.metadata["pending_sleep"]
  end

  test "interprets wake_at in the given IANA timezone" do
    session = sessions(:needs_input)
    wake_at = 1.day.from_now.in_time_zone("America/New_York").strftime("%Y-%m-%dT%H:%M:%S")

    result = tool.call(
      "session_id" => session.id,
      "wake_at" => wake_at,
      "timezone" => "America/New_York",
      "prompt" => "Morning check"
    )

    condition = Trigger.order(:id).last.trigger_conditions.sole
    assert_equal wake_at, condition.scheduled_at
    assert_equal "America/New_York", condition.schedule_timezone
    assert_match "- **Wake At:** #{wake_at} (America/New_York)", result
  end

  test "rejects a past wake_at without creating a trigger or changing session state" do
    session = sessions(:needs_input)
    past = 1.hour.ago.utc.strftime("%Y-%m-%dT%H:%M:%S")

    error = assert_no_difference "Trigger.count" do
      assert_raises(Mcp::ToolError) do
        tool.call("session_id" => session.id, "wake_at" => past, "prompt" => "Too late")
      end
    end

    assert_match "in the past or within 30 seconds", error.message
    assert_match "No trigger was created and no session state was changed", error.message
    assert session.reload.needs_input?
  end

  test "rejects a wake_at inside the 30 second grace window" do
    error = assert_raises(Mcp::ToolError) do
      tool.call("session_id" => sessions(:needs_input).id, "wake_at" => future_wake_at(10.seconds), "prompt" => "Now-ish")
    end

    assert_match "must be more than 30 seconds in the future", error.message
  end

  test "rejects a wake_at carrying an explicit UTC offset" do
    error = assert_raises(Mcp::ToolError) do
      tool.call("session_id" => sessions(:needs_input).id, "wake_at" => "2030-04-15T14:30:00+05:00", "prompt" => "Nope")
    end

    assert_match "must not include a UTC offset", error.message
  end

  test "rejects a date-only wake_at" do
    error = assert_raises(Mcp::ToolError) do
      tool.call("session_id" => sessions(:needs_input).id, "wake_at" => "2030-04-15", "prompt" => "Nope")
    end

    assert_match "must be an ISO-8601 datetime", error.message
  end

  test "rejects a Z-suffixed wake_at paired with a non-UTC timezone" do
    error = assert_raises(Mcp::ToolError) do
      tool.call(
        "session_id" => sessions(:needs_input).id,
        "wake_at" => "2030-04-15T14:30:00Z",
        "timezone" => "America/New_York",
        "prompt" => "Ambiguous"
      )
    end

    assert_match 'Either drop the trailing "Z" or set timezone to "UTC"', error.message
  end

  test "rejects an unknown timezone" do
    error = assert_raises(Mcp::ToolError) do
      tool.call(
        "session_id" => sessions(:needs_input).id,
        "wake_at" => future_wake_at,
        "timezone" => "Mars/Olympus_Mons",
        "prompt" => "Nope"
      )
    end

    assert_match "not a recognized IANA timezone", error.message
  end

  test "refuses to schedule a wake-up for a session in a non-wakeable state" do
    error = assert_no_difference "Trigger.count" do
      assert_raises(Mcp::ToolError) do
        tool.call("session_id" => sessions(:archived).id, "wake_at" => future_wake_at, "prompt" => "Never")
      end
    end

    assert_match "cannot be scheduled for wake-up", error.message
  end

  test "requires wake_at and prompt" do
    assert_raises(Mcp::ToolError) { tool.call("session_id" => sessions(:needs_input).id, "prompt" => "x") }
    assert_raises(Mcp::ToolError) { tool.call("session_id" => sessions(:needs_input).id, "wake_at" => future_wake_at) }
  end

  test "description re-renders the current server time on every call" do
    travel_to Time.utc(2030, 4, 15, 9, 30, 0) do
      assert_match "**Current server time:** 2030-04-15T09:30:00Z (UTC)", Mcp::Tools::WakeMeUpLater.rendered_description
    end

    travel_to Time.utc(2030, 4, 15, 10, 45, 0) do
      assert_match "**Current server time:** 2030-04-15T10:45:00Z (UTC)", Mcp::Tools::WakeMeUpLater.to_h[:description]
    end
  end

  test "minute-precision wake_at is stored with seconds so the trigger can fire" do
    session = sessions(:needs_input)

    tool.call("session_id" => session.id, "wake_at" => "2030-04-15T09:30Z", "prompt" => "wake up")

    condition = Trigger.order(:created_at).last.trigger_conditions.sole
    assert_equal "2030-04-15T09:30:00Z", condition.configuration["scheduled_at"]
    assert_nothing_raised { Time.iso8601(condition.configuration["scheduled_at"]) }
  end
end
