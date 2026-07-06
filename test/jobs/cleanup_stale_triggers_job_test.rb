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
