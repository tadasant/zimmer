# frozen_string_literal: true

require "test_helper"

# The shared scheduler behind both wake surfaces: the wake_me_up_later MCP tool
# and the web UI's "Pause Until" control.
class Sessions::ScheduleWakeUpTest < ActiveSupport::TestCase
  def future_wake_at(offset = 1.hour)
    offset.from_now.utc.strftime("%Y-%m-%dT%H:%M:%S")
  end

  test "creates a one-time wake trigger bound to the session" do
    session = sessions(:needs_input)
    wake_at = future_wake_at

    trigger = Sessions::ScheduleWakeUp.call(session: session, wake_at: wake_at, prompt: "Check the build")

    assert_equal "Wake session ##{session.id} at #{wake_at}", trigger.name
    assert_equal "Check the build", trigger.prompt_template
    assert trigger.reuse_session
    assert_equal session.id, trigger.last_session_id

    condition = trigger.trigger_conditions.sole
    assert_equal "schedule", condition.condition_type
    assert_equal wake_at, condition.scheduled_at
    assert_equal "UTC", condition.schedule_timezone
    assert condition.one_time_schedule?
  end

  test "sleeping the session is a side effect of trigger creation, not a separate call" do
    session = sessions(:needs_input)

    Sessions::ScheduleWakeUp.call(session: session, wake_at: future_wake_at, prompt: "Resume")

    assert session.reload.waiting?
  end

  test "a running session is marked pending_sleep rather than transitioned mid-turn" do
    session = sessions(:running)

    Sessions::ScheduleWakeUp.call(session: session, wake_at: future_wake_at, prompt: "Resume")

    session.reload
    assert session.running?
    assert_equal true, session.metadata["pending_sleep"]
  end

  test "interprets wake_at in the given IANA timezone" do
    wake_at = 1.day.from_now.in_time_zone("America/New_York").strftime("%Y-%m-%dT%H:%M:%S")

    trigger = Sessions::ScheduleWakeUp.call(
      session: sessions(:needs_input), wake_at: wake_at, timezone: "America/New_York", prompt: "Morning"
    )

    condition = trigger.trigger_conditions.sole
    assert_equal wake_at, condition.scheduled_at
    assert_equal "America/New_York", condition.schedule_timezone
  end

  test "the same wall-clock string means different instants in different zones" do
    wake_at = 2.days.from_now.utc.strftime("%Y-%m-%dT12:00:00")

    utc = Sessions::ScheduleWakeUp.call(session: sessions(:needs_input), wake_at: wake_at, timezone: "UTC", prompt: "a")
    tokyo = Sessions::ScheduleWakeUp.call(session: sessions(:waiting), wake_at: wake_at, timezone: "Asia/Tokyo", prompt: "b")

    # Not a formatting detail: reading a browser's naive local time as UTC would
    # silently offset every pause by the operator's UTC offset.
    assert_equal "UTC", utc.trigger_conditions.sole.schedule_timezone
    assert_equal "Asia/Tokyo", tokyo.trigger_conditions.sole.schedule_timezone
    assert_not_equal(
      ActiveSupport::TimeZone["UTC"].parse(wake_at),
      ActiveSupport::TimeZone["Asia/Tokyo"].parse(wake_at)
    )
  end

  test "rejects a past wake_at without creating a trigger or changing session state" do
    session = sessions(:needs_input)

    error = assert_no_difference "Trigger.count" do
      assert_raises(Sessions::ScheduleWakeUp::Error) do
        Sessions::ScheduleWakeUp.call(session: session, wake_at: future_wake_at(-1.hour), prompt: "Too late")
      end
    end

    assert_equal :wake_at_too_soon, error.code
    assert_match "in the past or within 30 seconds", error.message
    assert session.reload.needs_input?
  end

  test "rejects a wake_at inside the 30 second grace window" do
    error = assert_raises(Sessions::ScheduleWakeUp::Error) do
      Sessions::ScheduleWakeUp.call(session: sessions(:needs_input), wake_at: future_wake_at(10.seconds), prompt: "Now-ish")
    end

    assert_equal :wake_at_too_soon, error.code
  end

  test "rejects a wake_at carrying an explicit UTC offset" do
    error = assert_raises(Sessions::ScheduleWakeUp::Error) do
      Sessions::ScheduleWakeUp.call(session: sessions(:needs_input), wake_at: "2030-04-15T14:30:00+05:00", prompt: "Nope")
    end

    assert_equal :unparseable_wake_at, error.code
    assert_match "must not include a UTC offset", error.message
  end

  test "rejects a date-only wake_at" do
    error = assert_raises(Sessions::ScheduleWakeUp::Error) do
      Sessions::ScheduleWakeUp.call(session: sessions(:needs_input), wake_at: "2030-04-15", prompt: "Nope")
    end

    assert_match "must be an ISO-8601 datetime", error.message
  end

  test "rejects an unknown timezone" do
    error = assert_raises(Sessions::ScheduleWakeUp::Error) do
      Sessions::ScheduleWakeUp.call(
        session: sessions(:needs_input), wake_at: future_wake_at, timezone: "Mars/Olympus_Mons", prompt: "Nope"
      )
    end

    assert_match "not a recognized IANA timezone", error.message
  end

  test "refuses a session in a state the auto-sleep would silently no-op" do
    error = assert_no_difference "Trigger.count" do
      assert_raises(Sessions::ScheduleWakeUp::Error) do
        Sessions::ScheduleWakeUp.call(session: sessions(:archived), wake_at: future_wake_at, prompt: "Never")
      end
    end

    assert_equal :not_wakeable, error.code
    assert_match "cannot be scheduled for wake-up", error.message
  end

  test "requires a prompt to resume with" do
    error = assert_no_difference "Trigger.count" do
      assert_raises(Sessions::ScheduleWakeUp::Error) do
        Sessions::ScheduleWakeUp.call(session: sessions(:needs_input), wake_at: future_wake_at, prompt: "  ")
      end
    end

    assert_equal :missing_prompt, error.code
  end

  test "minute-precision wake_at is stored with seconds so the trigger can fire" do
    trigger = Sessions::ScheduleWakeUp.call(
      session: sessions(:needs_input), wake_at: "2030-04-15T09:30Z", prompt: "wake up"
    )

    condition = trigger.trigger_conditions.sole
    assert_equal "2030-04-15T09:30:00Z", condition.configuration["scheduled_at"]
    assert_nothing_raised { Time.iso8601(condition.configuration["scheduled_at"]) }
  end

  test "an already-waiting session takes the trigger and stays waiting" do
    session = sessions(:waiting)

    Sessions::ScheduleWakeUp.call(session: session, wake_at: future_wake_at, prompt: "Resume")

    assert session.reload.waiting?
  end
  test "replace_existing cancels this session's unfired one-time wake first" do
    session = sessions(:needs_input)
    first = Sessions::ScheduleWakeUp.call(session: session, wake_at: future_wake_at(1.hour), prompt: "early")

    second = assert_no_difference "Trigger.count" do
      Sessions::ScheduleWakeUp.call(
        session: session, wake_at: future_wake_at(3.hours), prompt: "later", replace_existing: true
      )
    end

    # Not merely "a trigger exists": the one that would have fired at the replaced
    # time has to be gone, or the session wakes an hour early.
    assert_not Trigger.exists?(first.id)
    assert Trigger.exists?(second.id)
  end

  test "without replace_existing both wakes stay armed" do
    session = sessions(:needs_input)
    first = Sessions::ScheduleWakeUp.call(session: session, wake_at: future_wake_at(1.hour), prompt: "early")
    Sessions::ScheduleWakeUp.call(session: session, wake_at: future_wake_at(3.hours), prompt: "later")

    assert Trigger.exists?(first.id), "the agent-facing path must stay additive — the triple-wake pattern depends on it"
  end

  test "replace_existing leaves another session's wake and this session's state-change watchers alone" do
    session = sessions(:needs_input)
    other_wake = Sessions::ScheduleWakeUp.call(session: sessions(:waiting), wake_at: future_wake_at(1.hour), prompt: "other")

    watcher = Trigger.create!(
      name: "Watch session #{sessions(:running).id}",
      agent_root_name: session.agent_runtime,
      prompt_template: "it moved",
      reuse_session: true,
      last_session_id: session.id,
      trigger_conditions_attributes: [ {
        condition_type: "ao_event",
        configuration: { "event_name" => "session_needs_input", "watched_session_id" => sessions(:running).id }
      } ]
    )

    Sessions::ScheduleWakeUp.call(session: session, wake_at: future_wake_at(3.hours), prompt: "mine", replace_existing: true)

    assert Trigger.exists?(other_wake.id), "another session's wake is not this session's to cancel"
    assert Trigger.exists?(watcher.id), "\"wake when X happens\" is a different question from \"wake at 9am\""
  end
end
