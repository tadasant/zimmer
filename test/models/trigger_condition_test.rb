# frozen_string_literal: true

require "test_helper"

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
    assert_includes @slack_condition.errors[:configuration], "event_type must be one of: new_message, bot_mention"
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

  test "schedule_due? returns true when never triggered for minutes" do
    @schedule_condition.configuration = { "unit" => "minutes", "interval" => 15 }
    @schedule_condition.last_triggered_at = nil
    assert @schedule_condition.schedule_due?
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
    assert @schedule_condition.schedule_due?
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

  test "schedule_due? returns true when never triggered for days" do
    @schedule_condition.last_triggered_at = nil
    assert @schedule_condition.schedule_due?
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

  test "schedule_due? returns true when never triggered for weeks" do
    @weekly_condition.last_triggered_at = nil
    assert @weekly_condition.schedule_due?
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

    assert_empty condition.allowed_user_ids
    assert condition.allow_all_users?
    assert condition.user_allowed?("U_ANYONE")
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

    assert condition.allow_all_users?
    assert_not condition.user_allowed?(nil)
    assert_not condition.user_allowed?("")
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

  private

  # The deployment-wide allow-list resolves through SecretsLoader (encrypted
  # credentials) first, ENV second -- the same order SlackService uses for its token.
  def with_allowed_user_ids_secret(value)
    SecretsLoader.stubs(:get).with("SLACK_BOT_MENTION_ALLOWED_USER_IDS").returns(value)
    yield
  end
end
