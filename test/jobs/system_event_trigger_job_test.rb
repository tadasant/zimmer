# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Firing the fleet-wide events that have no session behind them.
class SystemEventTriggerJobTest < ActiveJob::TestCase
  def wake_trigger(status: "enabled", event_name: "quota_available", skip_if_pending_session: false)
    Trigger.create!(
      name: "Quota available #{SecureRandom.hex(3)}",
      agent_root_name: AgentRootsConfig.all.first.name,
      prompt_template: "The pool is back: {{event}}",
      status: status,
      skip_if_pending_session: skip_if_pending_session,
      scheduling_class: SessionGenesis::PRIORITY,
      trigger_conditions_attributes: [
        { condition_type: "system_event", configuration: { "event_name" => event_name } }
      ]
    )
  end

  test "fires every enabled trigger listening for the event" do
    trigger = wake_trigger

    assert_difference -> { Session.count }, 1 do
      SystemEventTriggerJob.perform_now("quota_available")
    end

    session = Session.order(:id).last
    assert_equal trigger.id.to_s, session.metadata["trigger_id"].to_s
    assert_includes session.prompt, "The Claude Code account pool has capacity again"
    assert_not_nil trigger.trigger_conditions.first.reload.last_triggered_at
  end

  # The spawned session decides which waiting sessions to start, so it must not
  # itself be waiting behind the gate it is there to open.
  test "the spawned session takes the trigger's priority class" do
    wake_trigger

    SystemEventTriggerJob.perform_now("quota_available")

    assert Session.order(:id).last.priority?
  end

  test "a disabled trigger is left alone" do
    wake_trigger(status: "disabled")

    assert_no_difference -> { Session.count } do
      SystemEventTriggerJob.perform_now("quota_available")
    end
  end

  test "a trigger listening for a different event is left alone" do
    trigger = wake_trigger
    trigger.trigger_conditions.first.update_columns(configuration: { "event_name" => "something_else" })

    assert_no_difference -> { Session.count } do
      SystemEventTriggerJob.perform_now("quota_available")
    end
  end

  # The single point of failure the whole redesign rests on: if the fleet trigger
  # is missing, disabled or broken, the edge must NOT be spent — or the parked
  # sessions it exists to wake wait for the pool to empty and recover all over
  # again.
  test "a pass with nothing listening puts the edge back" do
    AppSetting.current.update!(quota_pool_available: true)

    SystemEventTriggerJob.perform_now("quota_available")

    assert_equal false, AppSetting.current.reload.quota_pool_available
  end

  test "a pass where every fire raises puts the edge back" do
    wake_trigger
    AppSetting.current.update!(quota_pool_available: true)
    Trigger.any_instance.stubs(:create_session!).raises(StandardError, "boom")
    AlertService.stubs(:raise_alert)

    SystemEventTriggerJob.perform_now("quota_available")

    assert_equal false, AppSetting.current.reload.quota_pool_available
  end

  test "a delivered fire spends the edge" do
    wake_trigger
    AppSetting.current.update!(quota_pool_available: true)

    SystemEventTriggerJob.perform_now("quota_available")

    assert_equal true, AppSetting.current.reload.quota_pool_available
  end

  # The bug this setting exists for: the fleet session the wake spawns is itself
  # parked by the quota exhaustion it is there to answer, so every later recovery
  # found it still in `waiting` and spawned another one carrying the identical
  # prompt. 102 sessions, ten of them in one afternoon.
  test "without the setting, a second recovery spawns a duplicate while the first session is still waiting" do
    wake_trigger

    SystemEventTriggerJob.perform_now("quota_available")
    first = Session.order(:id).last
    assert first.waiting?

    assert_difference -> { Session.count }, 1 do
      SystemEventTriggerJob.perform_now("quota_available")
    end
    assert_not_equal first.id, Session.order(:id).last.id
  end

  test "with the setting on, a second recovery spawns nothing while the first session is still waiting" do
    trigger = wake_trigger(skip_if_pending_session: true)

    SystemEventTriggerJob.perform_now("quota_available")
    first = Session.order(:id).last
    fired_at = trigger.trigger_conditions.first.reload.last_triggered_at

    assert_no_difference -> { Session.count } do
      SystemEventTriggerJob.perform_now("quota_available")
    end

    assert_equal first.id, Session.order(:id).last.id
    # No new fire happened, so the condition must not claim one.
    assert_equal fired_at.to_i, trigger.trigger_conditions.first.reload.last_triggered_at.to_i
  end

  # The trap. Re-arming here would put the edge back, so the next sweep would see
  # the level `false` against an available pool, call it a fresh recovery, fire,
  # skip, and re-arm again — one wasted fire every sweep for as long as the
  # pending session stays pending. A skip means HANDLED, not undelivered.
  test "a pass skipped for a pending session does NOT put the edge back" do
    wake_trigger(skip_if_pending_session: true)

    SystemEventTriggerJob.perform_now("quota_available")
    AppSetting.current.update!(quota_pool_available: true)

    assert_no_difference -> { Session.count } do
      SystemEventTriggerJob.perform_now("quota_available")
    end

    assert_equal true, AppSetting.current.reload.quota_pool_available
  end

  test "the trigger fires for real again, and spends the edge, once the pending session finishes" do
    wake_trigger(skip_if_pending_session: true)
    SystemEventTriggerJob.perform_now("quota_available")

    # The pending session finishes: the next recovery is a real one again.
    Session.order(:id).last.update_columns(status: Session.statuses[:archived])
    AppSetting.current.update!(quota_pool_available: true)

    assert_difference -> { Session.count }, 1 do
      SystemEventTriggerJob.perform_now("quota_available")
    end
    assert_equal true, AppSetting.current.reload.quota_pool_available
  end

  # The mixed pass: one trigger skips because its work is already in hand, another
  # raises. `handled` is non-zero, so the edge stays spent — deliberately. Putting
  # it back would re-run the whole pass on the next sweep, where the first trigger
  # skips again and the second raises again; the alert the failure already raised
  # is what surfaces it, not an endlessly re-armed edge.
  test "a pass where one trigger skipped and another raised does not put the edge back" do
    skipping = wake_trigger(skip_if_pending_session: true)
    SystemEventTriggerJob.perform_now("quota_available")
    AppSetting.current.update!(quota_pool_available: true)

    # A second trigger whose agent root no longer resolves: its fire raises for
    # real rather than by a stub, so the first trigger still takes the skip path.
    raising = wake_trigger
    raising.update_columns(agent_root_name: "definitely-not-a-real-agent-root")
    AlertService.stubs(:raise_alert)

    assert_no_difference -> { Session.count } do
      SystemEventTriggerJob.perform_now("quota_available")
    end

    assert_equal "enabled", raising.reload.status
    assert_equal true, AppSetting.current.reload.quota_pool_available
    assert_equal 1, Session.for_trigger(skipping.id).count
  end

  # The fleet-idle event is the second citizen of this job, and the one place it
  # must behave differently: its latch is NOT put back when nothing listened.
  test "an undelivered no_sessions_in_progress fire does not re-arm anything" do
    AppSetting.editable.update!(quota_pool_available: true, fleet_idle_since: 10.minutes.ago,
                                fleet_idle_event_fired_at: Time.current)

    assert_no_difference -> { Session.count } do
      SystemEventTriggerJob.perform_now("no_sessions_in_progress")
    end

    setting = AppSetting.current.reload
    assert_equal true, setting.quota_pool_available,
      "the quota edge belongs to the other event and must not be spent by this one"
    assert_not_nil setting.fleet_idle_event_fired_at,
      "an idle fleet nobody listens for is not a reason to fire every sweep"
  end

  test "fires a trigger listening for no_sessions_in_progress" do
    trigger = wake_trigger(event_name: "no_sessions_in_progress")

    assert_difference -> { Session.count }, 1 do
      SystemEventTriggerJob.perform_now("no_sessions_in_progress")
    end

    session = Session.order(:id).last
    assert_equal trigger.id.to_s, session.metadata["trigger_id"].to_s
    assert_includes session.prompt, "The fleet has room for more work"
    assert_not_nil trigger.trigger_conditions.first.reload.last_triggered_at
  end

  test "an unknown event name does nothing" do
    wake_trigger

    assert_no_difference -> { Session.count } do
      SystemEventTriggerJob.perform_now("not_an_event")
    end
  end

  # A broadcast condition is recurring: a bad fire must alert without parking the
  # trigger, or one failure would stop every future recovery wake.
  test "a fire that raises alerts and leaves the trigger enabled" do
    trigger = wake_trigger
    Trigger.any_instance.stubs(:create_session!).raises(StandardError, "boom")
    AlertService.expects(:raise_alert).once

    SystemEventTriggerJob.perform_now("quota_available")

    assert_equal "enabled", trigger.reload.status
    assert_nil trigger.trigger_conditions.first.reload.last_triggered_at
  end
end
