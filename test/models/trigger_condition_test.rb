# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class TriggerConditionTest < ActiveSupport::TestCase
  setup do
    @slack_condition = trigger_conditions(:enabled_slack_condition)
    @schedule_condition = trigger_conditions(:enabled_schedule_condition)
    @weekly_condition = trigger_conditions(:weekly_schedule_condition)
    @ao_event_condition = trigger_conditions(:ao_event_condition)
    @one_time_condition = trigger_conditions(:one_time_schedule_condition)
  end

  # Validations
  test "valid slack condition is valid" do
    assert @slack_condition.valid?
  end

  test "valid schedule condition is valid" do
    assert @schedule_condition.valid?
  end

  test "valid ao_event condition is valid" do
    assert @ao_event_condition.valid?
  end

  test "requires condition_type" do
    @slack_condition.condition_type = nil
    assert_not @slack_condition.valid?
    assert_includes @slack_condition.errors[:condition_type], "can't be blank"
  end

  test "condition_type must be valid" do
    @slack_condition.condition_type = "invalid"
    assert_not @slack_condition.valid?
    assert_includes @slack_condition.errors[:condition_type], "is not included in the list"
  end

  test "condition_type accepts all valid types" do
    TriggerCondition::CONDITION_TYPES.each do |type|
      condition = TriggerCondition.new(
        trigger: @slack_condition.trigger,
        condition_type: type,
        configuration: case type
                       when "slack" then { "channel_id" => "C123", "channel_name" => "test" }
                       when "schedule" then { "unit" => "minutes", "interval" => 5 }
                       when "ao_event" then { "event_name" => "session_needs_input" }
                       when "system_event" then { "event_name" => "quota_available" }
                       when "github_label" then { "repos" => [ "tadasant/zimmer" ], "target" => "pull_request", "labels" => [ "ready to merge" ] }
                       when "github_issue" then { "repos" => [ "tadasant/zimmer" ] }
                       end
      )
      assert condition.valid?, "Expected condition_type '#{type}' to be valid, got errors: #{condition.errors.full_messages}"
    end
  end

  test "requires trigger" do
    @slack_condition.trigger = nil
    assert_not @slack_condition.valid?
  end

  # Slack validation tests
  test "slack condition requires channel_id in configuration" do
    @slack_condition.configuration = {}
    assert_not @slack_condition.valid?
    assert_includes @slack_condition.errors[:configuration], "must include channel_id for Slack conditions"
  end

  test "slack condition validates event_type if present" do
    @slack_condition.configuration["event_type"] = "invalid_event"
    assert_not @slack_condition.valid?
    assert_includes @slack_condition.errors[:configuration], "event_type must be one of: new_message, bot_mention, dm_message, passive_listen_thread, passive_listen_channel, passive_listen"
  end

  # thread_ts (thread-scoped new_message) tests
  test "slack new_message condition is valid with a thread_ts" do
    @slack_condition.configuration["thread_ts"] = "1704000000.000000"
    assert @slack_condition.valid?
    assert @slack_condition.thread_scoped?
    assert_equal "1704000000.000000", @slack_condition.thread_ts
  end

  test "thread_scoped? is false without a thread_ts" do
    assert_not @slack_condition.thread_scoped?
    assert_nil @slack_condition.thread_ts
  end

  test "thread_ts requires a channel_id" do
    @slack_condition.configuration = { "event_type" => "new_message", "thread_ts" => "1704000000.000000" }
    assert_not @slack_condition.valid?
    assert_includes @slack_condition.errors[:configuration], "thread_ts requires a channel_id"
  end

  test "thread_ts is rejected for bot_mention conditions" do
    @slack_condition.configuration["event_type"] = "bot_mention"
    @slack_condition.configuration["thread_ts"] = "1704000000.000000"
    assert_not @slack_condition.valid?
    assert_includes @slack_condition.errors[:configuration], "thread_ts is not supported for bot_mention conditions"
  end

  test "thread_ts is rejected for every passive-listening condition" do
    %w[passive_listen_thread passive_listen_channel passive_listen].each do |event_type|
      @slack_condition.configuration["event_type"] = event_type
      @slack_condition.configuration["thread_ts"] = "1704000000.000000"
      assert_not @slack_condition.valid?
      assert_includes @slack_condition.errors[:configuration], "thread_ts is not supported for #{event_type} conditions"
    end
  end

  test "blank thread_ts does not make a condition thread-scoped" do
    @slack_condition.configuration["thread_ts"] = ""
    assert @slack_condition.valid?
    assert_not @slack_condition.thread_scoped?
  end

  # Schedule validation tests
  test "schedule condition requires unit" do
    @schedule_condition.configuration = {}
    assert_not @schedule_condition.valid?
    assert_includes @schedule_condition.errors[:configuration], "must include unit for Schedule conditions"
  end

  test "schedule condition validates unit values" do
    @schedule_condition.configuration = { "unit" => "invalid", "interval" => 1 }
    assert_not @schedule_condition.valid?
    assert_includes @schedule_condition.errors[:configuration], "unit must be one of: #{TriggerCondition::SCHEDULE_UNITS.join(', ')}"
  end

  test "schedule condition requires interval" do
    @schedule_condition.configuration = { "unit" => "days" }
    assert_not @schedule_condition.valid?
    assert_includes @schedule_condition.errors[:configuration], "must include interval for Schedule conditions"
  end

  test "schedule condition validates interval minimum" do
    @schedule_condition.configuration = { "unit" => "days", "interval" => 0, "time" => "09:00" }
    assert_not @schedule_condition.valid?
    assert_includes @schedule_condition.errors[:configuration], "interval must be at least 1"
  end

  test "schedule condition requires time for days" do
    @schedule_condition.configuration = { "unit" => "days", "interval" => 1 }
    assert_not @schedule_condition.valid?
    assert_includes @schedule_condition.errors[:configuration], "must include time for days schedules"
  end

  test "schedule condition requires day_of_week for weekly" do
    @weekly_condition.configuration = { "unit" => "weeks", "interval" => 1, "time" => "10:00" }
    assert_not @weekly_condition.valid?
    assert_includes @weekly_condition.errors[:configuration], "must include day_of_week for weekly schedules"
  end

  test "schedule condition validates day_of_week values" do
    @weekly_condition.configuration = { "unit" => "weeks", "interval" => 1, "time" => "10:00", "day_of_week" => "invalid" }
    assert_not @weekly_condition.valid?
    assert_includes @weekly_condition.errors[:configuration], "day_of_week must be one of: #{TriggerCondition::DAYS_OF_WEEK.join(', ')}"
  end

  test "schedule condition valid with minutes" do
    @schedule_condition.configuration = { "unit" => "minutes", "interval" => 15 }
    assert @schedule_condition.valid?
  end

  test "schedule condition valid with hours" do
    @schedule_condition.configuration = { "unit" => "hours", "interval" => 1 }
    assert @schedule_condition.valid?
  end

  test "schedule condition validates time format" do
    @schedule_condition.configuration = { "unit" => "days", "interval" => 1, "time" => "invalid" }
    assert_not @schedule_condition.valid?
    assert_includes @schedule_condition.errors[:configuration], "time must be in HH:MM format"
  end

  test "schedule condition rejects invalid time values like 25:99" do
    @schedule_condition.configuration = { "unit" => "days", "interval" => 1, "time" => "25:99" }
    assert_not @schedule_condition.valid?
    assert_includes @schedule_condition.errors[:configuration], "time must be in HH:MM format"
  end

  test "schedule condition validates timezone" do
    @schedule_condition.configuration = { "unit" => "days", "interval" => 1, "time" => "09:00", "timezone" => "Invalid/Zone" }
    assert_not @schedule_condition.valid?
    assert_includes @schedule_condition.errors[:configuration], "timezone is not a recognized timezone"
  end

  # One-time schedule validation tests
  test "one-time schedule condition is valid with scheduled_at" do
    assert @one_time_condition.valid?
  end

  test "one-time schedule condition does not require unit or interval" do
    condition = TriggerCondition.new(
      trigger: @one_time_condition.trigger,
      condition_type: "schedule",
      configuration: { "scheduled_at" => "2026-04-15T14:30:00", "timezone" => "UTC" }
    )
    assert condition.valid?
  end

  test "one-time schedule normalizes datetime-local format by appending seconds" do
    condition = TriggerCondition.new(
      trigger: @one_time_condition.trigger,
      condition_type: "schedule",
      configuration: { "scheduled_at" => "2026-04-15T14:30", "timezone" => "UTC" }
    )
    assert condition.valid?
    assert_equal "2026-04-15T14:30:00", condition.configuration["scheduled_at"]
  end

  test "one-time schedule condition rejects invalid scheduled_at" do
    @one_time_condition.configuration = { "scheduled_at" => "not-a-date" }
    assert_not @one_time_condition.valid?
    assert_includes @one_time_condition.errors[:configuration], "scheduled_at must be a valid datetime (ISO 8601 format)"
  end

  test "one-time schedule condition rejects invalid timezone" do
    @one_time_condition.configuration = { "scheduled_at" => "2026-04-15T14:30:00", "timezone" => "Invalid/Zone" }
    assert_not @one_time_condition.valid?
    assert_includes @one_time_condition.errors[:configuration], "timezone is not a recognized timezone"
  end

  test "one_time_schedule? returns true for scheduled_at conditions" do
    assert @one_time_condition.one_time_schedule?
  end

  test "one_time_schedule? returns false for recurring conditions" do
    assert_not @schedule_condition.one_time_schedule?
  end

  # The instant itself, for readers that have to tell a wake still in flight from
  # a wake that was lost — see SessionStateMachine::SCHEDULE_FIRE_SETTLE. It must
  # agree with #schedule_due? about when the moment was, so it reads the same
  # timezone through the same parser.
  test "scheduled_at_time reads the schedule's instant in its own timezone" do
    @one_time_condition.configuration = { "scheduled_at" => "2026-04-15T14:30:00", "timezone" => "America/New_York" }

    assert_equal Time.utc(2026, 4, 15, 18, 30), @one_time_condition.scheduled_at_time.utc
  end

  test "scheduled_at_time agrees with schedule_due? about the moment" do
    @one_time_condition.configuration = { "scheduled_at" => "2026-04-15T14:30:00", "timezone" => "UTC" }
    due_at = @one_time_condition.scheduled_at_time

    travel_to(due_at - 1.second) { assert_not @one_time_condition.schedule_due? }
    travel_to(due_at) { assert @one_time_condition.schedule_due? }
  end

  test "scheduled_at_time is nil for a recurring schedule and for an unreadable value" do
    assert_nil @schedule_condition.scheduled_at_time

    @one_time_condition.configuration = { "scheduled_at" => "not-a-date", "timezone" => "UTC" }
    assert_nil @one_time_condition.scheduled_at_time

    @one_time_condition.configuration = { "scheduled_at" => "2026-04-15T14:30:00", "timezone" => "Invalid/Zone" }
    assert_nil @one_time_condition.scheduled_at_time
  end

  # Zimmer event validation tests
  test "ao_event condition requires event_name" do
    @ao_event_condition.configuration = {}
    assert_not @ao_event_condition.valid?
    assert_includes @ao_event_condition.errors[:configuration], "must include event_name for Zimmer Event conditions"
  end

  test "ao_event condition validates event_name" do
    @ao_event_condition.configuration = { "event_name" => "invalid_event" }
    assert_not @ao_event_condition.valid?
    assert_includes @ao_event_condition.errors[:configuration], "event_name must be one of: #{TriggerCondition::AO_EVENT_NAMES.join(', ')}"
  end

  test "ao_event condition accepts valid event names" do
    TriggerCondition::AO_EVENT_NAMES.each do |event|
      @ao_event_condition.configuration = { "event_name" => event }
      assert @ao_event_condition.valid?, "Expected event_name '#{event}' to be valid"
    end
  end

  test "ao_event condition AO_EVENT_NAMES includes session_failed" do
    assert_includes TriggerCondition::AO_EVENT_NAMES, "session_failed"
  end

  test "ao_event condition AO_EVENT_NAMES includes session_archived" do
    assert_includes TriggerCondition::AO_EVENT_NAMES, "session_archived"
  end

  test "ao_event condition accepts session_archived event name" do
    @ao_event_condition.configuration = { "event_name" => "session_archived" }
    assert @ao_event_condition.valid?
  end

  # === The account subject ===
  #
  # The vocabulary was session-only until `account_needs_reauth`. What matters is
  # that the two halves stay apart: session-only machinery (scoping, the one-shot
  # guard) must not attach itself to an account event.

  test "ao_event condition accepts the account_needs_reauth event name" do
    @ao_event_condition.configuration = { "event_name" => "account_needs_reauth" }

    assert @ao_event_condition.valid?
    assert_predicate @ao_event_condition, :account_ao_event?
    assert_not @ao_event_condition.session_ao_event?
  end

  test "an account event is never session-scoped" do
    @ao_event_condition.configuration = { "event_name" => "account_needs_reauth" }

    assert_not @ao_event_condition.session_scoped_ao_event?
    assert_nil @ao_event_condition.watched_session_id
  end

  test "watched_session_id is rejected on an account event" do
    target = sessions(:needs_input)
    @ao_event_condition.configuration = {
      "event_name" => "account_needs_reauth",
      "watched_session_id" => target.id
    }

    assert_not @ao_event_condition.valid?
    assert @ao_event_condition.errors[:configuration].any? { |e| e.include?("only meaningful for session events") }
  end

  # A row written before that validation existed must still not be read as scoped
  # — otherwise AoEventTriggerJob would compare an account id against a session id
  # and silently never fire.
  test "a stray watched_session_id on a stored account event is ignored, not obeyed" do
    @ao_event_condition.update_columns(
      configuration: { "event_name" => "account_needs_reauth", "watched_session_id" => 999_999 }
    )

    assert_nil @ao_event_condition.reload.watched_session_id
    assert_not @ao_event_condition.session_scoped_ao_event?
  end

  test "the account event describes itself in the vocabulary the UI renders" do
    @ao_event_condition.configuration = { "event_name" => "account_needs_reauth" }

    assert_equal "Zimmer Event: Account needs re-authentication", @ao_event_condition.description
  end

  test "the event vocabularies partition AO_EVENT_NAMES" do
    assert_equal TriggerCondition::AO_EVENT_NAMES.sort,
                 (TriggerCondition::SESSION_AO_EVENT_NAMES + TriggerCondition::ACCOUNT_AO_EVENT_NAMES).sort
    assert_empty TriggerCondition::SESSION_AO_EVENT_NAMES & TriggerCondition::ACCOUNT_AO_EVENT_NAMES
  end

  test "ao_event condition with valid watched_session_id is valid" do
    target = sessions(:needs_input)
    @ao_event_condition.configuration = {
      "event_name" => "session_needs_input",
      "watched_session_id" => target.id
    }
    assert @ao_event_condition.valid?, @ao_event_condition.errors.full_messages.to_sentence
  end

  test "ao_event condition with non-existent watched_session_id is invalid" do
    @ao_event_condition.configuration = {
      "event_name" => "session_needs_input",
      "watched_session_id" => 999_999_999
    }
    assert_not @ao_event_condition.valid?
    assert_includes @ao_event_condition.errors[:configuration].join, "does not reference an existing session"
  end

  test "ao_event condition with non-positive watched_session_id is invalid" do
    @ao_event_condition.configuration = {
      "event_name" => "session_needs_input",
      "watched_session_id" => 0
    }
    assert_not @ao_event_condition.valid?
    assert_includes @ao_event_condition.errors[:configuration].join, "must be a positive integer"
  end

  test "ao_event condition normalizes string watched_session_id to integer" do
    target = sessions(:needs_input)
    @ao_event_condition.configuration = {
      "event_name" => "session_needs_input",
      "watched_session_id" => target.id.to_s
    }
    assert @ao_event_condition.valid?
    assert_equal target.id, @ao_event_condition.configuration["watched_session_id"]
  end

  test "watched_session_id returns integer when present" do
    target = sessions(:needs_input)
    @ao_event_condition.configuration = {
      "event_name" => "session_needs_input",
      "watched_session_id" => target.id
    }
    @ao_event_condition.save!
    assert_equal target.id, @ao_event_condition.watched_session_id
  end

  test "watched_session_id returns nil when absent" do
    assert_nil @ao_event_condition.watched_session_id
  end

  test "watched_session_id returns nil for non-ao_event conditions" do
    assert_nil @slack_condition.watched_session_id
  end

  test "session_scoped_ao_event? returns true when watched_session_id is set" do
    target = sessions(:needs_input)
    @ao_event_condition.configuration = {
      "event_name" => "session_needs_input",
      "watched_session_id" => target.id
    }
    @ao_event_condition.save!
    assert @ao_event_condition.session_scoped_ao_event?
  end

  test "session_scoped_ao_event? returns false when watched_session_id is absent" do
    assert_not @ao_event_condition.session_scoped_ao_event?
  end

  test "description for session_failed event" do
    @ao_event_condition.configuration = { "event_name" => "session_failed" }
    @ao_event_condition.save!
    assert_equal "Zimmer Event: Session failed", @ao_event_condition.description
  end

  test "description for session_archived event" do
    @ao_event_condition.configuration = { "event_name" => "session_archived" }
    @ao_event_condition.save!
    assert_equal "Zimmer Event: Session archived", @ao_event_condition.description
  end

  test "description includes watched session id when scoped" do
    target = sessions(:needs_input)
    @ao_event_condition.configuration = {
      "event_name" => "session_needs_input",
      "watched_session_id" => target.id
    }
    @ao_event_condition.save!
    assert_equal "Zimmer Event: Session needs input (session ##{target.id})", @ao_event_condition.description
  end

  # Scopes
  test "a dm_message condition is valid without a channel_id" do
    condition = TriggerCondition.new(
      trigger: triggers(:enabled_slack_trigger),
      condition_type: "slack",
      configuration: { "event_type" => "dm_message" }
    )

    assert_predicate condition, :valid?
  end

  test "a dm_message condition rejects thread_ts, which has nothing to scope" do
    condition = TriggerCondition.new(
      trigger: triggers(:enabled_slack_trigger),
      condition_type: "slack",
      configuration: { "channel_id" => "C1", "event_type" => "dm_message", "thread_ts" => "123.456" }
    )

    assert_not condition.valid?
    assert_includes condition.errors[:configuration], "thread_ts is not supported for dm_message conditions"
  end

  test "dm_message describes itself as a DM watcher, not a channel one" do
    condition = TriggerCondition.new(
      trigger: triggers(:enabled_slack_trigger),
      condition_type: "slack",
      configuration: { "event_type" => "dm_message", "allowed_user_ids" => %w[U1 U2] }
    )

    assert_equal "Slack: DMs to Zimmer from 2 allowed user(s)", condition.description
  end

  test "slack scope returns only slack conditions" do
    slack_conditions = TriggerCondition.slack
    assert slack_conditions.all? { |c| c.condition_type == "slack" }
    assert slack_conditions.count > 0
  end

  test "schedule scope returns only schedule conditions" do
    schedule_conditions = TriggerCondition.schedule
    assert schedule_conditions.all? { |c| c.condition_type == "schedule" }
    assert schedule_conditions.count > 0
  end

  test "ao_event scope returns only ao_event conditions" do
    ao_event_conditions = TriggerCondition.ao_event
    assert ao_event_conditions.all? { |c| c.condition_type == "ao_event" }
    assert ao_event_conditions.count > 0
  end

  # Configuration accessors
  test "channel_id returns channel_id from configuration" do
    assert_equal "C0A6BF8T45R", @slack_condition.channel_id
  end

  test "channel_name returns channel_name from configuration" do
    assert_equal "eng-ci", @slack_condition.channel_name
  end

  test "event_type returns event_type from configuration with default" do
    assert_equal "new_message", @slack_condition.event_type

    @slack_condition.configuration["event_type"] = nil
    assert_equal "new_message", @slack_condition.event_type
  end

  test "schedule_interval returns interval from configuration" do
    assert_equal 1, @schedule_condition.schedule_interval
  end

  test "schedule_unit returns unit from configuration" do
    assert_equal "days", @schedule_condition.schedule_unit
  end

  test "schedule_time returns time from configuration" do
    assert_equal "09:00", @schedule_condition.schedule_time
  end

  test "schedule_day_of_week returns day from configuration" do
    assert_equal "monday", @weekly_condition.schedule_day_of_week
  end

  test "schedule_timezone returns timezone with default" do
    assert_equal "Eastern Time (US & Canada)", @schedule_condition.schedule_timezone

    @schedule_condition.configuration.delete("timezone")
    assert_equal "UTC", @schedule_condition.schedule_timezone
  end

  test "ao_event_name returns event_name from configuration" do
    assert_equal "session_needs_input", @ao_event_condition.ao_event_name
  end

  # Schedule description
  test "schedule_description for minutes" do
    @schedule_condition.configuration = { "unit" => "minutes", "interval" => 15 }
    assert_equal "Every 15 minutes", @schedule_condition.schedule_description
  end

  test "schedule_description for single minute unit" do
    @schedule_condition.configuration = { "unit" => "minutes", "interval" => 1 }
    assert_equal "Every minute", @schedule_condition.schedule_description
  end

  test "schedule_description for daily" do
    assert_equal "Every day at 09:00 (Eastern Time (US & Canada))", @schedule_condition.schedule_description
  end

  test "schedule_description for multiple days" do
    @schedule_condition.configuration = { "unit" => "days", "interval" => 3, "time" => "09:00", "timezone" => "UTC" }
    assert_equal "Every 3 days at 09:00 (UTC)", @schedule_condition.schedule_description
  end

  test "schedule_description for weekly" do
    assert_equal "Every week on Monday at 10:00 (Pacific Time (US & Canada))", @weekly_condition.schedule_description
  end

  test "schedule_description for one-time schedule" do
    travel_to Time.zone.parse("2026-04-10 12:00:00 UTC") do
      desc = @one_time_condition.schedule_description
      assert_match(/Once at 2026-04-15 14:30/, desc)
      assert_match(/America\/New_York/, desc)
    end
  end

  test "schedule_description returns nil for non-schedule" do
    assert_nil @slack_condition.schedule_description
  end

  # Description (human-readable for any type)
  test "description for slack condition" do
    assert_equal "Slack: #eng-ci", @slack_condition.description
  end

  test "description for schedule condition" do
    desc = @schedule_condition.description
    assert_includes desc, "Every day at 09:00"
  end

  test "description for ao_event condition" do
    assert_equal "Zimmer Event: Session needs input", @ao_event_condition.description
  end

  # Schedule due?
  test "schedule_due? returns false for non-schedule conditions" do
    assert_not @slack_condition.schedule_due?
  end

  test "schedule_due? returns false for disabled schedule conditions" do
    condition = trigger_conditions(:disabled_schedule_condition)
    assert_not condition.schedule_due?
  end

  # An interval schedule names no wall-clock instant to wait for, so "never fired"
  # really does mean "due now" — the first fire is what anchors the interval. This
  # and its `hours` twin guard the half of the case statement #447 must NOT change:
  # the clock is pinned to the arbitrary hour the daily regression defers at.
  test "schedule_due? returns true when never triggered for minutes" do
    @schedule_condition.configuration = { "unit" => "minutes", "interval" => 15 }
    @schedule_condition.last_triggered_at = nil
    travel_to Time.utc(2026, 5, 12, 11, 49) do
      assert @schedule_condition.schedule_due?
    end
  end

  test "schedule_due? returns true when enough time has passed for minutes" do
    @schedule_condition.configuration = { "unit" => "minutes", "interval" => 15 }
    @schedule_condition.last_triggered_at = 16.minutes.ago
    assert @schedule_condition.schedule_due?
  end

  test "schedule_due? returns false when not enough time for minutes" do
    @schedule_condition.configuration = { "unit" => "minutes", "interval" => 15 }
    @schedule_condition.last_triggered_at = 10.minutes.ago
    assert_not @schedule_condition.schedule_due?
  end

  test "schedule_due? returns true when never triggered for hours" do
    @schedule_condition.configuration = { "unit" => "hours", "interval" => 2 }
    @schedule_condition.last_triggered_at = nil
    travel_to Time.utc(2026, 5, 12, 11, 49) do
      assert @schedule_condition.schedule_due?
    end
  end

  test "schedule_due? returns true when enough time has passed for hours" do
    @schedule_condition.configuration = { "unit" => "hours", "interval" => 2 }
    @schedule_condition.last_triggered_at = 3.hours.ago
    assert @schedule_condition.schedule_due?
  end

  test "schedule_due? returns false when not enough time for hours" do
    @schedule_condition.configuration = { "unit" => "hours", "interval" => 2 }
    @schedule_condition.last_triggered_at = 1.hour.ago
    assert_not @schedule_condition.schedule_due?
  end

  # A never-fired daily/weekly schedule waits for its configured wall-clock slot.
  #
  # The regression these pin down (#447): a nil last_triggered_at used to short-circuit
  # to "due" before the configured time was ever consulted, so a schedule created at
  # 11:35 UTC fired on the next minute's tick at 11:49 UTC — and, because a fire advances
  # last_triggered_at, silently consumed the 03:00 slot it was created for.
  #
  # 2026-05-11 is a Monday and 2026-05-12 a Tuesday; America/Los_Angeles is UTC-7 in May.

  test "schedule_due? is false for a never-triggered daily schedule before its configured time" do
    condition = fresh_daily_condition(armed_at: Time.utc(2026, 5, 12, 8, 0)) # 01:00 PT
    travel_to Time.utc(2026, 5, 12, 9, 59) do # 02:59 PT, one minute before the 03:00 slot
      assert_not condition.schedule_due?
    end
  end

  test "schedule_due? is true for a never-triggered daily schedule once its configured time arrives" do
    condition = fresh_daily_condition(armed_at: Time.utc(2026, 5, 12, 8, 0)) # 01:00 PT
    travel_to Time.utc(2026, 5, 12, 10, 0) do # 03:00 PT exactly
      assert condition.schedule_due?
    end
  end

  # The production report: two daily triggers created at ~11:35 UTC (04:35 PT) fired at
  # ~11:49 UTC instead of at their 03:00 PT slot. The slot had already passed when the
  # schedule was created, so it was not missed — the first run belongs to the next day.
  test "schedule_due? defers a daily schedule created after its configured time to the next day" do
    condition = fresh_daily_condition(armed_at: Time.utc(2026, 5, 12, 11, 35)) # 04:35 PT

    travel_to Time.utc(2026, 5, 12, 11, 49) do # 04:49 PT — the observed premature fire
      assert_not condition.schedule_due?, "must not fire on the same day the slot already passed"
    end

    travel_to Time.utc(2026, 5, 12, 18, 0) do # 11:00 PT, still the day of creation
      assert_not condition.schedule_due?
    end

    travel_to Time.utc(2026, 5, 13, 10, 0) do # 03:00 PT the next day
      assert condition.schedule_due?, "the first run is the next configured slot after creation"
    end
  end

  # The configured time is wall-clock in the condition's own timezone. Reading "03:00"
  # against UTC would make this pair indistinguishable — the first instant is hours past
  # 03:00 UTC and the schedule is still not due, because in Los Angeles it is 02:05.
  test "schedule_due? reads the configured time in the condition's timezone, not UTC" do
    condition = fresh_daily_condition(armed_at: Time.utc(2026, 5, 12, 5, 0)) # 05-11 22:00 PT

    travel_to Time.utc(2026, 5, 12, 9, 5) do # 02:05 PT — but 09:05 UTC, long past 03:00 UTC
      assert_not condition.schedule_due?
    end

    travel_to Time.utc(2026, 5, 12, 10, 0) do # 03:00 PT
      assert condition.schedule_due?
    end
  end

  # An interval > 1 has no meaning before the first fire — there is no previous run to count
  # from — so the first fire is the next configured slot and it becomes the anchor the interval
  # is measured from. "Every 3 days at 03:00" created at 01:00 runs two hours later, not in
  # three days.
  test "schedule_due? ignores the interval on a first fire and anchors on it thereafter" do
    @schedule_condition.update!(
      configuration: { "unit" => "days", "interval" => 3, "time" => "03:00",
                      "timezone" => "America/Los_Angeles" },
      last_triggered_at: nil,
      created_at: Time.utc(2026, 5, 12, 8, 0), # 01:00 PT the same day
      armed_at: Time.utc(2026, 5, 12, 8, 0)
    )

    travel_to Time.utc(2026, 5, 12, 10, 0) do # 03:00 PT, two hours after creation
      assert @schedule_condition.schedule_due?
    end

    @schedule_condition.update!(last_triggered_at: Time.utc(2026, 5, 12, 10, 0))

    travel_to Time.utc(2026, 5, 14, 10, 0) do # two days later, interval not yet elapsed
      assert_not @schedule_condition.schedule_due?
    end

    travel_to Time.utc(2026, 5, 15, 10, 0) do # three days later
      assert @schedule_condition.schedule_due?
    end
  end

  # The boundary is strict: a schedule created in the same minute as its slot, but a second
  # after it, waits for tomorrow rather than firing into a slot it did not exist for.
  test "schedule_due? treats a schedule created exactly at its slot as having missed it" do
    condition = fresh_daily_condition(armed_at: Time.utc(2026, 5, 12, 10, 0)) # 03:00 PT exactly

    travel_to Time.utc(2026, 5, 12, 10, 1) do
      assert_not condition.schedule_due?
    end

    travel_to Time.utc(2026, 5, 13, 10, 0) do
      assert condition.schedule_due?
    end
  end

  test "schedule_due? is false for a never-triggered weekly schedule before its configured time" do
    condition = fresh_weekly_condition(armed_at: Time.utc(2026, 5, 4, 8, 0)) # Mon a week earlier
    travel_to Time.utc(2026, 5, 11, 16, 59) do # Monday 09:59 PT, before the 10:00 slot
      assert_not condition.schedule_due?
    end
  end

  test "schedule_due? is true for a never-triggered weekly schedule once its configured time arrives" do
    condition = fresh_weekly_condition(armed_at: Time.utc(2026, 5, 4, 8, 0))
    travel_to Time.utc(2026, 5, 11, 17, 0) do # Monday 10:00 PT exactly
      assert condition.schedule_due?
    end
  end

  test "schedule_due? is false for a never-triggered weekly schedule on the wrong day" do
    condition = fresh_weekly_condition(armed_at: Time.utc(2026, 5, 4, 8, 0))
    travel_to Time.utc(2026, 5, 12, 20, 0) do # Tuesday 13:00 PT — past the time, wrong day
      assert_not condition.schedule_due?
    end
  end

  test "schedule_due? defers a weekly schedule created after its configured time to the next week" do
    condition = fresh_weekly_condition(armed_at: Time.utc(2026, 5, 11, 18, 0)) # Mon 11:00 PT

    travel_to Time.utc(2026, 5, 11, 19, 0) do # the same Monday, 12:00 PT
      assert_not condition.schedule_due?
    end

    travel_to Time.utc(2026, 5, 18, 17, 0) do # the following Monday, 10:00 PT
      assert condition.schedule_due?
    end
  end

  # --- Arming (#745) -------------------------------------------------------
  #
  # `armed_at` is what #armed_before? measures a never-fired days/weeks schedule's
  # first fire from. #743 used `created_at`, which made creation the only arming
  # instant: an edit that MOVED the slot, or an enable that made the condition live
  # after the slot had passed, left it reading as armed for a slot it was never live
  # for — and it fired once at whatever hour that was, consuming the configured run.
  #
  # Dates as above: 2026-05-11 is a Monday, 2026-05-12 a Tuesday, and
  # America/Los_Angeles is UTC-7 in May.

  test "a new condition is armed at creation" do
    condition = travel_to Time.utc(2026, 5, 12, 8, 0) do
      @schedule_condition.trigger.trigger_conditions.create!(
        condition_type: "schedule",
        configuration: { "unit" => "days", "interval" => 1, "time" => "03:00",
                        "timezone" => "America/Los_Angeles" }
      )
    end

    assert_equal Time.utc(2026, 5, 12, 8, 0), condition.reload.armed_at
  end

  # Scenario 2 of #745. "Every day at 23:00" created at 08:00 is correctly not due;
  # retimed to 09:00 at 10:00, it used to fire at 10:00 because created_at (08:00)
  # was still before today's 09:00 slot. The condition never existed with a 09:00
  # slot at the moment 09:00 passed, so its first run is 09:00 tomorrow.
  test "editing a never-fired schedule's time re-arms it against the new slot" do
    @schedule_condition.update!(
      configuration: { "unit" => "days", "interval" => 1, "time" => "23:00",
                      "timezone" => "America/Los_Angeles" },
      last_triggered_at: nil,
      created_at: Time.utc(2026, 5, 12, 15, 0), # 08:00 PT
      armed_at: Time.utc(2026, 5, 12, 15, 0)
    )

    travel_to Time.utc(2026, 5, 12, 17, 0) do # 10:00 PT — the retiming edit
      @schedule_condition.update!(
        configuration: @schedule_condition.configuration.merge("time" => "09:00")
      )
    end

    assert_equal Time.utc(2026, 5, 12, 17, 0), @schedule_condition.reload.armed_at,
      "moving the slot re-arms the condition against it"

    travel_to Time.utc(2026, 5, 12, 17, 1) do # 10:01 PT, a minute after the edit
      assert_not @schedule_condition.schedule_due?,
        "the 09:00 slot passed before this schedule had a 09:00 slot"
    end

    travel_to Time.utc(2026, 5, 13, 16, 0) do # 09:00 PT the next day
      assert @schedule_condition.schedule_due?
    end
  end

  test "editing a never-fired weekly schedule's day_of_week re-arms it" do
    condition = fresh_weekly_condition(armed_at: Time.utc(2026, 5, 4, 8, 0)) # Mon a week earlier

    travel_to Time.utc(2026, 5, 12, 20, 0) do # Tuesday 13:00 PT — past the 10:00 slot
      condition.update!(configuration: condition.configuration.merge("day_of_week" => "tuesday"))
      assert_not condition.schedule_due?,
        "Tuesday's 10:00 slot passed before this schedule named Tuesday"
    end

    travel_to Time.utc(2026, 5, 19, 17, 0) do # the following Tuesday, 10:00 PT
      assert condition.schedule_due?
    end
  end

  # Changing the timezone moves the slot in wall-clock terms exactly as changing the
  # time does — "03:00 UTC" and "03:00 America/Los_Angeles" are seven hours apart —
  # so it re-arms for the same reason.
  test "editing a never-fired schedule's timezone re-arms it against the new slot" do
    condition = fresh_daily_condition(armed_at: Time.utc(2026, 5, 12, 1, 0)) # 05-11 18:00 PT

    travel_to Time.utc(2026, 5, 12, 9, 0) do # 02:00 PT — before the 03:00 PT slot it was armed for
      condition.update!(configuration: condition.configuration.merge("timezone" => "UTC"))
      assert_not condition.schedule_due?,
        "03:00 UTC passed eight hours before the edit; the condition was not on UTC for it"
    end

    travel_to Time.utc(2026, 5, 13, 3, 0) do # 03:00 UTC the next day
      assert condition.schedule_due?
    end
  end

  # The crux of #745, and the reason arming is keyed on a scope diff rather than on
  # `updated_at`. Saving the trigger form again with nothing changed must leave a
  # pending first fire exactly where it was — a re-arm here would push it out a day
  # every time anyone pressed Save, which is #447's skipped slot in another costume.
  test "a no-op re-save does not re-arm a pending first fire" do
    condition = fresh_daily_condition(armed_at: Time.utc(2026, 5, 12, 8, 0)) # 01:00 PT

    travel_to Time.utc(2026, 5, 12, 9, 0) do # 02:00 PT, an hour before the slot
      condition.save!
      condition.update!(configuration: condition.configuration.dup)
    end

    assert_equal Time.utc(2026, 5, 12, 8, 0), condition.reload.armed_at,
      "a save that changes nothing is not an arming"

    travel_to Time.utc(2026, 5, 12, 10, 0) do # 03:00 PT — the run it was created for
      assert condition.schedule_due?
    end
  end

  # The form rebuilds the whole `configuration` hash, so "nothing changed" at the UI
  # is routinely a dirty `configuration` at the model — and a condition created
  # through `action_trigger` without a `timezone` comes back from the form carrying
  # "UTC", because the select renders #schedule_timezone's default and submits it.
  # Comparing raw keys would read that as a moved slot and defer the pending run by a
  # day, which is the #447 slot-skip this whole mechanism exists to prevent.
  test "a save that only materialises the default timezone does not re-arm" do
    @schedule_condition.update!(
      configuration: { "unit" => "days", "interval" => 1, "time" => "03:00" }, # no timezone
      last_triggered_at: nil,
      created_at: Time.utc(2026, 5, 12, 1, 0),
      armed_at: Time.utc(2026, 5, 12, 1, 0)
    )

    travel_to Time.utc(2026, 5, 12, 2, 0) do # an hour before the 03:00 UTC slot
      @schedule_condition.update!(
        configuration: @schedule_condition.configuration.merge("timezone" => "UTC")
      )
    end

    assert_equal Time.utc(2026, 5, 12, 1, 0), @schedule_condition.reload.armed_at,
      "writing the timezone the condition was already read in is not a moved slot"

    travel_to Time.utc(2026, 5, 12, 3, 0) do # 03:00 UTC — the run it was armed for
      assert @schedule_condition.schedule_due?
    end
  end

  # An edit that leaves the slot where it is is a no-op as far as arming goes, even
  # though the configuration changed. `interval` is the case that matters: it has no
  # meaning before a first fire, so re-arming on it would defer a pending run for a
  # setting that cannot affect it.
  test "changing a non-arming key does not re-arm a pending first fire" do
    condition = fresh_daily_condition(armed_at: Time.utc(2026, 5, 12, 8, 0)) # 01:00 PT

    travel_to Time.utc(2026, 5, 12, 9, 0) do # 02:00 PT
      condition.update!(configuration: condition.configuration.merge("interval" => 3))
    end

    assert_equal Time.utc(2026, 5, 12, 8, 0), condition.reload.armed_at

    travel_to Time.utc(2026, 5, 12, 10, 0) do # 03:00 PT, as originally armed
      assert condition.schedule_due?
    end
  end

  # A schedule that has fired is governed by `last_triggered_at`, and #armed_before?
  # is never reached. Re-arming it — by a retiming edit here — must not change when
  # it next runs.
  test "arming does not govern a schedule that has already fired" do
    condition = fresh_daily_condition(armed_at: Time.utc(2026, 5, 12, 8, 0))
    condition.update!(
      configuration: condition.configuration.merge("interval" => 3),
      last_triggered_at: Time.utc(2026, 5, 12, 10, 0) # fired at 03:00 PT
    )

    travel_to Time.utc(2026, 5, 13, 10, 0) do # the next day — one day of three elapsed
      condition.update!(configuration: condition.configuration.merge("time" => "03:00"))
      assert_not condition.schedule_due?, "a re-arm must not shorten the interval"
    end

    travel_to Time.utc(2026, 5, 15, 10, 0) do # three days after the fire
      assert condition.schedule_due?, "a re-arm must not lengthen the interval either"
    end
  end

  # The backfill's safety net. A row written before `armed_at` existed and somehow
  # missed by the migration reads exactly as it did under #743 rather than as
  # "armed" — the old behaviour, not a new off-slot fire.
  test "a condition with no armed_at falls back to created_at" do
    condition = fresh_daily_condition(armed_at: Time.utc(2026, 5, 12, 11, 35)) # 04:35 PT
    condition.update_columns(armed_at: nil)

    travel_to Time.utc(2026, 5, 12, 11, 49) do # 04:49 PT — #447's premature fire
      assert_not condition.reload.schedule_due?
    end

    travel_to Time.utc(2026, 5, 13, 10, 0) do # 03:00 PT the next day
      assert condition.schedule_due?
    end
  end

  # Arming is a schedule concept. A Slack condition carries an `armed_at` because
  # every row gets one on create, but nothing reads it, and editing what it watches
  # is not an arming.
  test "a non-schedule condition is armed on create and not re-armed by an edit" do
    condition = travel_to Time.utc(2026, 5, 12, 8, 0) do
      @slack_condition.trigger.trigger_conditions.create!(
        condition_type: "slack",
        configuration: { "channel_id" => "C0C8DF0T67T", "channel_name" => "eng-releases",
                        "event_type" => "new_message" }
      )
    end
    assert_equal Time.utc(2026, 5, 12, 8, 0), condition.reload.armed_at

    travel_to Time.utc(2026, 5, 12, 9, 0) do
      condition.update!(configuration: condition.configuration.merge("channel_name" => "eng-deploys"))
    end

    assert_equal Time.utc(2026, 5, 12, 8, 0), condition.reload.armed_at
  end

  test "schedule_due? returns true when enough days have passed" do
    @schedule_condition.configuration = { "unit" => "days", "interval" => 3, "time" => "09:00", "timezone" => "UTC" }
    travel_to Time.zone.parse("2026-02-20 10:00:00 UTC") do
      @schedule_condition.last_triggered_at = Time.zone.parse("2026-02-17 09:00:00 UTC")
      assert @schedule_condition.schedule_due?
    end
  end

  test "schedule_due? returns false when not enough days have passed" do
    @schedule_condition.configuration = { "unit" => "days", "interval" => 3, "time" => "09:00", "timezone" => "UTC" }
    travel_to Time.zone.parse("2026-02-19 10:00:00 UTC") do
      @schedule_condition.last_triggered_at = Time.zone.parse("2026-02-17 09:00:00 UTC")
      assert_not @schedule_condition.schedule_due?
    end
  end

  test "schedule_due? returns true when enough weeks have passed" do
    @weekly_condition.configuration = { "unit" => "weeks", "interval" => 2, "time" => "10:00",
                                        "day_of_week" => "monday", "timezone" => "UTC" }
    travel_to Time.zone.parse("2026-02-23 10:30:00 UTC") do
      @weekly_condition.last_triggered_at = Time.zone.parse("2026-02-09 10:00:00 UTC")
      assert @weekly_condition.schedule_due?
    end
  end

  test "schedule_due? returns false when not enough weeks have passed" do
    @weekly_condition.configuration = { "unit" => "weeks", "interval" => 2, "time" => "10:00",
                                        "day_of_week" => "monday", "timezone" => "UTC" }
    travel_to Time.zone.parse("2026-02-16 10:30:00 UTC") do
      @weekly_condition.last_triggered_at = Time.zone.parse("2026-02-09 10:00:00 UTC")
      assert_not @weekly_condition.schedule_due?
    end
  end

  test "schedule_due? returns false on wrong day of week" do
    travel_to Time.zone.parse("2026-02-24 10:30:00 UTC") do
      @weekly_condition.last_triggered_at = Time.zone.parse("2026-02-09 10:00:00 UTC")
      assert_not @weekly_condition.schedule_due?
    end
  end

  test "schedule_due? returns false when already triggered today for daily interval" do
    @schedule_condition.configuration = { "unit" => "days", "interval" => 1, "time" => "09:00", "timezone" => "UTC" }
    travel_to Time.zone.parse("2026-02-20 09:05:00 UTC") do
      @schedule_condition.last_triggered_at = Time.zone.parse("2026-02-20 09:00:00 UTC")
      assert_not @schedule_condition.schedule_due?
    end
  end

  test "schedule_due? returns false for invalid timezone" do
    @schedule_condition.configuration = { "unit" => "days", "interval" => 1, "time" => "09:00", "timezone" => "Invalid/Timezone" }
    @schedule_condition.last_triggered_at = nil
    assert_not @schedule_condition.schedule_due?
  end

  # One-time schedule_due? tests
  test "schedule_due? returns true for one-time schedule when time has passed and never triggered" do
    travel_to Time.zone.parse("2026-04-15 19:00:00 UTC") do
      @one_time_condition.last_triggered_at = nil
      assert @one_time_condition.schedule_due?
    end
  end

  test "schedule_due? returns false for one-time schedule when time has not arrived" do
    travel_to Time.zone.parse("2026-04-15 10:00:00 UTC") do
      @one_time_condition.last_triggered_at = nil
      assert_not @one_time_condition.schedule_due?
    end
  end

  test "schedule_due? returns false for one-time schedule when already triggered" do
    travel_to Time.zone.parse("2026-04-16 12:00:00 UTC") do
      @one_time_condition.last_triggered_at = Time.zone.parse("2026-04-15 19:00:00 UTC")
      assert_not @one_time_condition.schedule_due?
    end
  end

  # Bot mention condition tests
  test "bot_mention condition is valid with channel_id" do
    condition = trigger_conditions(:bot_mention_slack_condition)
    assert condition.valid?
    assert_equal "bot_mention", condition.event_type
  end

  test "bot_mention condition is valid without channel_id" do
    condition = trigger_conditions(:bot_mention_slack_condition)
    condition.configuration.delete("channel_id")
    condition.configuration.delete("channel_name")
    assert condition.valid?
  end

  test "bot_mention condition accepts bot_mention event_type" do
    @slack_condition.configuration["event_type"] = "bot_mention"
    assert @slack_condition.valid?
  end

  # Passive listening condition tests
  test "every passive-listening event type is valid with or without a channel_id" do
    condition = trigger_conditions(:passive_listen_all_channels_condition)

    %w[passive_listen_thread passive_listen_channel passive_listen].each do |event_type|
      condition.configuration["event_type"] = event_type
      condition.configuration.delete("channel_id")
      assert condition.valid?, "#{event_type} should be valid without a channel_id"

      condition.configuration["channel_id"] = "C_GENERAL"
      assert condition.valid?, "#{event_type} should be valid with a channel_id"
    end
  end

  test "the two passive halves select their own signal, and the deprecated type selects both" do
    condition = trigger_conditions(:passive_listen_all_channels_condition)

    condition.configuration["event_type"] = "passive_listen_thread"
    assert condition.passive_listen?
    assert condition.passive_threads?
    assert_not condition.passive_channel?
    assert_not condition.deprecated_event_type?

    condition.configuration["event_type"] = "passive_listen_channel"
    assert condition.passive_listen?
    assert_not condition.passive_threads?
    assert condition.passive_channel?
    assert_not condition.deprecated_event_type?

    condition.configuration["event_type"] = "passive_listen"
    assert condition.passive_listen?
    assert condition.passive_threads?
    assert condition.passive_channel?
    assert condition.deprecated_event_type?
  end

  test "passive_listen? is false for other event types" do
    assert_not @slack_condition.passive_listen?
    assert_not @slack_condition.passive_threads?
    assert_not @slack_condition.passive_channel?
    assert_not trigger_conditions(:bot_mention_slack_condition).passive_listen?
  end

  test "description distinguishes the passive-listening event types" do
    condition = trigger_conditions(:passive_listen_all_channels_condition)

    condition.configuration["event_type"] = "passive_listen_thread"
    assert_equal "Slack: replies in threads Zimmer joined, in all channels", condition.description

    condition.configuration["event_type"] = "passive_listen_channel"
    assert_equal "Slack: messages in all channels Zimmer posted in recently", condition.description

    condition.configuration["event_type"] = "passive_listen"
    assert_equal "Slack: passive listening (deprecated: threads + channels) in all channels", condition.description

    condition.configuration["event_type"] = "passive_listen_thread"
    condition.configuration["channel_name"] = "general"
    assert_equal "Slack: replies in threads Zimmer joined, in #general", condition.description
  end

  test "bot_activity_timestamps returns empty hash by default and stored values when set" do
    condition = trigger_conditions(:passive_listen_all_channels_condition)
    assert_equal({}, condition.bot_activity_timestamps)

    condition.configuration["bot_activity_timestamps"] = { "C123" => "1234.000" }
    assert_equal({ "C123" => "1234.000" }, condition.bot_activity_timestamps)
  end

  test "new_message condition requires channel_id" do
    @slack_condition.configuration.delete("channel_id")
    assert_not @slack_condition.valid?
    assert_includes @slack_condition.errors[:configuration], "must include channel_id for Slack conditions"
  end

  # An unconfigured Zimmer lets ANY workspace member @mention or DM the bot. The old
  # behavior -- a hard-coded pair of Slack user IDs ported from another workspace --
  # meant a fresh install silently ignored everyone, including its own owner.
  test "allowed_user_ids is empty by default, meaning everyone is allowed" do
    condition = trigger_conditions(:bot_mention_slack_condition)

    # nil == the deployment sets no allow-list at all. Stated, not inherited: this
    # asserts the default, so it must not read the allow-list of whatever box the
    # suite happens to run on.
    with_allowed_user_ids_secret(nil) do
      assert_empty condition.allowed_user_ids
      assert condition.allow_all_users?
      assert condition.user_allowed?("U_ANYONE")
    end
  end

  test "SLACK_BOT_MENTION_ALLOWED_USER_IDS restricts to exactly those users" do
    condition = trigger_conditions(:bot_mention_slack_condition)

    with_allowed_user_ids_secret("U111,U222") do
      assert_equal %w[U111 U222], condition.allowed_user_ids
      assert_not condition.allow_all_users?
      assert condition.user_allowed?("U111")
      assert_not condition.user_allowed?("U_NOT_ON_THE_LIST")
    end
  end

  # Nothing else in the suite drives the ENV half of default_allowed_user_ids, so
  # without this the `|| ENV[...]` fallback could be deleted and every test would stay
  # green -- and a deployment that configures the allow-list as a plain environment
  # variable rather than a credential would silently stop being restricted.
  test "the allow-list resolves the credential first and process ENV second" do
    condition = trigger_conditions(:bot_mention_slack_condition)

    with_allowed_user_ids_secret(nil, env: "U111,U222") do
      assert_equal %w[U111 U222], TriggerCondition.default_allowed_user_ids
      assert_equal %w[U111 U222], condition.allowed_user_ids
      assert_not condition.user_allowed?("U_NOT_ON_THE_LIST")
    end

    with_allowed_user_ids_secret("U333", env: "U111,U222") do
      assert_equal %w[U333], TriggerCondition.default_allowed_user_ids
    end
  end

  test "SLACK_BOT_MENTION_ALLOWED_USER_IDS tolerates whitespace and empty entries" do
    condition = trigger_conditions(:bot_mention_slack_condition)

    with_allowed_user_ids_secret(" U111 , ,U222,") do
      assert_equal %w[U111 U222], condition.allowed_user_ids
    end
  end

  # Blank must mean "everyone", not "nobody" -- SecretsInterpolator treats a
  # blank-but-set secret as set, so this is the difference between an open default
  # and a bot that silently answers no one.
  test "a blank SLACK_BOT_MENTION_ALLOWED_USER_IDS allows everyone" do
    condition = trigger_conditions(:bot_mention_slack_condition)

    with_allowed_user_ids_secret("   ") do
      assert condition.allow_all_users?
      assert condition.user_allowed?("U_ANYONE")
    end
  end

  test "a condition's own allowed_user_ids overrides the deployment-wide allow-list" do
    condition = trigger_conditions(:bot_mention_slack_condition)
    condition.configuration["allowed_user_ids"] = %w[U111 U222]

    with_allowed_user_ids_secret("U999") do
      assert_equal %w[U111 U222], condition.allowed_user_ids
      assert condition.user_allowed?("U111")
      assert_not condition.user_allowed?("U999")
    end
  end

  test "user_allowed? rejects a blank user id even when everyone is allowed" do
    condition = trigger_conditions(:bot_mention_slack_condition)

    # "everyone is allowed" is the premise of this test, so it has to be set here
    # rather than borrowed from the environment.
    with_allowed_user_ids_secret(nil) do
      assert condition.allow_all_users?
      assert_not condition.user_allowed?(nil)
      assert_not condition.user_allowed?("")
    end
  end

  test "dm_timestamps returns empty hash by default" do
    condition = trigger_conditions(:bot_mention_slack_condition)
    assert_equal({}, condition.dm_timestamps)
  end

  test "dm_timestamps returns stored timestamps" do
    condition = trigger_conditions(:bot_mention_slack_condition)
    condition.configuration["dm_timestamps"] = { "U111" => "1234.000" }
    assert_equal({ "U111" => "1234.000" }, condition.dm_timestamps)
  end

  test "update_dm_timestamp! persists DM timestamp for a user" do
    condition = trigger_conditions(:bot_mention_slack_condition)
    condition.update_dm_timestamp!("U111", "1234.567")
    condition.reload
    assert_equal "1234.567", condition.dm_timestamps["U111"]
  end

  test "update_dm_timestamp! preserves other DM timestamps" do
    condition = trigger_conditions(:bot_mention_slack_condition)
    condition.configuration["dm_timestamps"] = { "U111" => "1000.000" }
    condition.save!
    condition.update_dm_timestamp!("U222", "2000.000")
    condition.reload
    assert_equal "1000.000", condition.dm_timestamps["U111"]
    assert_equal "2000.000", condition.dm_timestamps["U222"]
  end

  test "description for bot_mention condition with channel" do
    condition = trigger_conditions(:bot_mention_slack_condition)
    assert_equal "Slack: @mention in #eng-support + DMs", condition.description
  end

  test "description for bot_mention condition without channel" do
    condition = trigger_conditions(:bot_mention_slack_condition)
    condition.configuration.delete("channel_id")
    condition.configuration.delete("channel_name")
    assert_equal "Slack: @mention in all channels + DMs", condition.description
  end

  test "channel_timestamps returns empty hash by default" do
    condition = trigger_conditions(:bot_mention_all_channels_condition)
    assert_equal({}, condition.channel_timestamps)
  end

  test "channel_timestamps returns stored timestamps" do
    condition = trigger_conditions(:bot_mention_all_channels_condition)
    condition.configuration["channel_timestamps"] = { "C123" => "1234.000" }
    assert_equal({ "C123" => "1234.000" }, condition.channel_timestamps)
  end

  test "update_channel_timestamp! persists channel timestamp" do
    condition = trigger_conditions(:bot_mention_all_channels_condition)
    condition.update_channel_timestamp!("C123", "1234.567")
    condition.reload
    assert_equal "1234.567", condition.channel_timestamps["C123"]
  end

  test "update_channel_timestamp! preserves other channel timestamps" do
    condition = trigger_conditions(:bot_mention_all_channels_condition)
    condition.configuration["channel_timestamps"] = { "C111" => "1000.000" }
    condition.save!
    condition.update_channel_timestamp!("C222", "2000.000")
    condition.reload
    assert_equal "1000.000", condition.channel_timestamps["C111"]
    assert_equal "2000.000", condition.channel_timestamps["C222"]
  end

  test "thread_timestamps returns empty hash by default" do
    condition = trigger_conditions(:bot_mention_all_channels_condition)
    assert_equal({}, condition.thread_timestamps)
  end

  test "thread_timestamps returns stored timestamps" do
    condition = trigger_conditions(:bot_mention_all_channels_condition)
    condition.configuration["thread_timestamps"] = { "C123:1234.000" => "1234.999" }
    assert_equal({ "C123:1234.000" => "1234.999" }, condition.thread_timestamps)
  end

  # mark_polled!
  test "mark_polled! updates last_polled_at" do
    @slack_condition.mark_polled!
    assert_in_delta Time.current, @slack_condition.last_polled_at, 1.second
  end

  test "mark_polled! updates last_message_ts when provided" do
    @slack_condition.mark_polled!(message_ts: "1704153600.000000")
    assert_equal "1704153600.000000", @slack_condition.last_message_ts
  end

  # ── GitHub conditions ─────────────────────────────────────────────────────

  def github_label_config(overrides = {})
    { "repos" => [ "tadasant/zimmer" ], "target" => "pull_request", "labels" => [ "ready to merge" ] }.merge(overrides)
  end

  test "github_label condition is valid with repos, target and labels" do
    condition = TriggerCondition.new(
      trigger: triggers(:enabled_slack_trigger),
      condition_type: "github_label",
      configuration: github_label_config
    )

    assert condition.valid?, condition.errors.full_messages.to_sentence
    assert_equal [ "tadasant/zimmer" ], condition.github_repos
    assert_equal [ "ready to merge" ], condition.github_labels
    assert condition.github_pull_requests?
  end

  test "github_issue condition needs only repos" do
    condition = TriggerCondition.new(
      trigger: triggers(:enabled_slack_trigger),
      condition_type: "github_issue",
      configuration: { "repos" => [ "tadasant/zimmer" ] }
    )

    assert condition.valid?, condition.errors.full_messages.to_sentence
  end

  test "github condition requires at least one repo" do
    condition = TriggerCondition.new(
      trigger: triggers(:enabled_slack_trigger),
      condition_type: "github_issue",
      configuration: { "repos" => [] }
    )

    assert_not condition.valid?
    assert_match(/at least one repo/, condition.errors[:configuration].to_sentence)
  end

  test "github condition rejects repos that are not owner/name" do
    condition = TriggerCondition.new(
      trigger: triggers(:enabled_slack_trigger),
      condition_type: "github_issue",
      configuration: { "repos" => [ "zimmer", "tadasant/zimmer" ] }
    )

    assert_not condition.valid?
    assert_match(/owner\/name format/, condition.errors[:configuration].to_sentence)
  end

  test "github condition rejects more repos than one search query can carry" do
    repos = Array.new(TriggerCondition::MAX_GITHUB_REPOS + 1) { |i| "owner/repo-#{i}" }
    condition = TriggerCondition.new(
      trigger: triggers(:enabled_slack_trigger),
      condition_type: "github_issue",
      configuration: { "repos" => repos }
    )

    assert_not condition.valid?
    assert_match(/at most #{TriggerCondition::MAX_GITHUB_REPOS} repos/, condition.errors[:configuration].to_sentence)
  end

  test "github_label condition requires at least one label" do
    condition = TriggerCondition.new(
      trigger: triggers(:enabled_slack_trigger),
      condition_type: "github_label",
      configuration: github_label_config("labels" => [])
    )

    assert_not condition.valid?
    assert_match(/at least one label/, condition.errors[:configuration].to_sentence)
  end

  test "github_label condition rejects an unknown target" do
    condition = TriggerCondition.new(
      trigger: triggers(:enabled_slack_trigger),
      condition_type: "github_label",
      configuration: github_label_config("target" => "discussion")
    )

    assert_not condition.valid?
    assert_match(/target must be one of/, condition.errors[:configuration].to_sentence)
  end

  test "repos and labels submitted as newline-separated text are normalized to arrays" do
    # This is the shape the trigger form's textareas post: one array element with newlines.
    condition = TriggerCondition.create!(
      trigger: triggers(:enabled_slack_trigger),
      condition_type: "github_label",
      configuration: {
        "repos" => [ "tadasant/zimmer\n tadasant/zimmer-catalog \n\ntadasant/zimmer" ],
        "labels" => [ "ready to merge\nurgent" ],
        "target" => "pull_request"
      }
    )

    assert_equal [ "tadasant/zimmer", "tadasant/zimmer-catalog" ], condition.github_repos
    assert_equal [ "ready to merge", "urgent" ], condition.github_labels
  end

  test "github_issue conditions drop label fields the UI never showed them" do
    condition = TriggerCondition.create!(
      trigger: triggers(:enabled_slack_trigger),
      condition_type: "github_issue",
      configuration: { "repos" => [ "tadasant/zimmer" ], "labels" => [ "stale" ], "target" => "issue" }
    )

    assert_not condition.configuration.key?("labels")
    assert_not condition.configuration.key?("target")
  end

  test "github_issue exclusions are normalized from the form's newline-separated text" do
    condition = TriggerCondition.create!(
      trigger: triggers(:enabled_slack_trigger),
      condition_type: "github_issue",
      configuration: {
        "repos" => [ "tadasant/zimmer" ],
        "exclude_labels" => [ "hold issue work gate\n wip \n\nhold issue work gate" ]
      }
    )

    assert_equal [ "hold issue work gate", "wip" ], condition.github_exclude_labels
  end

  test "github_label conditions drop an exclusion list they would never consult" do
    condition = TriggerCondition.create!(
      trigger: triggers(:enabled_slack_trigger),
      condition_type: "github_label",
      configuration: github_label_config("exclude_labels" => [ "hold issue work gate" ])
    )

    assert_not condition.configuration.key?("exclude_labels")
    assert_empty condition.github_exclude_labels
  end

  test "a github_issue condition's description names what it excludes" do
    condition = trigger_conditions(:github_issue_condition)
    assert_equal "GitHub: new issue in tadasant/zimmer", condition.description

    condition.update!(configuration: condition.configuration.merge(
      "exclude_labels" => [ "hold issue work gate" ]
    ))

    assert_equal "GitHub: new issue in tadasant/zimmer, unless labelled 'hold issue work gate'",
                 condition.reload.description
  end

  # The blast radius of adding an exclusion to a LIVE condition: `exclude_labels` is
  # deliberately outside github_watch_scope, so an edit that only adds one must keep the
  # cursor. Losing it would re-baseline the condition and silently skip the issues opened
  # between the edit and the next tick.
  test "adding an exclusion keeps a github_issue condition's cursor" do
    condition = trigger_conditions(:github_issue_condition)
    condition.update!(configuration: condition.configuration.merge(
      "last_issue_at" => "2026-07-12T09:00:00Z",
      "seen_issue_keys" => [ "tadasant/zimmer#42" ]
    ))

    # Exactly what an API caller sends: the user-facing keys only, cursor omitted.
    condition.update!(configuration: {
      "repos" => [ "tadasant/zimmer" ],
      "exclude_labels" => [ "hold issue work gate" ]
    })

    condition.reload
    assert_equal [ "hold issue work gate" ], condition.github_exclude_labels
    assert_equal "2026-07-12T09:00:00Z", condition.github_last_issue_at
    assert_equal [ "tadasant/zimmer#42" ], condition.github_seen_issue_keys
  end

  test "poll state survives an edit that does not change what is watched" do
    condition = trigger_conditions(:github_label_condition)
    condition.update!(configuration: condition.configuration.merge("seen_items" => [ "tadasant/zimmer#1:ready to merge" ]))

    # A UI save posts only the user-facing keys; the cursor must not be collateral damage.
    condition.update!(configuration: github_label_config)

    assert_equal [ "tadasant/zimmer#1:ready to merge" ], condition.reload.github_seen_items
    assert condition.github_baselined?
  end

  # #647, exactly as it was sent: the caller read the condition, changed ONE key, and
  # sent the whole configuration back — poller state included, verbatim. What came back
  # out had no seen-set at all, and the next poll absorbed everything labelled since as
  # already-seen. An explicitly-passed poller key has to survive the write it was in.
  test "poller state passed explicitly on an update round-trips across a scope change" do
    condition = trigger_conditions(:github_label_condition)
    seen = [ "tadasant/zimmer#1:ready to merge" ]
    condition.update!(configuration: condition.configuration.merge("seen_items" => seen))

    condition.update!(configuration: github_label_config(
      "repos" => [ "tadasant/zimmer", "tadasant/zimmer-catalog" ],
      "seen_items" => seen
    ))

    condition.reload
    assert_equal seen, condition.github_seen_items
    assert condition.github_baselined?
    assert_equal [ "tadasant/zimmer", "tadasant/zimmer-catalog" ], condition.github_repos
  end

  # The other half of the same guarantee: a UI save (or an API caller editing only what
  # it cares about) sends no poller keys at all, and must not be punished for it.
  test "poller state omitted from an update is merged back across a scope change" do
    condition = trigger_conditions(:github_label_condition)
    condition.update!(configuration: condition.configuration.merge(
      "seen_items" => [ "tadasant/zimmer#1:ready to merge" ],
      "seen_missing_counts" => { "tadasant/zimmer#2:ready to merge" => 1 },
      "baseline_scope" => { "repos" => [ "tadasant/zimmer" ], "target" => "pull_request",
                            "labels" => [ "ready to merge" ] }
    ))

    condition.update!(configuration: github_label_config("repos" => [ "tadasant/zimmer", "tadasant/zimmer-catalog" ]))

    condition.reload
    assert_equal [ "tadasant/zimmer#1:ready to merge" ], condition.github_seen_items
    assert_equal({ "tadasant/zimmer#2:ready to merge" => 1 }, condition.github_seen_missing_counts)
    assert_equal [ "tadasant/zimmer" ], condition.github_baseline_scope["repos"],
                 "the baseline must still describe the scope it was actually taken against"
  end

  # The stampede the old drop-everything re-baseline was protecting against is now
  # headed off here instead: what the seen-set does NOT cover is still not an event.
  test "the baseline scope decides which repo and label an item counts as an event in" do
    condition = trigger_conditions(:github_label_condition)
    condition.update!(configuration: condition.configuration.merge(
      "seen_items" => [],
      "baseline_scope" => { "repos" => [ "tadasant/zimmer" ], "target" => "pull_request",
                            "labels" => [ "ready to merge" ] }
    ))
    condition.update!(configuration: github_label_config(
      "repos" => [ "tadasant/zimmer", "tadasant/zimmer-catalog" ],
      "labels" => [ "ready to merge", "needs review" ]
    ))
    condition.reload

    assert condition.github_baseline_covers?("tadasant/zimmer", "ready to merge")
    assert condition.github_baseline_covers?("Tadasant/Zimmer", "Ready To Merge"),
           "GitHub returns its own casing; the configured casing is what the keys use"
    assert_not condition.github_baseline_covers?("tadasant/zimmer-catalog", "ready to merge")
    assert_not condition.github_baseline_covers?("tadasant/zimmer", "needs review")
  end

  # A condition baselined before baseline_scope existed has none. Absent must read as
  # "covers what is watched now" — the reading that fires nothing retroactively on the
  # deploy that introduces the key.
  test "a seen-set with no recorded baseline scope covers everything currently watched" do
    condition = trigger_conditions(:github_label_condition)
    assert_nil condition.github_baseline_scope
    assert condition.github_baseline_covers?("tadasant/zimmer", "ready to merge")
    assert condition.github_baseline_covers?("tadasant/anything", "any label")
  end

  # …but "covers what is watched now" is only safe while the scope is not moving. An
  # edit that widens a condition that has never had a scope stamped — every live
  # condition, in the window between this deploy and its first tick — would otherwise
  # read the seen-set as already covering the repo added a millisecond ago, and every PR
  # already labelled there would look like a new event. The pre-edit scope is stamped
  # first, so the poller has something truthful to diff against.
  test "widening a condition that has no recorded baseline scope stamps the pre-edit scope first" do
    condition = trigger_conditions(:github_label_condition)
    # update_column, so the setup itself does not stamp a scope: this is a row that was
    # baselined before the key existed.
    condition.update_column(:configuration, condition.configuration.merge(
      "seen_items" => [ "tadasant/zimmer#1:ready to merge" ]
    ))
    assert_nil condition.reload.github_baseline_scope

    condition.update!(configuration: github_label_config("repos" => [ "tadasant/zimmer", "tadasant/zimmer-catalog" ]))
    condition.reload

    assert_equal [ "tadasant/zimmer" ], condition.github_baseline_scope["repos"],
                 "the stamp must describe what the seen-set covered BEFORE the edit"
    assert condition.github_baseline_covers?("tadasant/zimmer", "ready to merge")
    assert_not condition.github_baseline_covers?("tadasant/zimmer-catalog", "ready to merge"),
               "the newly-added repo must not be read as already baselined"
  end

  # The backfill describes a seen-set, so a condition without one gets no stamp — the
  # poller re-baselines it and writes its own.
  test "a condition with no seen-set gets no backfilled baseline scope" do
    condition = trigger_conditions(:github_label_condition)
    condition.update_column(:configuration, condition.configuration.except("seen_items"))

    condition.reload.update!(configuration: github_label_config("repos" => [ "tadasant/zimmer", "tadasant/zimmer-catalog" ]))

    assert_nil condition.reload.github_baseline_scope
    assert_not condition.github_baselined?
  end

  test "flipping the target invalidates the baseline, since a repo numbers issues and PRs together" do
    condition = trigger_conditions(:github_label_condition)
    condition.update!(configuration: condition.configuration.merge(
      "baseline_scope" => { "repos" => [ "tadasant/zimmer" ], "target" => "pull_request",
                            "labels" => [ "ready to merge" ] }
    ))
    condition.update!(configuration: github_label_config("target" => "issue"))
    condition.reload

    assert condition.github_baseline_retargeted?
    assert_not condition.github_baseline_covers?("tadasant/zimmer", "ready to merge")
  end

  # A github_issue condition's cursor is one global timestamp, so a widened scope still
  # restarts it — but at the instant of the EDIT, not at whatever time the next tick runs.
  # That closes the gap in which an issue opened right after the edit fell before the new
  # cursor and was never seen.
  test "adding a repo to a github_issue condition rebases its cursor to the edit" do
    condition = trigger_conditions(:github_issue_condition)
    condition.update!(configuration: condition.configuration.merge(
      "last_issue_at" => "2026-07-12T09:00:00Z",
      "seen_issue_keys" => [ "tadasant/zimmer#42" ]
    ))

    travel_to Time.utc(2026, 7, 13, 10, 0, 0) do
      condition.update!(configuration: { "repos" => [ "tadasant/zimmer", "tadasant/zimmer-catalog" ] })
    end

    condition.reload
    assert_equal "2026-07-13T10:00:00Z", condition.github_last_issue_at,
                 "the cursor must restart at the edit, not be dropped for the next tick to set"
  end

  # #759. The cursor restarts at the edit, but the poller queries INDEX_LAG_GRACE behind
  # it — so an emptied seen-set makes every issue already fired in the previous 30 minutes
  # read as fresh, and each one gets a second session. The set has to survive the rebase.
  test "adding a repo to a github_issue condition keeps the keys it has already fired" do
    condition = trigger_conditions(:github_issue_condition)
    condition.update!(configuration: condition.configuration.merge(
      "last_issue_at" => "2026-07-12T09:00:00Z",
      "seen_issue_keys" => [ "tadasant/zimmer#42" ]
    ))

    travel_to Time.utc(2026, 7, 13, 10, 0, 0) do
      condition.update!(configuration: { "repos" => [ "tadasant/zimmer", "tadasant/zimmer-catalog" ] })
    end

    assert_equal [ "tadasant/zimmer#42" ], condition.reload.github_seen_issue_keys,
                 "the rebased cursor still re-queries the 30 minutes behind it; forgetting " \
                 "what fired there is what re-fired zimmer#755 and #756 in production"
  end

  # What stops the newly-watched repo's own back catalogue from riding in on that preserved
  # window: it is baselined by repo, at the edit. The repos already watched get no entry,
  # so their grace window keeps working.
  test "adding a repo to a github_issue condition baselines only that repo" do
    condition = trigger_conditions(:github_issue_condition)
    condition.update!(configuration: condition.configuration.merge(
      "last_issue_at" => "2026-07-12T09:00:00Z"
    ))

    travel_to Time.utc(2026, 7, 13, 10, 0, 0) do
      condition.update!(configuration: { "repos" => [ "tadasant/zimmer", "tadasant/zimmer-catalog" ] })
    end

    assert_equal({ "tadasant/zimmer-catalog" => "2026-07-13T10:00:00Z" },
                 condition.reload.github_issue_repo_baselines)
  end

  # A second widening must not re-baseline the first addition: an issue opened in
  # zimmer-catalog between the two edits is a live event, and stamping it forward to the
  # later instant would swallow it. Each repo carries the instant IT joined.
  test "a second widening leaves the first addition's baseline where it was" do
    condition = trigger_conditions(:github_issue_condition)
    condition.update!(configuration: condition.configuration.merge(
      "last_issue_at" => "2026-07-12T09:00:00Z"
    ))

    travel_to Time.utc(2026, 7, 13, 10, 0, 0) do
      condition.update!(configuration: { "repos" => [ "tadasant/zimmer", "tadasant/zimmer-catalog" ] })
    end
    travel_to Time.utc(2026, 7, 13, 11, 0, 0) do
      condition.update!(configuration: {
        "repos" => [ "tadasant/zimmer", "tadasant/zimmer-catalog", "tadasant/pi-extensions" ]
      })
    end

    assert_equal({ "tadasant/zimmer-catalog" => "2026-07-13T10:00:00Z",
                   "tadasant/pi-extensions" => "2026-07-13T11:00:00Z" },
                 condition.reload.github_issue_repo_baselines)
  end

  # An edit that both adds and removes drops the departed repo's baseline: the entry can
  # never match another item once nothing from that repo is queried for. (A removal on its
  # own is not a widening and does not reach the rebase at all — see the test below.)
  test "a repo that leaves the scope in a widening edit takes its issue baseline with it" do
    condition = trigger_conditions(:github_issue_condition)
    condition.update!(configuration: condition.configuration.merge(
      "last_issue_at" => "2026-07-12T09:00:00Z"
    ))

    travel_to Time.utc(2026, 7, 13, 10, 0, 0) do
      condition.update!(configuration: { "repos" => [ "tadasant/zimmer", "tadasant/zimmer-catalog" ] })
    end
    travel_to Time.utc(2026, 7, 13, 11, 0, 0) do
      condition.update!(configuration: { "repos" => [ "tadasant/zimmer", "tadasant/pi-extensions" ] })
    end

    assert_equal({ "tadasant/pi-extensions" => "2026-07-13T11:00:00Z" },
                 condition.reload.github_issue_repo_baselines)
  end

  # A removal on its own keeps the cursor (tested above), so it also keeps the baselines —
  # there is no rebase to prune them in. Harmless: nothing from an unwatched repo is
  # queried for, and a re-add is a widening, which overwrites the stale entry with the
  # instant the repo actually rejoined.
  test "removing a repo on its own leaves the issue baselines alone, and a re-add restamps" do
    condition = trigger_conditions(:github_issue_condition)
    condition.update!(configuration: condition.configuration.merge(
      "last_issue_at" => "2026-07-12T09:00:00Z"
    ))

    travel_to Time.utc(2026, 7, 13, 10, 0, 0) do
      condition.update!(configuration: { "repos" => [ "tadasant/zimmer", "tadasant/zimmer-catalog" ] })
    end
    condition.update!(configuration: { "repos" => [ "tadasant/zimmer" ] })

    assert_equal({ "tadasant/zimmer-catalog" => "2026-07-13T10:00:00Z" },
                 condition.reload.github_issue_repo_baselines,
                 "a narrowing is not a rebase, so nothing prunes here")

    travel_to Time.utc(2026, 7, 13, 12, 0, 0) do
      condition.update!(configuration: { "repos" => [ "tadasant/zimmer", "tadasant/zimmer-catalog" ] })
    end

    assert_equal({ "tadasant/zimmer-catalog" => "2026-07-13T12:00:00Z" },
                 condition.reload.github_issue_repo_baselines,
                 "the re-add is a widening, so the repo is baselined at the instant it rejoined")
  end

  # The map is compared lexicographically against an issue's created_at, so a value that is
  # not an ISO 8601 string sorts above every timestamp and would suppress the repo forever,
  # silently — and the poller's prune would keep it forever too. The key is preserved across
  # a UI save, so an API or MCP caller can send one; the write path is where it is settled.
  test "a github_issue condition normalizes the issue baselines a caller sends" do
    condition = trigger_conditions(:github_issue_condition)

    condition.update!(configuration: condition.configuration.merge(
      "issue_repo_baselines" => {
        "Tadasant/Zimmer" => "2026-07-12T09:00:00+00:00",
        "tadasant/other" => { "not" => "a timestamp" },
        "tadasant/third" => "whenever",
        "" => "2026-07-12T09:00:00Z"
      }
    ))

    assert_equal({ "tadasant/zimmer" => "2026-07-12T09:00:00Z" },
                 condition.reload.github_issue_repo_baselines,
                 "downcased and re-emitted; anything unparseable is dropped rather than kept")
  end

  test "garbage in place of the issue baselines hash reads as no baselines at all" do
    condition = trigger_conditions(:github_issue_condition)
    condition.update!(configuration: condition.configuration.merge("issue_repo_baselines" => "nope"))

    assert_equal({}, condition.reload.github_issue_repo_baselines)
  end

  # A condition the poller has never reached has no cursor to rebase and no seen-set to
  # protect, so a widening edit writes no baseline: the poller's first tick stamps every
  # watched repo at its own instant, which covers the addition too.
  test "widening a github_issue condition that has never been polled writes no cursor state" do
    condition = trigger_conditions(:github_issue_condition)
    condition.update_column(
      :configuration,
      condition.configuration.except("last_issue_at", "seen_issue_keys")
    )

    travel_to Time.utc(2026, 7, 13, 10, 0, 0) do
      condition.reload.update!(configuration: { "repos" => [ "tadasant/zimmer", "tadasant/zimmer-catalog" ] })
    end

    condition.reload
    assert_nil condition.github_last_issue_at
    assert_equal({}, condition.github_issue_repo_baselines)
  end

  # Only a repo that was NOT watched before can back-fire, so only that rebases. A
  # removal keeps the cursor: rebasing on one throws away live position for nothing, and
  # if the poller happens to be behind it skips every issue opened in the repos that are
  # still watched — #647's shape, through the one path a narrowing can reach.
  test "removing a repo from a github_issue condition keeps its cursor" do
    condition = trigger_conditions(:github_issue_condition)
    condition.update!(configuration: condition.configuration.merge(
      "repos" => [ "tadasant/zimmer", "tadasant/zimmer-catalog" ]
    ))
    # The cursor is set in its own write: the widening above legitimately rebases it.
    condition.update!(configuration: condition.reload.configuration.merge(
      "last_issue_at" => "2026-07-12T09:00:00Z",
      "seen_issue_keys" => [ "tadasant/zimmer#42" ]
    ))

    condition.update!(configuration: { "repos" => [ "tadasant/zimmer" ] })

    condition.reload
    assert_equal "2026-07-12T09:00:00Z", condition.github_last_issue_at
    assert_equal [ "tadasant/zimmer#42" ], condition.github_seen_issue_keys
  end

  test "github condition descriptions read as events" do
    label = trigger_conditions(:github_label_condition)
    assert_equal "GitHub: 'ready to merge' added to PRs in tadasant/zimmer", label.description

    issue = trigger_conditions(:github_issue_condition)
    assert_equal "GitHub: new issue in tadasant/zimmer", issue.description
  end

  private

  # A never-fired "every day at 03:00 America/Los_Angeles" condition — the shape from
  # #447 — created and armed at +armed_at+. Persisted, because the arming instant is
  # what the first fire is measured from and an in-memory record would have none.
  #
  # Both columns are written explicitly. #armed_before? reads `armed_at`, and an
  # `armed_at` in the same write suppresses TriggerCondition#stamp_armed_at, which
  # would otherwise re-arm this to the wall clock the moment the configuration
  # changed — the very re-arm the shape-change tests below exercise on purpose.
  def fresh_daily_condition(armed_at:)
    @schedule_condition.update!(
      configuration: { "unit" => "days", "interval" => 1, "time" => "03:00",
                      "timezone" => "America/Los_Angeles" },
      last_triggered_at: nil,
      created_at: armed_at,
      armed_at: armed_at
    )
    @schedule_condition
  end

  # The weekly twin: "every Monday at 10:00 America/Los_Angeles", never fired.
  def fresh_weekly_condition(armed_at:)
    @weekly_condition.update!(
      configuration: { "unit" => "weeks", "interval" => 1, "time" => "10:00",
                      "day_of_week" => "monday", "timezone" => "America/Los_Angeles" },
      last_triggered_at: nil,
      created_at: armed_at,
      armed_at: armed_at
    )
    @weekly_condition
  end

  # The deployment-wide allow-list resolves through SecretsLoader (encrypted
  # credentials) first, ENV second -- the same order SlackService uses for its token.
  # So the helper controls BOTH sources, not just the credential: with a nil credential
  # the `||` in TriggerCondition.default_allowed_user_ids falls through to whatever
  # SLACK_BOT_MENTION_ALLOWED_USER_IDS the box happens to export, which would leave a
  # test claiming to assert the unset default while really asserting "this box has no
  # allow-list".
  #
  # Sets the real variable rather than stubbing ENV#[], for the same reason
  # with_expiration_env does: a partial mocha stub on ENV#[] breaks every other ENV
  # read the code path makes. Saving it before anything that can raise, likewise --
  # an early raise with `previous` unassigned would restore by deleting a variable
  # the helper never read.
  #
  # @param value [String, nil] the credential the deployment sets; nil means it sets
  #   none, which is the genuinely-unset case (raw is nil) rather than the
  #   blank-but-set one (a whitespace string, which short-circuits the ENV fallback)
  # @param env [String, nil] the process-ENV value behind it; nil means unset, which
  #   is what every caller but the resolution-order test wants
  def with_allowed_user_ids_secret(value, env: nil)
    previous = ENV["SLACK_BOT_MENTION_ALLOWED_USER_IDS"]
    if env.nil?
      ENV.delete("SLACK_BOT_MENTION_ALLOWED_USER_IDS")
    else
      ENV["SLACK_BOT_MENTION_ALLOWED_USER_IDS"] = env
    end
    SecretsLoader.stubs(:get).with("SLACK_BOT_MENTION_ALLOWED_USER_IDS").returns(value)
    yield
  ensure
    if previous.nil?
      ENV.delete("SLACK_BOT_MENTION_ALLOWED_USER_IDS")
    else
      ENV["SLACK_BOT_MENTION_ALLOWED_USER_IDS"] = previous
    end
  end
end
