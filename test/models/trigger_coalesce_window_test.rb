# frozen_string_literal: true

require "test_helper"

# `coalesce_window_seconds`: how close together two Slack messages have to land
# before they count as one event. The poller-side behaviour is covered in
# test/jobs/slack_trigger_poller_coalescing_test.rb; this is the resolution of the
# stored value, where NULL means "the default" and 0 means "off".
class TriggerCoalesceWindowTest < ActiveSupport::TestCase
  def build_trigger(attributes = {})
    Trigger.create!({
      name: "Coalescing #{SecureRandom.hex(3)}",
      agent_root_name: AgentRootsConfig.all.first.name,
      prompt_template: "There is a new message in Slack, channel {{channel}}.",
      status: "enabled",
      trigger_conditions_attributes: [
        { condition_type: "slack", configuration: { "channel_id" => "C_ALERTS", "channel_name" => "alerts", "event_type" => "new_message" } }
      ]
    }.merge(attributes))
  end

  test "a trigger that says nothing inherits the default window rather than switching coalescing off" do
    trigger = build_trigger

    assert_nil trigger.coalesce_window_seconds
    assert_equal Trigger::DEFAULT_COALESCE_WINDOW_SECONDS, trigger.effective_coalesce_window_seconds
    assert trigger.coalesces_messages?
  end

  test "0 is a real value and means never coalesce" do
    trigger = build_trigger(coalesce_window_seconds: 0)

    assert_equal 0, trigger.effective_coalesce_window_seconds
    assert_not trigger.coalesces_messages?
  end

  test "an explicit window overrides the default" do
    trigger = build_trigger(coalesce_window_seconds: 300)

    assert_equal 300, trigger.effective_coalesce_window_seconds
    assert trigger.coalesces_messages?
  end

  test "a negative window is rejected" do
    trigger = build_trigger
    trigger.coalesce_window_seconds = -1

    assert_not trigger.valid?
    assert_includes trigger.errors.full_messages.join(" "), "Coalesce window seconds"
  end

  test "a window longer than an hour is rejected" do
    trigger = build_trigger
    trigger.coalesce_window_seconds = 1.hour.to_i + 1

    assert_not trigger.valid?
  end

  test "a window stored on a trigger with no Slack condition reports itself inert" do
    trigger = Trigger.create!(
      name: "Nightly sweep #{SecureRandom.hex(3)}",
      agent_root_name: AgentRootsConfig.all.first.name,
      prompt_template: "Sweep the backlog",
      status: "enabled",
      coalesce_window_seconds: 120,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "interval" => "1", "unit" => "days", "time" => "04:00", "timezone" => "UTC" } }
      ]
    )

    assert trigger.coalesce_window_inert?
  end

  test "the INHERITED default is not called inert on a non-Slack trigger" do
    # Nobody chose it, so labelling it would be a warning about nothing — every
    # schedule trigger in the fleet would carry it.
    trigger = Trigger.create!(
      name: "Nightly sweep #{SecureRandom.hex(3)}",
      agent_root_name: AgentRootsConfig.all.first.name,
      prompt_template: "Sweep the backlog",
      status: "enabled",
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "interval" => "1", "unit" => "days", "time" => "04:00", "timezone" => "UTC" } }
      ]
    )

    assert_not trigger.coalesce_window_inert?
  end

  test "a window set on a Slack trigger is never inert" do
    assert_not build_trigger(coalesce_window_seconds: 30).coalesce_window_inert?
  end
end
