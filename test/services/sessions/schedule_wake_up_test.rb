# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "ostruct"

# The scheduler behind the wake_me_up_later MCP tool.
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

  # Additive, and deliberately: an agent routinely arms a wall-clock backstop
  # beside a state-change watcher, whichever fires first wins, and
  # Trigger#destroy_sibling_wakes! cleans up the rest.
  test "a second wake leaves the first one armed" do
    session = sessions(:needs_input)
    first = Sessions::ScheduleWakeUp.call(session: session, wake_at: future_wake_at(1.hour), prompt: "early")
    Sessions::ScheduleWakeUp.call(session: session, wake_at: future_wake_at(3.hours), prompt: "later")

    assert Trigger.exists?(first.id), "the agent-facing path must stay additive — the triple-wake pattern depends on it"
  end

  # https://github.com/tadasant/zimmer/issues/600. A session that resolves to no
  # catalog agent root — a legacy one, or one whose root has left the catalog —
  # gets a wake whose `agent_root_name` names no root. That value is a label on
  # the trigger; the wake reuses its target session and never spawns, so it must
  # still fire. It did not: Trigger#create_session! resolved the name before
  # reaching the reuse path, raised, and ScheduleTriggerJob parked the trigger
  # `failed` — leaving the session asleep for good, the exact outcome the
  # past-dated `wake_at` guard above exists to prevent.
  test "a wake for a session that resolves to no catalog agent root still fires" do
    session = sessions(:needs_input)
    assert_nil session.agent_root_key,
      "fixture precondition: this session must resolve to no catalog agent root"

    trigger = Sessions::ScheduleWakeUp.call(session: session, wake_at: future_wake_at, prompt: "Resume")
    assert_equal "claude_code", trigger.agent_root_name,
      "precondition: the wake is armed with a name that is not a catalog root"
    assert session.reload.waiting?

    AlertService.stubs(:raise_alert)
    AgentSessionJob.stubs(:enqueue_with_prompt).returns(OpenStruct.new(job_id: "job-600"))

    travel_to 2.hours.from_now do
      ScheduleTriggerJob.perform_now
    end

    assert_not session.reload.waiting?,
      "the wake should have resumed its session, not left it asleep"
    assert_equal "Resume", session.metadata["pending_follow_up_prompt"]
    assert_not_equal "failed", Trigger.find_by(id: trigger.id)&.status,
      "the wake must not park itself failed on a root it never uses"
  end
end
