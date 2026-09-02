# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class CleanupStaleTriggersJobTest < ActiveJob::TestCase
  def make_session(status: :needs_input)
    Session.create!(
      git_root: "https://github.com/test/repo",
      agent_runtime: "claude_code",
      branch: "main",
      status: status
    )
  end

  test "destroys one-time-reuse trigger whose target session is archived" do
    target = make_session(status: :archived)
    watched = make_session(status: :running)

    orphan = Trigger.create!(
      name: "Orphan wake (target archived)",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go {{event}}",
      reuse_session: true,
      last_session_id: target.id,
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched.id } }
      ]
    )

    CleanupStaleTriggersJob.perform_now

    assert_not Trigger.exists?(orphan.id), "orphan wake aimed at archived target should be destroyed"
  end

  test "leaves one-time-reuse trigger whose target session is still active" do
    target = make_session(status: :needs_input)
    watched = make_session(status: :running)

    active = Trigger.create!(
      name: "Active wake (target alive)",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go {{event}}",
      reuse_session: true,
      last_session_id: target.id,
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched.id } }
      ]
    )

    CleanupStaleTriggersJob.perform_now

    assert Trigger.exists?(active.id), "wake for an active session must not be destroyed"
  end

  test "preserves resuscitate_archived triggers even when target is archived" do
    target = make_session(status: :archived)
    watched = make_session(status: :running)

    resuscitator = Trigger.create!(
      name: "Resuscitator wake",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go {{event}}",
      reuse_session: true,
      resuscitate_archived: true,
      last_session_id: target.id,
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched.id } }
      ]
    )

    CleanupStaleTriggersJob.perform_now

    assert Trigger.exists?(resuscitator.id), "triggers explicitly opting into resuscitate_archived must be preserved"
  end

  test "leaves recurring (broadcast) triggers alone even when last_session_id session is archived" do
    target = make_session(status: :archived)

    recurring = Trigger.create!(
      name: "Recurring broadcast referencing archived session",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go {{event}}",
      reuse_session: true,
      last_session_id: target.id,
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_needs_input" } }
      ]
    )

    CleanupStaleTriggersJob.perform_now

    assert Trigger.exists?(recurring.id), "recurring/broadcast trigger must not be destroyed"
  end

  test "destroys triggers whose only conditions are lapsed one-time schedules" do
    requester = make_session(status: :waiting)

    lapsed = Trigger.create!(
      name: "Lapsed one-time schedule",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 2.hours.ago.iso8601, "timezone" => "UTC" } }
      ]
    )

    CleanupStaleTriggersJob.perform_now

    assert_not Trigger.exists?(lapsed.id), "lapsed one-time schedule trigger should be destroyed"
  end

  # === Failed triggers are tombstones, not litter (issue #76) ===
  #
  # A trigger ScheduleTriggerJob parked as `failed` has, by construction, a
  # scheduled_at in the past and will never fire again on its own — so the
  # lapsed-schedule heuristic matches every one of them. Sweeping it would delete
  # the evidence an hour later and re-create the silent loss the parking exists to
  # prevent.

  test "preserves a failed one-time schedule trigger the user has not dealt with yet" do
    requester = make_session(status: :waiting)

    failed = Trigger.create!(
      name: "Failed wake",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 2.hours.ago.iso8601, "timezone" => "UTC" } }
      ]
    )
    failed.mark_failed(StandardError.new("agent root not found"))

    CleanupStaleTriggersJob.perform_now

    assert Trigger.exists?(failed.id),
      "a failed trigger must survive the lapsed-schedule sweep so the user can still see and re-arm it"
    assert_equal "failed", failed.reload.status
  end

  test "preserves a failed trigger even when its target session is archived" do
    target = make_session(status: :archived)
    watched = make_session(status: :running)

    failed = Trigger.create!(
      name: "Failed wake on archived target",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go {{event}}",
      reuse_session: true,
      last_session_id: target.id,
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched.id } }
      ]
    )
    failed.mark_failed(StandardError.new("boom"))

    CleanupStaleTriggersJob.perform_now

    assert Trigger.exists?(failed.id), "only the user clears a failed trigger"
  end

  test "does not destroy triggers whose one-time schedule is in the future" do
    requester = make_session(status: :waiting)

    future = Trigger.create!(
      name: "Future one-time schedule",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 1.hour.from_now.iso8601, "timezone" => "UTC" } }
      ]
    )

    CleanupStaleTriggersJob.perform_now

    assert Trigger.exists?(future.id)
  end

  # === A wake consumed by a resume is dead on arrival (issue #546) ===
  #
  # SessionStateMachine#cancel_pending_one_time_wake_triggers consumes a pending
  # one-time wake on any deliberate resume by stamping last_triggered_at. That
  # closes #schedule_due? forever, so ScheduleTriggerJob never fires it and never
  # runs its own auto-delete — and the lapsed-schedule ground below is keyed on
  # the wake's ORIGINAL scheduled_at, which on its own would leave a wake set 12
  # hours out and consumed five minutes later sitting in the list, `enabled` and
  # apparently armed, for ~13 hours.

  test "destroys a one-time wake consumed by a resume even though its scheduled_at is far in the future" do
    requester = make_session(status: :waiting)

    consumed = Trigger.create!(
      name: "Wake me in 12 hours",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 12.hours.from_now.iso8601, "timezone" => "UTC" } }
      ]
    )
    consumed.trigger_conditions.first.update!(last_triggered_at: Time.current)

    CleanupStaleTriggersJob.perform_now

    assert_not Trigger.exists?(consumed.id),
      "a consumed one-time wake can never fire again and must not linger until scheduled_at + 1h"
  end

  test "destroys a one-time wake the session's own resume consumed" do
    requester = make_session(status: :waiting)

    wake = Trigger.create!(
      name: "Wake me in 12 hours",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 12.hours.from_now.iso8601, "timezone" => "UTC" } }
      ]
    )

    # The real consuming write, driven end to end rather than stamped by hand.
    requester.send(:cancel_pending_one_time_wake_triggers)
    assert_not_nil wake.trigger_conditions.first.reload.last_triggered_at,
      "guard: the resume should have consumed the condition"

    CleanupStaleTriggersJob.perform_now

    assert_not Trigger.exists?(wake.id), "the resume that consumed the wake left a dead row behind"
  end

  test "destroys a consumed wake whose sibling ao_event condition is consumed too" do
    requester = make_session(status: :waiting)
    watched = make_session(status: :running)

    combined = Trigger.create!(
      name: "Watcher plus deadline backstop",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go {{event}}",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 12.hours.from_now.iso8601, "timezone" => "UTC" } },
        { condition_type: "ao_event", configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched.id } }
      ]
    )
    combined.trigger_conditions.each { |c| c.update!(last_triggered_at: Time.current) }

    CleanupStaleTriggersJob.perform_now

    assert_not Trigger.exists?(combined.id), "every one-shot on the trigger is spent — nothing can fire it"
  end

  test "preserves a consumed one-time schedule whose ao_event sibling is still armed" do
    requester = make_session(status: :waiting)
    watched = make_session(status: :running)

    half_spent = Trigger.create!(
      name: "Watcher plus deadline backstop",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go {{event}}",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 12.hours.from_now.iso8601, "timezone" => "UTC" } },
        { condition_type: "ao_event", configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched.id } }
      ]
    )
    half_spent.trigger_conditions.detect(&:one_time_schedule?).update!(last_triggered_at: Time.current)

    CleanupStaleTriggersJob.perform_now

    assert Trigger.exists?(half_spent.id), "the unconsumed ao_event watcher can still fire this trigger"
  end

  test "preserves a failed trigger whose consumed schedule is still in the future" do
    # The one failure that does not re-arm: a raise from the cleanup BEHIND a
    # successful fire parks the trigger with its schedule already consumed. The
    # `failed` tombstone must survive the new consumed-wake ground exactly as it
    # survives the lapsed-schedule one.
    requester = make_session(status: :waiting)

    failed = Trigger.create!(
      name: "Failed after a successful fire",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 12.hours.from_now.iso8601, "timezone" => "UTC" } }
      ]
    )
    failed.trigger_conditions.first.update!(last_triggered_at: Time.current)
    failed.mark_failed(StandardError.new("sibling cleanup blew up"))

    CleanupStaleTriggersJob.perform_now

    assert Trigger.exists?(failed.id), "only the user clears a failed trigger"
    assert_equal "failed", failed.reload.status
  end

  test "preserves an armed one-time wake with a future scheduled_at" do
    # The predicate must key on the condition being CONSUMED, not on the trigger
    # merely looking like a wake. Destroying this row is the silent failure the
    # narrow predicate exists to avoid: the session simply never wakes up.
    requester = make_session(status: :waiting)

    armed = Trigger.create!(
      name: "Armed wake, 12 hours out",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 12.hours.from_now.iso8601, "timezone" => "UTC" } }
      ]
    )

    CleanupStaleTriggersJob.perform_now

    assert Trigger.exists?(armed.id), "an unconsumed wake is still going to fire"
    assert_nil armed.trigger_conditions.first.reload.last_triggered_at
  end

  test "preserves a consumed wake that mixes in a live recurring schedule" do
    requester = make_session(status: :waiting)

    mixed = Trigger.create!(
      name: "Consumed one-time plus recurring",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 12.hours.from_now.iso8601, "timezone" => "UTC" } },
        { condition_type: "schedule", configuration: { "unit" => "hours", "interval" => 1, "timezone" => "UTC" } }
      ]
    )
    mixed.trigger_conditions.detect(&:one_time_schedule?).update!(last_triggered_at: Time.current)

    CleanupStaleTriggersJob.perform_now

    assert Trigger.exists?(mixed.id), "the recurring condition keeps firing; the trigger is not dead"
  end

  test "preserves a consumed one-time schedule on a trigger that created a session" do
    requester = make_session(status: :waiting)

    delivered = Trigger.create!(
      name: "Fired and spawned",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go",
      reuse_session: true,
      last_session_id: requester.id,
      sessions_created_count: 1,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 12.hours.from_now.iso8601, "timezone" => "UTC" } }
      ]
    )
    delivered.trigger_conditions.first.update!(last_triggered_at: Time.current)

    CleanupStaleTriggersJob.perform_now

    assert Trigger.exists?(delivered.id),
      "a wake that spawned a session is the firing job's residue — it falls to the lapsed-schedule ground on the old terms"
  end

  test "preserves a wake a system-recovery resume deliberately left armed" do
    # The preserve branch is the one resume that does NOT stamp last_triggered_at:
    # the session did not choose to wake, so its wakes are not moot. Nothing here
    # may collect them.
    requester = make_session(status: :waiting)

    preserved = Trigger.create!(
      name: "Wake me in 12 hours",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 12.hours.from_now.iso8601, "timezone" => "UTC" } }
      ]
    )

    requester.system_recovery_resume = true
    requester.send(:cancel_pending_one_time_wake_triggers)
    assert_nil preserved.trigger_conditions.first.reload.last_triggered_at,
      "guard: a system-recovery resume must leave the wake armed"

    CleanupStaleTriggersJob.perform_now

    assert Trigger.exists?(preserved.id), "a recovered session's wake is still going to fire"
  end

  test "leaves a consumed ao_event-only wake alone — this sweep only reaches one-time schedules" do
    # Pins the known gap rather than hiding it: Trigger#dead_one_time_wake? is
    # true for this trigger, but the candidate query asks for a schedule
    # condition, so the sweep never sees it. Tracked in tadasant/zimmer#793 —
    # if that is fixed, this expectation flips deliberately.
    requester = make_session(status: :waiting)
    watched = make_session(status: :running)

    watcher = Trigger.create!(
      name: "Watch that session",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go {{event}}",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched.id } }
      ]
    )
    watcher.trigger_conditions.first.update!(last_triggered_at: Time.current)
    assert watcher.reload.dead_one_time_wake?, "guard: the predicate does answer for this shape"

    CleanupStaleTriggersJob.perform_now

    assert Trigger.exists?(watcher.id), "out of this sweep's candidate set — see #793"
  end

  test "does not destroy triggers whose one-time schedule lapsed under the threshold" do
    requester = make_session(status: :waiting)

    recently_lapsed = Trigger.create!(
      name: "Recently lapsed one-time schedule",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 30.minutes.ago.iso8601, "timezone" => "UTC" } }
      ]
    )

    CleanupStaleTriggersJob.perform_now

    assert Trigger.exists?(recently_lapsed.id), "wait for ScheduleTriggerJob to handle recent lapses"
  end

  test "does not destroy triggers with mixed conditions even if one is a lapsed one-time schedule" do
    # Triggers that mix a stale one-time schedule with a recurring/slack/ao_event
    # condition are NOT pure one-time wakes; the other condition may still be
    # legitimate. Leave them alone.
    requester = make_session(status: :waiting)

    mixed = Trigger.create!(
      name: "Mixed conditions",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go {{event}}",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 2.hours.ago.iso8601, "timezone" => "UTC" } },
        { condition_type: "schedule", configuration: { "unit" => "hours", "interval" => 1, "timezone" => "UTC" } }
      ]
    )

    CleanupStaleTriggersJob.perform_now

    assert Trigger.exists?(mixed.id), "mixed-condition trigger must not be swept by the lapsed-schedule heuristic"
  end

  test "destroys lapsed one-time schedule stored with non-UTC offset (timezone-aware)" do
    # Regression: a previous lex-only SQL filter could miss schedules whose
    # ISO 8601 string has a far-positive UTC offset (e.g. +12:00) — the string
    # representation lex-compares "later" than a UTC cutoff string even though
    # the actual instant is well in the past. The Ruby-side check must use
    # ActiveSupport::TimeZone parsing so it never lies about staleness.
    requester = make_session(status: :waiting)

    # 2 hours ago in UTC, expressed as +12:00 wall-clock (so the literal string
    # starts ~14 hours later than the cutoff string). Lex comparison alone
    # would NOT catch this; timezone-aware parsing must.
    plus_twelve = (Time.current - 2.hours).in_time_zone("Etc/GMT-12")
    weird_tz_lapsed = Trigger.create!(
      name: "Lapsed schedule with +12:00 offset",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go",
      reuse_session: true,
      last_session_id: requester.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => plus_twelve.iso8601, "timezone" => "Etc/GMT-12" } }
      ]
    )

    CleanupStaleTriggersJob.perform_now

    assert_not Trigger.exists?(weird_tz_lapsed.id),
      "lapsed schedule with non-UTC offset must be destroyed via timezone-aware parsing, not lex comparison"
  end

  test "is idempotent — running twice produces no errors and no further deletions" do
    target = make_session(status: :archived)
    watched = make_session(status: :running)

    Trigger.create!(
      name: "Orphan wake",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "go {{event}}",
      reuse_session: true,
      last_session_id: target.id,
      trigger_conditions_attributes: [
        { condition_type: "ao_event", configuration: { "event_name" => "session_needs_input", "watched_session_id" => watched.id } }
      ]
    )

    CleanupStaleTriggersJob.perform_now
    assert_nothing_raised { CleanupStaleTriggersJob.perform_now }
  end
end
