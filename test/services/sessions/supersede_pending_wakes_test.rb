# frozen_string_literal: true

require "test_helper"

# Cancelling a session's pending wall-clock wakes, which is what a park into the
# spot queue does before it arms nothing at all.
#
# Every test here is about what the query must NOT reach. The destroy runs on a
# join, and a join that is one clause too wide takes a recurring sweep or another
# session's wake down with it.
class Sessions::SupersedePendingWakesTest < ActiveSupport::TestCase
  def future_wake_at(offset = 1.hour)
    offset.from_now.utc.strftime("%Y-%m-%dT%H:%M:%S")
  end

  test "destroys this session's unfired one-time wake" do
    session = sessions(:needs_input)
    wake = Sessions::ScheduleWakeUp.call(session: session, wake_at: future_wake_at(1.hour), prompt: "early")

    destroyed = Sessions::SupersedePendingWakes.call(session: session.reload)

    assert_equal [ wake.id ], destroyed
    assert_not Trigger.exists?(wake.id)
  end

  test "leaves another session's wake and this session's state-change watchers alone" do
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

    Sessions::SupersedePendingWakes.call(session: session)

    assert Trigger.exists?(other_wake.id), "another session's wake is not this session's to cancel"
    assert Trigger.exists?(watcher.id), "\"wake when X happens\" is a different question from \"wake at 9am\""
  end

  test "spares a trigger that carries conditions beyond the wake" do
    session = sessions(:needs_input)
    multi = Trigger.create!(
      name: "Nightly sweep with a one-off",
      agent_root_name: session.agent_runtime,
      prompt_template: "sweep",
      reuse_session: true,
      last_session_id: session.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => future_wake_at(2.hours), "timezone" => "UTC" } },
        { condition_type: "schedule", configuration: { "unit" => "hours", "interval" => 6, "timezone" => "UTC" } }
      ]
    )

    Sessions::SupersedePendingWakes.call(session: session)

    # The filtered join matches only ONE of this trigger's two conditions. Loading
    # the association through that join would make it look single-purpose and
    # destroy it, taking the recurring sweep with it.
    assert Trigger.exists?(multi.id), "a trigger doing other work is not this gesture's to destroy"
    assert_equal 2, multi.reload.trigger_conditions.count, "its conditions must survive intact"
  end
end
