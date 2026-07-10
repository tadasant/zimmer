# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "ostruct"

class ScheduleTriggerJobTest < ActiveJob::TestCase
  setup do
    @trigger = triggers(:enabled_schedule_trigger)
    @condition = trigger_conditions(:enabled_schedule_condition)
    @mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )

    # Make all schedule conditions "not due" by default so tests can selectively enable them
    TriggerCondition.schedule
      .joins(:trigger)
      .where(triggers: { status: "enabled" })
      .update_all(last_triggered_at: Time.current)
    @condition.reload
  end

  test "runs on the dedicated triggers queue (not default)" do
    assert_equal "triggers", ScheduleTriggerJob.new.queue_name
  end

  test "processes due schedule conditions" do
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    # Make the condition due by clearing last_triggered_at
    @condition.update!(last_triggered_at: nil)

    assert_difference("Session.count", 1) do
      ScheduleTriggerJob.perform_now
    end
  end

  test "skips conditions that are not due" do
    # Set last_triggered_at to very recent (not due)
    @condition.update!(last_triggered_at: 1.minute.ago)

    assert_no_difference("Session.count") do
      ScheduleTriggerJob.perform_now
    end
  end

  test "skips disabled schedule triggers" do
    condition = trigger_conditions(:disabled_schedule_condition)
    condition.update!(last_triggered_at: nil)

    # Only enabled schedule conditions should be processed
    initial_count = condition.trigger.sessions_created_count
    ScheduleTriggerJob.perform_now
    condition.trigger.reload
    assert_equal initial_count, condition.trigger.sessions_created_count
  end

  test "does not process slack conditions" do
    slack_trigger = triggers(:enabled_slack_trigger)
    initial_count = slack_trigger.sessions_created_count

    ScheduleTriggerJob.perform_now

    slack_trigger.reload
    assert_equal initial_count, slack_trigger.sessions_created_count
  end

  test "continues processing other conditions when one fails" do
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    # Make multiple conditions due
    TriggerCondition.schedule
      .joins(:trigger)
      .where(triggers: { status: "enabled" })
      .update_all(last_triggered_at: nil)

    # Even if one condition fails, others should be processed
    assert_nothing_raised do
      ScheduleTriggerJob.perform_now
    end
  end

  test "interpolates time and date in prompt" do
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    @condition.update!(last_triggered_at: nil)

    ScheduleTriggerJob.perform_now

    session = Session.order(created_at: :desc).first
    # The prompt should contain the current date since the template includes {{date}}
    assert_match(/\d{4}-\d{2}-\d{2}/, session.prompt)
  end

  test "advances last_triggered_at when session creation fails" do
    @condition.update!(last_triggered_at: nil)

    # Stub create_session! to raise an error (e.g. invalid MCP server)
    Trigger.any_instance.stubs(:create_session!).raises(ActiveRecord::RecordInvalid.new(@trigger))
    AlertService.stubs(:raise_alert)

    assert_nil @condition.last_triggered_at

    ScheduleTriggerJob.perform_now

    @condition.reload
    assert_not_nil @condition.last_triggered_at, "last_triggered_at should be advanced even when session creation fails"
  end

  test "raises exactly one alert when session creation fails" do
    @condition.update!(last_triggered_at: nil)

    Trigger.any_instance.stubs(:create_session!).raises(StandardError.new("mcp_servers contains invalid server(s): agent-orchestrator-pulse-directory-management"))

    alert_titles = []
    AlertService.stubs(:raise_alert).with { |title, **_kwargs| alert_titles << title; true }

    ScheduleTriggerJob.perform_now

    assert_equal [ "Schedule trigger session creation failed" ], alert_titles,
      "Expected exactly one alert from the inner rescue, not a duplicate from the outer rescue"
  end

  test "alert details include exception class and backtrace when session creation fails" do
    @condition.update!(last_triggered_at: nil)

    boom = StandardError.new("agent root not found in catalog")
    boom.set_backtrace([ "app/models/trigger.rb:42:in `heal_stale_agent_root!'", "app/models/trigger.rb:99:in `create_session!'" ])
    Trigger.any_instance.stubs(:create_session!).raises(boom)

    captured_details = nil
    AlertService.stubs(:raise_alert).with do |_title, **kwargs|
      captured_details = kwargs[:details]
      true
    end

    ScheduleTriggerJob.perform_now

    assert_not_nil captured_details, "alert details should be passed"
    assert_includes captured_details, "StandardError", "details should include the exception class"
    assert_includes captured_details, "agent root not found in catalog", "details should include the exception message"
    assert_includes captured_details, "Backtrace:", "details should include a backtrace section"
    assert_includes captured_details, "trigger.rb:42", "details should include backtrace frames"
  end

  test "auto-deletes trigger after one-time schedule fires" do
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    one_time_condition = trigger_conditions(:one_time_schedule_condition)
    trigger = one_time_condition.trigger
    trigger_id = trigger.id
    condition_id = one_time_condition.id
    one_time_condition.update!(last_triggered_at: nil)

    assert_equal "enabled", trigger.status

    travel_to Time.zone.parse("2026-04-15 19:00:00 UTC") do
      ScheduleTriggerJob.perform_now
    end

    assert_not Trigger.exists?(trigger_id), "One-time trigger should be auto-deleted after firing"
    assert_not TriggerCondition.exists?(condition_id), "Condition should be cascade-deleted with the trigger"
  end

  test "does not auto-delete trigger for recurring schedules" do
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    @condition.update!(last_triggered_at: nil)

    ScheduleTriggerJob.perform_now

    assert Trigger.exists?(@trigger.id), "Recurring trigger should still exist after firing"
    @trigger.reload
    assert_equal "enabled", @trigger.status, "Recurring trigger should remain enabled after firing"
  end

  test "auto-deletes one-time trigger even when session creation fails" do
    one_time_condition = trigger_conditions(:one_time_schedule_condition)
    trigger = one_time_condition.trigger
    trigger_id = trigger.id
    condition_id = one_time_condition.id
    one_time_condition.update!(last_triggered_at: nil)

    Trigger.any_instance.stubs(:create_session!).raises(StandardError.new("agent root not found"))
    AlertService.stubs(:raise_alert)

    assert_equal "enabled", trigger.status

    travel_to Time.zone.parse("2026-04-15 19:00:00 UTC") do
      ScheduleTriggerJob.perform_now
    end

    assert_not Trigger.exists?(trigger_id), "One-time trigger should be auto-deleted even on failure"
    assert_not TriggerCondition.exists?(condition_id), "Condition should be cascade-deleted with the trigger"
  end

  test "destroys sibling wake triggers when one-time schedule fires" do
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    requester = Session.create!(
      prompt: "Requester",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      status: :needs_input,
      metadata: {}
    )

    watched = Session.create!(
      prompt: "Watched",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      status: :running,
      metadata: {}
    )

    one_time_condition = trigger_conditions(:one_time_schedule_condition)
    firing_trigger = one_time_condition.trigger
    firing_trigger.update!(reuse_session: true, last_session_id: requester.id)
    one_time_condition.update!(last_triggered_at: nil)

    sibling_needs_input = Trigger.create!(
      name: "Sibling needs_input wake",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go {{event}}",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched.id } }
      ]
    )

    sibling_deadline = Trigger.create!(
      name: "Sibling deadline backstop",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 1.hour.from_now.iso8601, "timezone" => "UTC" } }
      ]
    )

    travel_to Time.zone.parse("2026-04-15 19:00:00 UTC") do
      ScheduleTriggerJob.perform_now
    end

    assert_not Trigger.exists?(firing_trigger.id), "firing one-time trigger destroyed"
    assert_not Trigger.exists?(sibling_needs_input.id), "ao_event sibling destroyed"
    assert_not Trigger.exists?(sibling_deadline.id), "schedule sibling destroyed"
  end

  test "does not destroy siblings when one-time trigger firing fails" do
    requester = Session.create!(
      prompt: "Requester",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      status: :needs_input,
      metadata: {}
    )

    watched = Session.create!(
      prompt: "Watched",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      status: :running,
      metadata: {}
    )

    one_time_condition = trigger_conditions(:one_time_schedule_condition)
    firing_trigger = one_time_condition.trigger
    firing_trigger.update!(reuse_session: true, last_session_id: requester.id)
    one_time_condition.update!(last_triggered_at: nil)

    sibling_wake = Trigger.create!(
      name: "Sibling wake",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go {{event}}",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched.id } }
      ]
    )

    Trigger.any_instance.stubs(:create_session!).raises(StandardError.new("boom"))
    AlertService.stubs(:raise_alert)

    travel_to Time.zone.parse("2026-04-15 19:00:00 UTC") do
      ScheduleTriggerJob.perform_now
    end

    assert_not Trigger.exists?(firing_trigger.id), "firing one-time trigger destroyed even on failure"
    assert Trigger.exists?(sibling_wake.id), "siblings should NOT be destroyed when the wake never delivered"
  end

  test "does not destroy siblings when recurring schedule fires" do
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    requester = Session.create!(
      prompt: "Requester",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      status: :needs_input,
      metadata: {}
    )

    watched = Session.create!(
      prompt: "Watched",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      status: :running,
      metadata: {}
    )

    sibling_wake = Trigger.create!(
      name: "Sibling wake on watched",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go {{event}}",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched.id } }
      ]
    )

    @trigger.update!(reuse_session: true, last_session_id: requester.id)
    @condition.update!(last_triggered_at: nil)

    ScheduleTriggerJob.perform_now

    assert Trigger.exists?(sibling_wake.id), "recurring trigger firing must not destroy unrelated wakes"
  end

  test "does not create infinite retry loop on persistent errors" do
    @condition.update!(last_triggered_at: nil)

    Trigger.any_instance.stubs(:create_session!).raises(StandardError.new("persistent error"))
    AlertService.stubs(:raise_alert)

    # First run: should advance last_triggered_at
    ScheduleTriggerJob.perform_now
    @condition.reload
    first_triggered_at = @condition.last_triggered_at
    assert_not_nil first_triggered_at

    # Second run immediately after: condition should NOT be due since last_triggered_at was just set
    assert_not @condition.schedule_due?, "condition should not be due immediately after last_triggered_at was advanced"
  end

  # === Tests for silent-drop race protection ===
  #
  # Mirrors the same regression coverage added to AoEventTriggerJob: when the
  # firing one-time trigger reports its follow-up was dropped, the job must
  # preserve siblings and skip auto-delete so a later wake (or the deadline
  # backstop) can actually deliver. This is the cycle-18 bug from session 3843.

  test "preserves siblings and skips auto-delete when follow_up_session! drops the prompt" do
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    requester = Session.create!(
      prompt: "Requester",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      status: :needs_input,
      metadata: {}
    )

    watched = Session.create!(
      prompt: "Watched",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      status: :running,
      metadata: {}
    )

    one_time_condition = trigger_conditions(:one_time_schedule_condition)
    firing_trigger = one_time_condition.trigger
    firing_trigger.update!(reuse_session: true, last_session_id: requester.id)
    one_time_condition.update!(last_triggered_at: nil)

    sibling_wake = Trigger.create!(
      name: "Sibling wake",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go {{event}}",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched.id } }
      ]
    )

    # Force the dropped path. See the AoEventTriggerJob equivalent test for
    # why we stub the predicate directly rather than relying on natural state.
    Trigger.any_instance.stubs(:last_follow_up_dropped?).returns(true)

    travel_to Time.zone.parse("2026-04-15 19:00:00 UTC") do
      ScheduleTriggerJob.perform_now
    end

    assert Trigger.exists?(firing_trigger.id),
      "Firing one-time trigger should be preserved when delivery was dropped"
    assert Trigger.exists?(sibling_wake.id),
      "Sibling wake must be preserved when delivery was dropped — otherwise the requester loses all wakes"
  end
end
