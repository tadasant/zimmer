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

  test "alert carries the exception itself, so the snippet has class, message and frames" do
    @condition.update!(last_triggered_at: nil)

    boom = StandardError.new("agent root not found in catalog")
    boom.set_backtrace([ "app/models/trigger.rb:42:in `heal_stale_agent_root!'", "app/models/trigger.rb:99:in `create_session!'" ])
    Trigger.any_instance.stubs(:create_session!).raises(boom)

    captured_error = nil
    AlertService.stubs(:raise_alert).with do |_title, **kwargs|
      captured_error = kwargs[:error]
      true
    end

    ScheduleTriggerJob.perform_now

    assert_not_nil captured_error, "the rescued exception should be passed as error:"
    snippet = AlertSnippet.build(captured_error)
    assert_includes snippet, "StandardError", "snippet should include the exception class"
    assert_includes snippet, "agent root not found in catalog", "snippet should include the exception message"
    assert_includes snippet, "trigger.rb:42", "snippet should include backtrace frames"
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

  # Regression for the "Daily Fleet Cleanup" incident (2026-08-23).
  #
  # The trigger's reuse candidate was a `spot` session that never ran a turn and
  # was then archived, so it had no Claude session_id and UnarchiveSessionService
  # could never restore it. #resuscitate_session! raised, this job advanced
  # last_triggered_at to stop the retry loop, and the daily sweep created
  # nothing — permanently, because the reuse candidate never changed. The fire
  # must now produce a session and no alert.
  test "a recurring fire whose archived reuse candidate never ran creates a session instead of alerting" do
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    # A session that never started has neither a runtime session id nor a
    # transcript — the fixture carries both, so clear both.
    never_ran = sessions(:archived)
    never_ran.update_columns(session_id: nil, transcript: nil)

    @trigger.update!(reuse_session: true, resuscitate_archived: true, last_session_id: never_ran.id)
    @condition.update!(last_triggered_at: nil)

    AlertService.expects(:raise_alert).never
    UnarchiveSessionService.expects(:call).never

    assert_difference("Session.count", 1) do
      ScheduleTriggerJob.perform_now
    end

    assert_not_nil @condition.reload.last_triggered_at
    assert_equal "enabled", @trigger.reload.status
    assert_not_equal never_ran.id, @trigger.last_session_id,
      "the trigger should now point at the fresh session, so the next fire is not stuck on the same candidate"
  end

  # === A failed one-time wake survives as a visible record (issue #76) ===
  #
  # Destroying the trigger on the failure path leaves a scheduled wake that
  # errored gone with nothing to show for it: "wake me at 6am to check the
  # deploy" becomes "you are not woken, and you find out at 9". These pin the
  # invariant that prevents it — park it as failed, keep it, keep the evidence,
  # and still never retry in a loop.

  test "marks one-time trigger failed instead of destroying it when session creation fails" do
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

    assert Trigger.exists?(trigger_id), "One-time trigger must survive a failed firing"
    assert TriggerCondition.exists?(condition_id), "Its condition must survive too"

    trigger.reload
    assert_equal "failed", trigger.status
    assert trigger.failed?
    assert_not_nil trigger.failed_at, "failed_at records when the fire failed"
    assert_includes trigger.last_error, "agent root not found",
      "last_error must carry the reason the user has to act on"
    assert_includes trigger.last_error, "StandardError", "last_error names the exception class"
  end

  test "a failed one-time trigger does not re-fire in a loop" do
    one_time_condition = trigger_conditions(:one_time_schedule_condition)
    trigger = one_time_condition.trigger
    one_time_condition.update!(last_triggered_at: nil)

    Trigger.any_instance.stubs(:create_session!).raises(StandardError.new("persistent error"))

    # One alert per attempted fire, so the alert count IS the retry count.
    alert_count = 0
    AlertService.stubs(:raise_alert).with { |_title, **_kwargs| alert_count += 1; true }

    travel_to Time.zone.parse("2026-04-15 19:00:00 UTC") do
      ScheduleTriggerJob.perform_now
      assert_equal 1, alert_count, "the fire is attempted once"

      # Five more ticks: a failed trigger is filtered out by every firing path,
      # exactly as a disabled one is. Nothing retries, so nothing re-alerts.
      5.times { ScheduleTriggerJob.perform_now }
    end

    assert_equal 1, alert_count, "a failed trigger must not be retried (or re-alerted) on later ticks"
    assert_equal "failed", trigger.reload.status
  end

  test "re-arming a failed one-time trigger fires it for real" do
    one_time_condition = trigger_conditions(:one_time_schedule_condition)
    trigger = one_time_condition.trigger
    one_time_condition.update!(last_triggered_at: nil)

    Trigger.any_instance.stubs(:create_session!).raises(StandardError.new("transient blip"))
    AlertService.stubs(:raise_alert)

    travel_to Time.zone.parse("2026-04-15 19:00:00 UTC") do
      ScheduleTriggerJob.perform_now
    end

    trigger.reload
    assert_equal "failed", trigger.status
    assert_nil one_time_condition.reload.last_triggered_at,
      "the schedule is deliberately left due — the status, not the timestamp, is what stops the retry"

    # The user presses Re-arm (or an agent calls action_trigger toggle).
    Trigger.any_instance.unstub(:create_session!)
    trigger.toggle!

    assert_equal "enabled", trigger.status
    assert_nil trigger.failed_at, "re-arming clears the failure state"
    assert_nil trigger.last_error

    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    travel_to Time.zone.parse("2026-04-15 19:05:00 UTC") do
      assert_difference("Session.count", 1) do
        ScheduleTriggerJob.perform_now
      end
    end
  end

  # The condition is advanced BEFORE the post-fire cleanup runs, so a raise from
  # #destroy_sibling_wakes! or the auto-delete arrives with the schedule already
  # spent and the session already created. Parking is still right — the error
  # must not vanish — but promising a re-arm would be a lie, and acting on it
  # would duplicate the session.
  test "a raise after the schedule was consumed parks the trigger without promising a re-arm" do
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    one_time_condition = trigger_conditions(:one_time_schedule_condition)
    trigger = one_time_condition.trigger
    one_time_condition.update!(last_triggered_at: nil)

    Trigger.any_instance.stubs(:destroy_sibling_wakes!).raises(StandardError.new("sibling cleanup blew up"))

    captured_details = nil
    AlertService.stubs(:raise_alert).with do |_title, **kwargs|
      captured_details = kwargs[:details]
      true
    end

    travel_to Time.zone.parse("2026-04-15 19:00:00 UTC") do
      assert_difference("Session.count", 1) do
        ScheduleTriggerJob.perform_now
      end
    end

    trigger.reload
    assert_equal "failed", trigger.status, "the error must still be recorded, not swallowed"
    assert_not_nil one_time_condition.reload.last_triggered_at,
      "the fire got far enough to consume the schedule"
    assert trigger.spent_one_shot_wake?,
      "there is nothing left to fire, so the UI must not offer a re-arm that would deliver nothing"
    assert_match(/will NOT re-fire/, captured_details)

    # And re-arming really does not duplicate the session.
    Trigger.any_instance.unstub(:destroy_sibling_wakes!)
    trigger.toggle!

    travel_to Time.zone.parse("2026-04-15 19:05:00 UTC") do
      assert_no_difference("Session.count") do
        ScheduleTriggerJob.perform_now
      end
    end
  end

  test "the alert for a failed one-time fire says the trigger was kept and how to re-arm it" do
    one_time_condition = trigger_conditions(:one_time_schedule_condition)
    trigger = one_time_condition.trigger
    one_time_condition.update!(last_triggered_at: nil)

    Trigger.any_instance.stubs(:create_session!).raises(StandardError.new("agent root not found"))

    captured_details = nil
    AlertService.stubs(:raise_alert).with do |_title, **kwargs|
      captured_details = kwargs[:details]
      true
    end

    travel_to Time.zone.parse("2026-04-15 19:00:00 UTC") do
      ScheduleTriggerJob.perform_now
    end

    assert_not_nil captured_details, "a failed wake must alert, not pass in silence"
    assert_match(/failed/i, captured_details)
    assert_match(/re-arm/i, captured_details)
    assert_includes captured_details, "/triggers/#{trigger.id}",
      "the alert should link the trigger the user has to re-arm"
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

    assert Trigger.exists?(firing_trigger.id), "firing one-time trigger is parked as failed, not destroyed"
    assert_equal "failed", firing_trigger.reload.status
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

  # --- Burst control -------------------------------------------------------
  #
  # A burst-suppressed fire delivered nothing. It must not be mistaken for a
  # successful fire by the bookkeeping that consumes conditions and auto-deletes
  # one-time triggers, or a burst on one condition silently destroys work
  # scheduled on another.

  test "a burst-suppressed one-time schedule is neither consumed nor auto-deleted" do
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    one_time_condition = trigger_conditions(:one_time_schedule_condition)
    trigger = one_time_condition.trigger
    trigger.update!(max_sessions_per_minute: 1)
    one_time_condition.update!(last_triggered_at: nil)

    # Put the trigger into an open burst.
    trigger.update_columns(burst_active_until: 5.minutes.from_now)

    travel_to Time.zone.parse("2026-04-15 19:00:00 UTC") do
      assert_no_difference("Session.count") do
        ScheduleTriggerJob.perform_now
      end
    end

    assert Trigger.exists?(trigger.id), "a trigger that spawned nothing must not be auto-deleted"
    assert_nil one_time_condition.reload.last_triggered_at,
      "the schedule is still due — it fires for real once the burst ends"
  end

  test "a schedule fires normally once its burst has ended" do
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    @trigger.update!(max_sessions_per_minute: 3)
    @trigger.update_columns(burst_active_until: 2.minutes.from_now)
    @condition.update!(last_triggered_at: nil)

    assert_no_difference("Session.count") do
      ScheduleTriggerJob.perform_now
    end

    travel(3.minutes) do
      assert_difference("Session.count", 1) do
        ScheduleTriggerJob.perform_now
      end
    end
  end
end
