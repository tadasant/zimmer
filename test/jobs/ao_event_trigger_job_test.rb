# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "ostruct"

class AoEventTriggerJobTest < ActiveJob::TestCase
  setup do
    @trigger = triggers(:ao_event_trigger)
    @condition = trigger_conditions(:ao_event_condition)
    @mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo",
      default_branch: "main",
      subdirectory: nil
    )

    # Disable all other triggers with ao_event conditions to isolate tests
    Trigger.where.not(id: @trigger.id).where(status: "enabled").find_each do |t|
      t.update!(status: "disabled") if t.trigger_conditions.ao_event.exists?
    end
  end

  test "fires trigger when autonomous session transitions to needs_input" do
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    session = Session.create!(
      prompt: "Test session",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      is_autonomous: true,
      metadata: {}
    )

    assert_difference("Session.count", 1) do
      AoEventTriggerJob.perform_now("session_needs_input", session.id)
    end

    @condition.reload
    assert_not_nil @condition.last_triggered_at
  end

  test "skips non-autonomous sessions" do
    session = Session.create!(
      prompt: "Test session",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      is_autonomous: false,
      metadata: {}
    )

    assert_no_difference("Session.count") do
      AoEventTriggerJob.perform_now("session_needs_input", session.id)
    end
  end

  test "prevents infinite loops - skips trigger that created the session" do
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    # Create a session that was created by this trigger
    session = Session.create!(
      prompt: "Test session",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      is_autonomous: true,
      metadata: { "trigger_id" => @trigger.id }
    )

    assert_no_difference("Session.count") do
      AoEventTriggerJob.perform_now("session_needs_input", session.id)
    end
  end

  test "fires trigger for session created by a different trigger" do
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    # Session was created by a different trigger
    session = Session.create!(
      prompt: "Test session",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      is_autonomous: true,
      metadata: { "trigger_id" => 99999 }
    )

    assert_difference("Session.count", 1) do
      AoEventTriggerJob.perform_now("session_needs_input", session.id)
    end
  end

  test "skips disabled triggers" do
    @trigger.update!(status: "disabled")

    session = Session.create!(
      prompt: "Test session",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      is_autonomous: true,
      metadata: {}
    )

    assert_no_difference("Session.count") do
      AoEventTriggerJob.perform_now("session_needs_input", session.id)
    end
  end

  test "does nothing for unknown event names" do
    assert_no_difference("Session.count") do
      AoEventTriggerJob.perform_now("unknown_event", 1)
    end
  end

  test "does nothing for non-existent sessions" do
    assert_no_difference("Session.count") do
      AoEventTriggerJob.perform_now("session_needs_input", 999999)
    end
  end

  test "interpolates event variable in prompt" do
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    session = Session.create!(
      prompt: "Test session",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      is_autonomous: true,
      title: "My Test Session",
      metadata: {}
    )

    AoEventTriggerJob.perform_now("session_needs_input", session.id)

    created_session = Session.order(created_at: :desc).first
    assert_includes created_session.prompt, "Session ##{session.id}"
    assert_includes created_session.prompt, "My Test Session"
    assert_includes created_session.prompt, "needs input"
  end

  test "continues processing when one trigger fails" do
    AgentRootsConfig.stubs(:find!).raises(AgentRootsConfig::AgentRootNotFoundError.new("Not found"))

    session = Session.create!(
      prompt: "Test session",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      is_autonomous: true,
      metadata: {}
    )

    # Should not raise
    assert_nothing_raised do
      AoEventTriggerJob.perform_now("session_needs_input", session.id)
    end
  end

  # === Tests for session_failed event ===

  test "fires session_failed trigger when autonomous session transitions to failed" do
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    failed_trigger = Trigger.create!(
      name: "Session Failed Handler",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Session failed: {{event}}",
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_failed" } }
      ]
    )
    failed_condition = failed_trigger.trigger_conditions.first

    session = Session.create!(
      prompt: "Test session",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      is_autonomous: true,
      metadata: {}
    )

    assert_difference("Session.count", 1) do
      AoEventTriggerJob.perform_now("session_failed", session.id)
    end

    failed_condition.reload
    assert_not_nil failed_condition.last_triggered_at
  end

  test "does not fire session_needs_input trigger on session_failed event" do
    session = Session.create!(
      prompt: "Test session",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      is_autonomous: true,
      metadata: {}
    )

    # @trigger has only a session_needs_input condition; session_failed should not fire it
    assert_no_difference("Session.count") do
      AoEventTriggerJob.perform_now("session_failed", session.id)
    end

    @condition.reload
    assert_nil @condition.last_triggered_at
  end

  # === Tests for session_archived event ===

  test "fires session_archived trigger when autonomous session is archived" do
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    archived_trigger = Trigger.create!(
      name: "Session Archived Handler",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Session archived: {{event}}",
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_archived" } }
      ]
    )
    archived_condition = archived_trigger.trigger_conditions.first

    session = Session.create!(
      prompt: "Test session",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      is_autonomous: true,
      metadata: {}
    )

    assert_difference("Session.count", 1) do
      AoEventTriggerJob.perform_now("session_archived", session.id)
    end

    archived_condition.reload
    assert_not_nil archived_condition.last_triggered_at
  end

  test "does not fire session_archived trigger on session_needs_input event" do
    archived_trigger = Trigger.create!(
      name: "Session Archived Handler",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Session archived: {{event}}",
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_archived" } }
      ]
    )
    archived_condition = archived_trigger.trigger_conditions.first

    session = Session.create!(
      prompt: "Test session",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      is_autonomous: true,
      metadata: {}
    )

    AoEventTriggerJob.perform_now("session_needs_input", session.id)

    archived_condition.reload
    assert_nil archived_condition.last_triggered_at
  end

  test "interpolates event variable for session_archived" do
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    Trigger.create!(
      name: "Session Archived Handler",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Session archived: {{event}}",
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_archived" } }
      ]
    )

    session = Session.create!(
      prompt: "Test session",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      is_autonomous: true,
      title: "My Test Session",
      metadata: {}
    )

    AoEventTriggerJob.perform_now("session_archived", session.id)

    created_session = Session.order(created_at: :desc).first
    assert_includes created_session.prompt, "Session ##{session.id}"
    assert_includes created_session.prompt, "My Test Session"
    assert_includes created_session.prompt, "archived"
  end

  test "session_archived end-to-end: archive! enqueues job that fires watched-session trigger" do
    # End-to-end coverage that an archive! transition reaches the job and the
    # job fires the watched-session session_archived trigger, including the
    # one_time_reuse_trigger? auto-destroy at the end. Note: this test stubs
    # after_all_transactions_commit to yield immediately, so it does NOT
    # exercise the ordering between synchronous cleanup and async dispatch —
    # the cleanup-ordering regression guard lives in
    # session_state_machine_test.rb's "archive does NOT destroy
    # watched-session ao_event triggers scoped to session_archived" test.
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    target_session = Session.create!(
      prompt: "Target (will be reused)",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      is_autonomous: true,
      status: :needs_input,
      metadata: {}
    )

    watched_session = Session.create!(
      prompt: "Watched",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      is_autonomous: true,
      status: :needs_input,
      metadata: {}
    )

    one_time_trigger = Trigger.create!(
      name: "Wake target on watched archive",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Watched session reached state: {{event}}",
      reuse_session: true,
      last_session_id: target_session.id,
      trigger_conditions_attributes: [
        {
          condition_type: "ao_event",
          configuration: {
            "event_name" => "session_archived",
            "watched_session_id" => watched_session.id
          }
        }
      ]
    )

    # Archive the watched session — synchronous cleanup runs first, then the
    # job is enqueued via after_all_transactions_commit. We yield the deferred
    # block immediately so the job runs in the same flow.
    ActiveRecord.stubs(:after_all_transactions_commit).yields

    perform_enqueued_jobs(only: AoEventTriggerJob) do
      watched_session.archive!
    end

    assert_not Trigger.where(id: one_time_trigger.id).exists?,
      "One-time trigger should auto-destroy after firing on archive (proves the trigger fired)"
  end

  # === Tests for watched_session_id scoping ===

  test "watched-session ao_event condition fires only for the matching session" do
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    watched_session = Session.create!(
      prompt: "Watched",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      is_autonomous: true,
      metadata: {}
    )
    other_session = Session.create!(
      prompt: "Other",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      is_autonomous: true,
      metadata: {}
    )

    # Replace @condition with a session-scoped one
    @condition.update!(configuration: {
      "event_name" => "session_needs_input",
      "watched_session_id" => watched_session.id
    })

    # Other session transitioning should NOT fire the scoped condition
    assert_no_difference("Session.count") do
      AoEventTriggerJob.perform_now("session_needs_input", other_session.id)
    end
    @condition.reload
    assert_nil @condition.last_triggered_at

    # Watched session transitioning SHOULD fire the scoped condition
    assert_difference("Session.count", 1) do
      AoEventTriggerJob.perform_now("session_needs_input", watched_session.id)
    end
    @condition.reload
    assert_not_nil @condition.last_triggered_at
  end

  test "broadcast (no watched_session_id) ao_event condition fires for any session" do
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    # @condition is broadcast (no watched_session_id) by fixture default
    refute @condition.session_scoped_ao_event?

    session = Session.create!(
      prompt: "Test session",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      is_autonomous: true,
      metadata: {}
    )

    assert_difference("Session.count", 1) do
      AoEventTriggerJob.perform_now("session_needs_input", session.id)
    end
  end

  test "watched-session ao_event fires even when watched session is non-autonomous" do
    # Session-scoped wake-ups are an explicit per-session opt-in, so the
    # is_autonomous gate (which exists to prevent global automation from
    # firing on user-paused sessions) should NOT apply.
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    watched_session = Session.create!(
      prompt: "Watched (user-paused, non-autonomous)",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      is_autonomous: false,
      metadata: {}
    )

    @condition.update!(configuration: {
      "event_name" => "session_needs_input",
      "watched_session_id" => watched_session.id
    })

    assert_difference("Session.count", 1) do
      AoEventTriggerJob.perform_now("session_needs_input", watched_session.id)
    end

    @condition.reload
    assert_not_nil @condition.last_triggered_at
  end

  test "skips already-fired session-scoped condition (one-shot semantics)" do
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    watched_session = Session.create!(
      prompt: "Watched",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      is_autonomous: true,
      metadata: {}
    )

    original_fire_time = 1.hour.ago
    @condition.update!(
      configuration: {
        "event_name" => "session_needs_input",
        "watched_session_id" => watched_session.id
      },
      last_triggered_at: original_fire_time
    )

    assert_no_difference("Session.count") do
      AoEventTriggerJob.perform_now("session_needs_input", watched_session.id)
    end

    @condition.reload
    assert_in_delta original_fire_time.to_f, @condition.last_triggered_at.to_f, 1.0,
      "Already-fired condition should not be re-stamped on subsequent transitions"
  end

  test "auto-destroys one-time wake-up trigger after firing" do
    # When a trigger's only condition is a session-scoped ao_event, it's a
    # one-time per-session wake-up. After firing, the trigger should
    # auto-delete (mirrors ScheduleTriggerJob's one-time cleanup).
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    watched_session = Session.create!(
      prompt: "Watched",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      is_autonomous: true,
      metadata: {}
    )

    target_session = Session.create!(
      prompt: "Target (will be reused)",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      is_autonomous: true,
      status: :needs_input,
      metadata: {}
    )

    one_time_trigger = Trigger.create!(
      name: "Wake target on watched needs_input",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Watched session reached state: {{event}}",
      reuse_session: true,
      last_session_id: target_session.id,
      trigger_conditions_attributes: [
        {
          condition_type: "ao_event",
          configuration: {
            "event_name" => "session_needs_input",
            "watched_session_id" => watched_session.id
          }
        }
      ]
    )

    assert one_time_trigger.one_time_reuse_trigger?, "Sanity check: trigger should be a one-time reuse trigger"
    assert Trigger.where(id: one_time_trigger.id).exists?

    AoEventTriggerJob.perform_now("session_needs_input", watched_session.id)

    assert_not Trigger.where(id: one_time_trigger.id).exists?,
      "One-time trigger should auto-destroy after firing"
  end

  test "destroys sibling wake triggers when one-time trigger fires" do
    # When agents schedule the "triple-wake plus deadline backstop" pattern
    # (needs_input + failed + archived + a deadline backstop sibling group),
    # firing one trigger should destroy the others — the requester is now
    # awake, so the rest are moot.
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    watched_session = Session.create!(
      prompt: "Watched",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      is_autonomous: true,
      metadata: {}
    )

    target_session = Session.create!(
      prompt: "Target requester",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      is_autonomous: true,
      status: :needs_input,
      metadata: {}
    )

    needs_input_wake = Trigger.create!(
      name: "Wake on watched needs_input",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go {{event}}",
      reuse_session: true,
      last_session_id: target_session.id,
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched_session.id } }
      ]
    )

    failed_wake = Trigger.create!(
      name: "Wake on watched failed",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go {{event}}",
      reuse_session: true,
      last_session_id: target_session.id,
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_failed", "watched_session_id" => watched_session.id } }
      ]
    )

    archived_wake = Trigger.create!(
      name: "Wake on watched archived",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go {{event}}",
      reuse_session: true,
      last_session_id: target_session.id,
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_archived", "watched_session_id" => watched_session.id } }
      ]
    )

    deadline_backstop = Trigger.create!(
      name: "Deadline backstop wake",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go",
      reuse_session: true,
      last_session_id: target_session.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 1.hour.from_now.iso8601, "timezone" => "UTC" } }
      ]
    )

    AoEventTriggerJob.perform_now("session_needs_input", watched_session.id)

    assert_not Trigger.exists?(needs_input_wake.id), "firing trigger should be destroyed"
    assert_not Trigger.exists?(failed_wake.id), "sibling failed_wake should be destroyed"
    assert_not Trigger.exists?(archived_wake.id), "sibling archived_wake should be destroyed"
    assert_not Trigger.exists?(deadline_backstop.id), "deadline backstop sibling should be destroyed"
  end

  test "sibling cleanup leaves triggers for unrelated requesters intact" do
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    watched_session = Session.create!(
      prompt: "Watched",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      is_autonomous: true,
      metadata: {}
    )

    target_a = Session.create!(prompt: "A", agent_runtime: "claude_code", git_root: "https://github.com/test/repo", status: :needs_input, metadata: {})
    target_b = Session.create!(prompt: "B", agent_runtime: "claude_code", git_root: "https://github.com/test/repo", status: :needs_input, metadata: {})

    wake_for_a = Trigger.create!(
      name: "Wake A on watched",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go {{event}}",
      reuse_session: true,
      last_session_id: target_a.id,
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched_session.id } }
      ]
    )

    unrelated_wake_for_b = Trigger.create!(
      name: "Wake B on watched",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go {{event}}",
      reuse_session: true,
      last_session_id: target_b.id,
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_failed", "watched_session_id" => watched_session.id } }
      ]
    )

    AoEventTriggerJob.perform_now("session_needs_input", watched_session.id)

    assert_not Trigger.exists?(wake_for_a.id), "firing trigger destroyed"
    assert Trigger.exists?(unrelated_wake_for_b.id), "wake aimed at a different requester must survive"
  end

  test "does not auto-destroy multi-condition trigger after firing" do
    # If a trigger has additional conditions (slack, recurring schedule, etc.),
    # firing one condition shouldn't destroy the trigger — the others are still
    # live.
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    watched_session = Session.create!(
      prompt: "Watched",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      is_autonomous: true,
      metadata: {}
    )

    multi_trigger = Trigger.create!(
      name: "Wake on watched OR slack message",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Triggered: {{event}} {{link}}",
      trigger_conditions_attributes: [
        {
          condition_type: "ao_event",
          configuration: {
            "event_name" => "session_needs_input",
            "watched_session_id" => watched_session.id
          }
        },
        {
          condition_type: "slack",
          configuration: {
            "channel_id" => "C0TEST",
            "channel_name" => "test",
            "event_type" => "new_message"
          }
        }
      ]
    )

    AoEventTriggerJob.perform_now("session_needs_input", watched_session.id)

    assert Trigger.where(id: multi_trigger.id).exists?,
      "Multi-condition trigger should not be destroyed after firing one condition"
  end

  # === Tests for silent-drop race protection ===
  #
  # When a wake-up fires for a requester that is still in `running` state and
  # the prompt couldn't be delivered (legacy: enqueue_messages off and not a
  # one_time_reuse_trigger; or any future failure mode flagged by
  # last_follow_up_dropped?), the job must preserve the firing trigger AND
  # its siblings — destroying them would leave the requester with no wakes
  # at all, which is the cycle-18 bug from production session 3843.

  test "preserves siblings and skips auto-delete when follow_up_session! drops the prompt" do
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    watched_session = Session.create!(
      prompt: "Watched",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      is_autonomous: true,
      metadata: {}
    )

    requester = Session.create!(
      prompt: "Requester",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      is_autonomous: true,
      status: :needs_input,
      metadata: {}
    )

    firing_wake = Trigger.create!(
      name: "Wake on watched needs_input",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Wake up: {{event}}",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched_session.id } }
      ]
    )

    sibling_failed = Trigger.create!(
      name: "Sibling wake on watched failed",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Wake up: {{event}}",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_failed", "watched_session_id" => watched_session.id } }
      ]
    )

    sibling_deadline = Trigger.create!(
      name: "Sibling deadline backstop",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Wake up",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 1.hour.from_now.iso8601, "timezone" => "UTC" } }
      ]
    )

    # Force the dropped path. The natural scenario (recurring trigger + busy
    # requester + enqueue_messages off) doesn't intersect with one_time_reuse_trigger?
    # — the primary fix makes wake-ups always queue. To test the job's defensive
    # behavior in the (now unreachable from #follow_up_session!) dropped state,
    # we stub the predicate directly on the firing trigger.
    Trigger.any_instance.stubs(:last_follow_up_dropped?).returns(true)

    AoEventTriggerJob.perform_now("session_needs_input", watched_session.id)

    assert Trigger.exists?(firing_wake.id),
      "Firing trigger should be preserved when delivery was dropped"
    assert Trigger.exists?(sibling_failed.id),
      "Sibling wake must be preserved when delivery was dropped — otherwise the requester loses all wakes"
    assert Trigger.exists?(sibling_deadline.id),
      "Deadline backstop must be preserved when delivery was dropped"
  end

  test "wake-up to a running requester is queued and siblings are destroyed (end-to-end race scenario)" do
    # The race: a watched session transitions to needs_input while the
    # requester is still running on its previous turn. The primary fix makes
    # follow_up_session! queue the wake message durably (because the trigger
    # is a one_time_reuse_trigger?), so delivery succeeds — and the job then
    # destroys the firing trigger and its siblings, as it would in the normal
    # post-pause path.
    AgentRootsConfig.stubs(:find!).returns(@mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    watched_session = Session.create!(
      prompt: "Watched",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      is_autonomous: true,
      metadata: {}
    )

    requester = Session.create!(
      prompt: "Requester (still running its previous turn)",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo",
      is_autonomous: true,
      status: :running,
      metadata: {}
    )

    firing_wake = Trigger.create!(
      name: "Wake on watched needs_input",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Wake up: {{event}}",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched_session.id } }
      ]
    )

    sibling_failed = Trigger.create!(
      name: "Sibling wake on watched failed",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Wake up: {{event}}",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_failed", "watched_session_id" => watched_session.id } }
      ]
    )

    assert firing_wake.one_time_reuse_trigger?
    assert_equal false, firing_wake.enqueue_messages,
      "Sanity check: wake-up triggers created by the MCP tools default to enqueue_messages=false"

    assert_difference("requester.enqueued_messages.count", 1) do
      AoEventTriggerJob.perform_now("session_needs_input", watched_session.id)
    end

    enqueued = requester.enqueued_messages.last
    assert_equal "pending", enqueued.status, "Wake message should be queued for the running requester"

    assert_not Trigger.exists?(firing_wake.id),
      "Firing trigger should be destroyed — delivery succeeded via queuing"
    assert_not Trigger.exists?(sibling_failed.id),
      "Sibling wake should be destroyed — delivery succeeded via queuing"
  end

  # === Queue routing ===
  #
  # Latency-sensitive wakes must run on the dedicated `triggers` queue, NOT the
  # shared `default` queue. On `default` this job was starved for hours behind a
  # periodic/bulk backlog and never fired the wake in time — the root cause this
  # queue split fixes.

  test "runs on the dedicated triggers queue (not default)" do
    assert_equal "triggers", AoEventTriggerJob.new.queue_name
  end

  test "enqueues onto the triggers queue" do
    assert_enqueued_with(job: AoEventTriggerJob, queue: "triggers") do
      AoEventTriggerJob.perform_later("session_needs_input", 123)
    end
  end

  # === Dispatch-latency observability ===
  #
  # A wake that sits in the queue too long is delivered late. Surface that as a
  # .warn so future queue starvation is observable instead of silent.

  # ActiveJob restores enqueued_at as a Time object at perform time (Rails 8.1),
  # so the Time path is the real production path. A String can still appear (e.g.
  # a manually enqueued/legacy payload), so both branches are exercised.
  test "warns when enqueue-to-perform latency exceeds the threshold (Time enqueued_at — production path)" do
    job = AoEventTriggerJob.new("session_needs_input", 123)
    job.enqueued_at = Time.current - (AoEventTriggerJob::DISPATCH_LATENCY_WARN_THRESHOLD + 80)

    Rails.logger.expects(:warn).with(regexp_matches(/High dispatch latency/)).once

    job.send(:warn_on_high_dispatch_latency, "session_needs_input", 123)
  end

  test "warns when latency exceeds the threshold (String enqueued_at — fallback path)" do
    job = AoEventTriggerJob.new("session_needs_input", 123)
    job.enqueued_at = (Time.current - (AoEventTriggerJob::DISPATCH_LATENCY_WARN_THRESHOLD + 80)).iso8601

    Rails.logger.expects(:warn).with(regexp_matches(/High dispatch latency/)).once

    job.send(:warn_on_high_dispatch_latency, "session_needs_input", 123)
  end

  test "does not warn when dispatch latency is within the threshold" do
    job = AoEventTriggerJob.new("session_needs_input", 123)
    job.enqueued_at = Time.current - 1

    Rails.logger.expects(:warn).never

    job.send(:warn_on_high_dispatch_latency, "session_needs_input", 123)
  end

  test "does not warn (and does not raise) when enqueued_at is missing" do
    job = AoEventTriggerJob.new("session_needs_input", 123)
    job.enqueued_at = nil

    Rails.logger.expects(:warn).never

    assert_nothing_raised do
      job.send(:warn_on_high_dispatch_latency, "session_needs_input", 123)
    end
  end
end
