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

    make_due!

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

  # #447 as it was actually reported: a job tick, not a model predicate. A daily schedule
  # created at 04:35 PT for an 03:00 PT slot produced a session at 04:49 PT and advanced
  # last_triggered_at, so the 03:00 run it existed for never happened.
  test "a daily schedule created after its configured time does not fire on the next tick" do
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    @condition.update!(
      configuration: { "unit" => "days", "interval" => 1, "time" => "03:00",
                      "timezone" => "America/Los_Angeles" },
      last_triggered_at: nil,
      created_at: Time.utc(2026, 5, 12, 11, 35), # 04:35 PT
      armed_at: Time.utc(2026, 5, 12, 11, 35)
    )

    travel_to Time.utc(2026, 5, 12, 11, 49) do # 04:49 PT — the observed premature fire
      assert_no_difference("Session.count") do
        ScheduleTriggerJob.perform_now
      end
    end

    assert_nil @condition.reload.last_triggered_at,
      "a fire that never happened must not consume the schedule's next slot"

    travel_to Time.utc(2026, 5, 13, 10, 0) do # 03:00 PT the next day
      assert_difference("Session.count", 1) do
        ScheduleTriggerJob.perform_now
      end
    end
  end

  # #745, scenario 1, at the same altitude: a job tick, not a model predicate. A daily
  # schedule created disabled on Monday and enabled on Tuesday afternoon used to fire
  # on the next tick — created_at (Monday) was before Tuesday's 03:00 slot, so it read
  # as armed for a slot it had been switched off for, and the fire consumed that day's
  # run. Enabling re-arms it, so its first run is 03:00 on Wednesday.
  test "a daily schedule enabled after its configured time does not fire on the next tick" do
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    @trigger.update!(status: "disabled")
    @condition.update!(
      configuration: { "unit" => "days", "interval" => 1, "time" => "03:00",
                      "timezone" => "America/Los_Angeles" },
      last_triggered_at: nil,
      created_at: Time.utc(2026, 5, 11, 16, 0), # Monday 09:00 PT
      armed_at: Time.utc(2026, 5, 11, 16, 0)
    )

    travel_to Time.utc(2026, 5, 12, 22, 0) do # Tuesday 15:00 PT — the operator enables it
      @trigger.enable!

      assert_no_difference("Session.count") do
        ScheduleTriggerJob.perform_now
      end
    end

    assert_nil @condition.reload.last_triggered_at,
      "an enable is not a fire, and must not consume the schedule's next slot"

    travel_to Time.utc(2026, 5, 13, 10, 0) do # 03:00 PT the next day
      assert_difference("Session.count", 1) do
        ScheduleTriggerJob.perform_now
      end
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

    # Arm every enabled schedule condition. update_all alone would not do it: a days/weeks
    # condition also needs its slot to be past and its arming behind that slot, which is
    # what make_due! arranges — so each is armed individually.
    due = TriggerCondition.schedule.joins(:trigger).where(triggers: { status: "enabled" })
      .reject(&:one_time_schedule?)
    due.each { |condition| make_due!(condition) }
    assert_operator due.count, :>, 1, "the test needs more than one due condition to be meaningful"

    # Even if one condition fails, others should be processed
    assert_difference("Session.count", due.count) do
      assert_nothing_raised do
        ScheduleTriggerJob.perform_now
      end
    end
  end

  test "interpolates time and date in prompt" do
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    make_due!

    ScheduleTriggerJob.perform_now

    session = Session.order(created_at: :desc).first
    # The prompt should contain the current date since the template includes {{date}}
    assert_match(/\d{4}-\d{2}-\d{2}/, session.prompt)
  end

  test "advances last_triggered_at when session creation fails" do
    make_due!

    # Stub create_session! to raise an error (e.g. invalid MCP server)
    Trigger.any_instance.stubs(:create_session!).raises(ActiveRecord::RecordInvalid.new(@trigger))
    AlertService.stubs(:raise_alert)

    assert_nil @condition.last_triggered_at

    ScheduleTriggerJob.perform_now

    @condition.reload
    assert_not_nil @condition.last_triggered_at, "last_triggered_at should be advanced even when session creation fails"
  end

  test "raises exactly one alert when session creation fails" do
    make_due!

    Trigger.any_instance.stubs(:create_session!).raises(StandardError.new("mcp_servers contains invalid server(s): agent-orchestrator-pulse-directory-management"))

    alert_titles = []
    AlertService.stubs(:raise_alert).with { |title, **_kwargs| alert_titles << title; true }

    ScheduleTriggerJob.perform_now

    assert_equal [ "Schedule trigger session creation failed" ], alert_titles,
      "Expected exactly one alert from the inner rescue, not a duplicate from the outer rescue"
  end

  test "alert carries the exception itself, so the snippet has class, message and frames" do
    make_due!

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

  # The dedup skip must not look like a fire. For a one-time schedule that is the
  # difference between "runs when the pending session is done" and "the trigger is
  # destroyed and the work never happens".
  test "a one-time schedule skipped for a pending session keeps its trigger and stays due" do
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    one_time_condition = trigger_conditions(:one_time_schedule_condition)
    trigger = one_time_condition.trigger
    trigger.update!(skip_if_pending_session: true)
    one_time_condition.update!(last_triggered_at: nil)

    pending = sessions(:waiting)
    pending.update!(metadata: pending.metadata.merge("trigger_id" => trigger.id))

    assert_no_difference("Session.count") do
      travel_to(Time.zone.parse("2026-04-15 19:00:00 UTC")) { ScheduleTriggerJob.perform_now }
    end

    assert Trigger.exists?(trigger.id), "the skipped one-time trigger must survive"
    assert_nil one_time_condition.reload.last_triggered_at, "the schedule must stay due"

    # And it fires for real once the pending session is done.
    pending.update_columns(status: Session.statuses[:archived])
    assert_difference("Session.count", 1) do
      travel_to(Time.zone.parse("2026-04-15 19:00:00 UTC")) { ScheduleTriggerJob.perform_now }
    end
    assert_not Trigger.exists?(trigger.id), "and only then is the one-time trigger spent"
  end

  test "does not auto-delete trigger for recurring schedules" do
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    make_due!

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
    make_due!

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
  # that cleanup — the auto-delete on a spawning trigger, #hold_wake_group! on a
  # reuse wake — arrives with the schedule already spent and the session already
  # created. Parking is still right — the error must not vanish — but promising a
  # re-arm would be a lie, and acting on it would duplicate the session. Both
  # cleanup shapes are covered: this test stubs the auto-delete, and the one below
  # stubs the hold.
  test "a raise after the schedule was consumed parks the trigger without promising a re-arm" do
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    one_time_condition = trigger_conditions(:one_time_schedule_condition)
    trigger = one_time_condition.trigger
    one_time_condition.update!(last_triggered_at: nil)

    Trigger.any_instance.stubs(:destroy!).raises(StandardError.new("auto-delete blew up"))

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
    Trigger.any_instance.unstub(:destroy!)
    trigger.toggle!

    travel_to Time.zone.parse("2026-04-15 19:05:00 UTC") do
      assert_no_difference("Session.count") do
        ScheduleTriggerJob.perform_now
      end
    end
  end

  # The reuse-wake half of the same shape: the raise comes from #hold_wake_group!
  # rather than from the auto-delete. The trigger must still be parked with its
  # error — and the park is what protects it, because
  # SessionStateMachine#retire_held_wake_triggers exempts `failed` rows. The hold
  # mark is already on it by then: the resume the fire went through marks the
  # group before the job's own call, which is the belt-and-braces half of the
  # hold and the reason a raise here cannot lose the wake.
  test "a raise from the wake hold still parks the trigger, and the park protects it" do
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_with_prompt).returns(OpenStruct.new(job_id: "job-hold"))

    requester = Session.create!(
      prompt: "Requester",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      status: :needs_input,
      metadata: {}
    )

    one_time_condition = trigger_conditions(:one_time_schedule_condition)
    trigger = one_time_condition.trigger
    trigger.update!(reuse_session: true, last_session_id: requester.id)
    one_time_condition.update!(last_triggered_at: nil)

    Trigger.any_instance.stubs(:hold_wake_group!).raises(StandardError.new("hold blew up"))
    AlertService.stubs(:raise_alert)

    travel_to Time.zone.parse("2026-04-15 19:00:00 UTC") do
      ScheduleTriggerJob.perform_now
    end

    trigger.reload
    assert_equal "failed", trigger.status, "the error must be recorded, not swallowed"
    assert_not_nil trigger.wake_held_at, "the resume had already marked the group"
    assert_not_nil one_time_condition.reload.last_triggered_at,
      "the fire got far enough to consume the schedule"

    # The requester's next pause must leave the parked evidence alone, hold mark
    # or not — and re-arming it sheds the mark, so the re-arm is not destroyed by
    # the pause after that.
    requester.reload.pause!
    assert Trigger.exists?(trigger.id), "a parked wake is the user's to clear"

    trigger.toggle!
    assert_nil trigger.reload.wake_held_at
  ensure
    Trigger.any_instance.unstub(:hold_wake_group!)
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

  test "holds sibling wake triggers when one-time schedule fires, and retires them at the pause" do
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

    assert_not_nil firing_trigger.reload.wake_held_at, "firing one-time trigger held"
    assert_not_nil sibling_needs_input.reload.wake_held_at, "ao_event sibling held"
    assert_not_nil sibling_deadline.reload.wake_held_at, "schedule sibling held"

    requester.reload.pause!

    assert_not Trigger.exists?(firing_trigger.id), "firing one-time trigger retired with the turn"
    assert_not Trigger.exists?(sibling_needs_input.id), "ao_event sibling retired"
    assert_not Trigger.exists?(sibling_deadline.id), "schedule sibling retired"
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
    make_due!

    ScheduleTriggerJob.perform_now

    assert Trigger.exists?(sibling_wake.id), "recurring trigger firing must not destroy unrelated wakes"
  end

  test "does not create infinite retry loop on persistent errors" do
    make_due!

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
    make_due!

    assert_no_difference("Session.count") do
      ScheduleTriggerJob.perform_now
    end

    travel(3.minutes) do
      assert_difference("Session.count", 1) do
        ScheduleTriggerJob.perform_now
      end
    end
  end

  private

  # Make a recurring schedule condition due on this tick, whatever wall-clock time the
  # suite runs at.
  #
  # Clearing last_triggered_at is not enough on its own: a days/weeks schedule is due only
  # once its configured slot has come round, and only if it was already armed when that slot
  # passed (#447). So the slot moves to midnight — past on every tick — a weekly condition's
  # day_of_week moves to today, and the condition is dated back behind both. last_triggered_at
  # stays nil, so tests that assert it advances from nil keep asserting exactly that.
  def make_due!(condition = @condition)
    slot = { "time" => "00:00" }
    if condition.schedule_unit == "weeks"
      today = Time.current.in_time_zone(condition.schedule_timezone)
      slot["day_of_week"] = TriggerCondition::DAYS_OF_WEEK[(today.wday - 1) % 7]
    end

    condition.update!(
      last_triggered_at: nil,
      created_at: 2.days.ago,
      armed_at: 2.days.ago,
      configuration: condition.configuration.merge(slot)
    )
    condition
  end
end
