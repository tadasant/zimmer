# frozen_string_literal: true

require "test_helper"

# `skip_if_pending_session`: the trigger setting that stops a trigger stacking up
# sessions that all carry the same intent.
class TriggerSkipIfPendingSessionTest < ActiveSupport::TestCase
  def build_trigger(skip_if_pending_session: true)
    Trigger.create!(
      name: "Pending dedup #{SecureRandom.hex(3)}",
      agent_root_name: AgentRootsConfig.all.first.name,
      prompt_template: "Do the fleet work",
      status: "enabled",
      skip_if_pending_session: skip_if_pending_session,
      trigger_conditions_attributes: [
        { condition_type: "system_event", configuration: { "event_name" => "quota_available" } }
      ]
    )
  end

  def fire(trigger)
    trigger.create_session!(prompt: trigger.prompt_template)
  end

  test "defaults to off, and an off trigger spawns a duplicate while its previous session is still waiting" do
    trigger = build_trigger(skip_if_pending_session: false)

    assert_not Trigger.new.skip_if_pending_session, "the setting must be opt-in"

    first = fire(trigger)
    assert first.waiting?

    second = assert_difference -> { Session.count }, 1 do
      fire(trigger)
    end

    assert_not_equal first.id, second.id
    assert_not trigger.last_fire_skipped_for_pending_session?
  end

  test "skips the fire while the previous session is still waiting" do
    trigger = build_trigger
    first = fire(trigger)

    second = assert_no_difference -> { Session.count } do
      fire(trigger)
    end

    assert_nil second
    assert trigger.last_fire_skipped_for_pending_session?
    assert_equal first.id, trigger.last_fire_pending_session.id
  end

  test "skips the fire while the previous session is running" do
    trigger = build_trigger
    first = fire(trigger)
    first.update_columns(status: Session.statuses[:running])

    assert_no_difference -> { Session.count } do
      fire(trigger)
    end

    assert_equal first.id, trigger.last_fire_pending_session.id
  end

  # The three statuses that must NOT block a legitimate future fire: each is a
  # session that has already had its turn.
  %w[archived failed needs_input].each do |status|
    test "a #{status} predecessor does not block the next fire" do
      trigger = build_trigger
      first = fire(trigger)
      first.update_columns(status: Session.statuses[status])

      second = assert_difference -> { Session.count }, 1 do
        fire(trigger)
      end

      assert_not_equal first.id, second.id
      assert_not trigger.last_fire_skipped_for_pending_session?
      assert_nil trigger.last_fire_pending_session
    end
  end

  test "another trigger's pending session does not block a fire" do
    other = build_trigger
    fire(other)

    trigger = build_trigger

    assert_difference -> { Session.count }, 1 do
      fire(trigger)
    end
    assert_not trigger.last_fire_skipped_for_pending_session?
  end

  # A burst notice carries "investigate this burst", not the trigger's own
  # intent, so it must not stand in for the work the trigger was asked to do.
  test "a pending burst-notice session does not block a fire" do
    trigger = build_trigger
    notice = fire(trigger)
    notice.update!(metadata: notice.metadata.merge("burst_notice" => true))

    assert_difference -> { Session.count }, 1 do
      fire(trigger)
    end
  end

  test "a skipped fire consumes no burst budget and leaves last_triggered_at alone" do
    trigger = build_trigger
    trigger.update!(max_sessions_per_minute: 2)
    fire(trigger)

    fired_at = trigger.reload.last_triggered_at
    count_before = trigger.burst_window_count

    fire(trigger)

    trigger.reload
    assert_equal count_before, trigger.burst_window_count
    assert_equal fired_at.to_i, trigger.last_triggered_at.to_i
    assert_equal 1, trigger.sessions_created_count
  end

  test "the trigger fires again once the pending session finishes" do
    trigger = build_trigger
    first = fire(trigger)

    assert_no_difference(-> { Session.count }) { fire(trigger) }

    first.update_columns(status: Session.statuses[:archived])

    assert_difference -> { Session.count }, 1 do
      fire(trigger)
    end
  end

  test "pending_intent_session reports the newest pending session" do
    trigger = build_trigger(skip_if_pending_session: false)
    older = fire(trigger)
    newer = fire(trigger)
    older.update_columns(created_at: 1.hour.ago)

    assert_equal newer.id, trigger.pending_intent_session.id
  end
end
