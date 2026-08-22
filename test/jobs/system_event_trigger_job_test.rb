# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Firing the fleet-wide events that have no session behind them.
class SystemEventTriggerJobTest < ActiveJob::TestCase
  def wake_trigger(status: "enabled", event_name: "quota_available")
    Trigger.create!(
      name: "Quota available #{SecureRandom.hex(3)}",
      agent_root_name: AgentRootsConfig.all.first.name,
      prompt_template: "The pool is back: {{event}}",
      status: status,
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
