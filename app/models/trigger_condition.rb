# frozen_string_literal: true

# Represents a single condition that can fire a trigger.
# A Trigger (trigger flow) can have multiple conditions with OR semantics —
# if ANY condition fires, the trigger's session template executes.
#
# Condition types:
# - "slack": Fires when a new message is posted in a Slack channel
# - "schedule": Fires on a time-based schedule (recurring or one-time)
#     Recurring: { "unit" => "hours", "interval" => 2, "timezone" => "UTC" }
#     One-time:  { "scheduled_at" => "2026-04-15T14:30:00", "timezone" => "America/New_York" }
# - "ao_event": Fires on internal Zimmer events (e.g., session transitions to needs_input)
class TriggerCondition < ApplicationRecord
  CONDITION_TYPES = %w[slack schedule ao_event].freeze
  EVENT_TYPES = %w[new_message bot_mention].freeze
  SCHEDULE_UNITS = %w[minutes hours days weeks].freeze
  DAYS_OF_WEEK = %w[monday tuesday wednesday thursday friday saturday sunday].freeze
  AO_EVENT_NAMES = %w[session_needs_input session_failed session_archived].freeze

  belongs_to :trigger

  validates :condition_type, presence: true, inclusion: { in: CONDITION_TYPES }
  validates :configuration, presence: true
  validate :validate_configuration_for_type

  scope :slack, -> { where(condition_type: "slack") }
  scope :schedule, -> { where(condition_type: "schedule") }
  scope :ao_event, -> { where(condition_type: "ao_event") }

  # Slack configuration accessors
  def channel_id
    configuration["channel_id"]
  end

  def channel_name
    configuration["channel_name"]
  end

  def event_type
    configuration["event_type"] || "new_message"
  end

  # Optional thread timestamp for new_message conditions. When present, the
  # condition monitors new REPLIES in this specific thread instead of new
  # top-level messages in the channel. This is required for channels whose
  # meaningful posts arrive as thread replies (e.g. a daily digest thread) —
  # plain conversations.history polling never surfaces thread replies, so a
  # top-level new_message condition can never fire on them.
  def thread_ts
    configuration["thread_ts"].presence
  end

  # True when this is a Slack condition scoped to a specific thread's replies.
  def thread_scoped?
    condition_type == "slack" && thread_ts.present?
  end

  # The deployment-wide allow-list for bot_mention conditions: a comma-separated
  # list of Slack user IDs in SLACK_BOT_MENTION_ALLOWED_USER_IDS, resolved from
  # encrypted credentials first and process ENV second (the same order
  # SlackService#slack_bot_token and AlertService#channel_id use).
  #
  # Blank or unset means EVERYONE, not nobody. An unconfigured Zimmer lets any
  # workspace member @mention or DM the bot; a deployment narrows it by setting
  # this. The bound on "everyone" is that the bot only ever sees channels it has
  # been invited to, and DMs people choose to open with it.
  def self.default_allowed_user_ids
    raw = SecretsLoader.get("SLACK_BOT_MENTION_ALLOWED_USER_IDS") ||
      ENV["SLACK_BOT_MENTION_ALLOWED_USER_IDS"]

    raw.to_s.split(",").filter_map { |id| id.strip.presence }
  end

  # Allowed user IDs for bot_mention conditions: this condition's own explicit
  # list if it has one (set from the UI/API), else the deployment-wide default.
  # Empty means unrestricted -- ask allow_all_users? rather than reading this as
  # "nobody", and see the DM caveat there.
  # Memoized: the poller asks this once per message and once per thread reply, and
  # SecretsLoader deliberately does not memoize (it re-reads credentials on every
  # call so a deploy's new secrets are picked up mid-process). A condition object
  # lives for one poll, so caching here is safe and saves that work per message.
  def allowed_user_ids
    @allowed_user_ids ||= begin
      ids = configuration["allowed_user_ids"]
      ids.present? ? Array(ids) : self.class.default_allowed_user_ids
    end
  end

  # True when no allow-list applies, i.e. every workspace member may trigger.
  #
  # Callers MUST branch on this rather than passing allowed_user_ids around: the
  # DM path enumerates the allow-list (SlackService.list_dm_channels filters
  # conversations.list down to DMs with those users), and "everyone" cannot be
  # expressed as a list of IDs. Treating the empty list as a filter silently means
  # "nobody" and DMs stop working.
  def allow_all_users?
    allowed_user_ids.empty?
  end

  # Whether a Slack user may fire this condition.
  def user_allowed?(user_id)
    return false if user_id.blank?

    allow_all_users? || allowed_user_ids.include?(user_id)
  end

  # Get the per-user DM timestamps for bot_mention conditions.
  # Returns a hash of user_id => last_message_ts
  def dm_timestamps
    configuration["dm_timestamps"] || {}
  end

  # Update DM timestamp for a specific user
  def update_dm_timestamp!(user_id, ts)
    new_config = configuration.merge("dm_timestamps" => dm_timestamps.merge(user_id => ts))
    update!(configuration: new_config)
  end

  # Get the per-channel timestamps for bot_mention conditions (all-channel monitoring).
  # Returns a hash of channel_id => last_message_ts
  def channel_timestamps
    configuration["channel_timestamps"] || {}
  end

  # Update channel timestamp for a specific channel
  def update_channel_timestamp!(channel_id, ts)
    new_config = configuration.merge("channel_timestamps" => channel_timestamps.merge(channel_id => ts))
    update!(configuration: new_config)
  end

  # Get per-thread "last reply checked" timestamps for bot_mention conditions.
  # Returns a hash of "channel_id:thread_ts" => last_reply_ts
  def thread_timestamps
    configuration["thread_timestamps"] || {}
  end

  # Schedule configuration accessors
  def scheduled_at
    configuration["scheduled_at"]
  end

  def one_time_schedule?
    condition_type == "schedule" && scheduled_at.present?
  end

  def schedule_interval
    (configuration["interval"] || 1).to_i
  end

  def schedule_unit
    configuration["unit"]
  end

  def schedule_time
    configuration["time"]
  end

  def schedule_day_of_week
    configuration["day_of_week"]
  end

  def schedule_timezone
    configuration["timezone"] || "UTC"
  end

  # Zimmer event configuration accessors
  def ao_event_name
    configuration["event_name"]
  end

  # Optional session id this ao_event condition is scoped to. When set, the
  # condition only fires when the specified session transitions to the watched
  # state. When nil, the condition fires for any session transitioning to the
  # watched state (broadcast semantics).
  def watched_session_id
    return nil unless condition_type == "ao_event"
    value = configuration["watched_session_id"]
    return nil if value.blank?
    value.to_i
  end

  # Returns true if this ao_event condition is scoped to a specific session.
  def session_scoped_ao_event?
    condition_type == "ao_event" && watched_session_id.present?
  end

  # Human-readable schedule description
  def schedule_description
    return nil unless condition_type == "schedule"

    if one_time_schedule?
      tz = schedule_timezone
      zone = ActiveSupport::TimeZone[tz]
      return "Once at #{scheduled_at} (#{tz})" unless zone

      begin
        parsed = zone.parse(scheduled_at)
        "Once at #{parsed.strftime('%Y-%m-%d %H:%M')} (#{tz})"
      rescue ArgumentError
        "Once at #{scheduled_at} (#{tz})"
      end
    else
      interval = schedule_interval
      unit = schedule_unit
      time = schedule_time
      day = schedule_day_of_week
      tz = schedule_timezone

      base = interval == 1 ? "Every #{unit&.singularize}" : "Every #{interval} #{unit}"

      case unit
      when "minutes"
        base
      when "hours"
        time_part = time.present? ? " at :#{time.to_s.split(':').last || '00'}" : ""
        "#{base}#{time_part}"
      when "days"
        time_part = time.present? ? " at #{time}" : ""
        "#{base}#{time_part} (#{tz})"
      when "weeks"
        day_part = day.present? ? " on #{day.capitalize}" : ""
        time_part = time.present? ? " at #{time}" : ""
        "#{base}#{day_part}#{time_part} (#{tz})"
      else
        "Custom schedule"
      end
    end
  end

  # Human-readable description for any condition type
  def description
    case condition_type
    when "slack"
      if event_type == "bot_mention"
        channel_name.present? ? "Slack: @mention in ##{channel_name} + DMs" : "Slack: @mention in all channels + DMs"
      else
        channel_name.present? ? "Slack: ##{channel_name}" : "Slack trigger"
      end
    when "schedule"
      schedule_description || "Schedule trigger"
    when "ao_event"
      base = case ao_event_name
      when "session_needs_input"
        "Zimmer Event: Session needs input"
      when "session_failed"
        "Zimmer Event: Session failed"
      when "session_archived"
        "Zimmer Event: Session archived"
      else
        "Zimmer Event: #{ao_event_name}"
      end
      session_scoped_ao_event? ? "#{base} (session ##{watched_session_id})" : base
    else
      "Unknown trigger"
    end
  end

  # Check if the schedule trigger should fire now
  def schedule_due?
    return false unless condition_type == "schedule"
    return false unless trigger&.enabled?

    now = Time.current.in_time_zone(schedule_timezone)
    last = last_triggered_at&.in_time_zone(schedule_timezone)

    if one_time_schedule?
      return false if last.present?
      parsed = ActiveSupport::TimeZone[schedule_timezone].parse(scheduled_at)
      return now >= parsed
    end

    case schedule_unit
    when "minutes"
      last.nil? || now - last >= schedule_interval.minutes
    when "hours"
      last.nil? || now - last >= schedule_interval.hours
    when "days"
      return true if last.nil?
      target = parse_schedule_time(now)
      now >= target && (now.to_date - last.to_date).to_i >= schedule_interval
    when "weeks"
      return true if last.nil?
      target_day = DAYS_OF_WEEK.index(schedule_day_of_week) # 0=monday
      current_day = (now.wday - 1) % 7 # Convert Sunday=0 to Monday=0
      target = parse_schedule_time(now)
      weeks_elapsed = ((now.to_date - last.to_date).to_i / 7.0).floor
      current_day == target_day && now >= target && weeks_elapsed >= schedule_interval
    else
      false
    end
  rescue ArgumentError
    Rails.logger.warn "[TriggerCondition#schedule_due?] Invalid timezone '#{schedule_timezone}' for condition #{id}"
    false
  end

  # Update the last polled timestamp (for Slack polling)
  def mark_polled!(message_ts: nil)
    attrs = { last_polled_at: Time.current }
    attrs[:last_message_ts] = message_ts if message_ts
    update!(attrs)
  end

  private

  def parse_schedule_time(reference_time)
    return reference_time.beginning_of_day unless schedule_time.present?
    parts = schedule_time.to_s.split(":")
    hour = (parts[0] || "0").to_i
    minute = (parts[1] || "0").to_i
    reference_time.change(hour: hour, min: minute, sec: 0)
  end

  def validate_configuration_for_type
    unless configuration.is_a?(Hash)
      errors.add(:configuration, "must be a hash")
      return
    end

    case condition_type
    when "slack"
      validate_slack_configuration
    when "schedule"
      validate_schedule_configuration
    when "ao_event"
      validate_ao_event_configuration
    end
  end

  def validate_slack_configuration
    # channel_id is required for new_message, optional for bot_mention (which also monitors DMs)
    if configuration["channel_id"].blank? && event_type != "bot_mention"
      errors.add(:configuration, "must include channel_id for Slack conditions")
    end

    if configuration["event_type"].present? && !EVENT_TYPES.include?(configuration["event_type"])
      errors.add(:configuration, "event_type must be one of: #{EVENT_TYPES.join(', ')}")
    end

    # thread_ts scopes a new_message condition to a single thread's replies. It
    # requires a channel_id (which thread to read), and is meaningless for
    # bot_mention conditions (those handle threads via their own @mention scan).
    if configuration["thread_ts"].present?
      if configuration["channel_id"].blank?
        errors.add(:configuration, "thread_ts requires a channel_id")
      end
      if event_type == "bot_mention"
        errors.add(:configuration, "thread_ts is not supported for bot_mention conditions")
      end
    end
  end

  def validate_schedule_configuration
    if configuration["scheduled_at"].present?
      validate_one_time_schedule_configuration
    else
      validate_recurring_schedule_configuration
    end

    if configuration["timezone"].present? && !ActiveSupport::TimeZone[configuration["timezone"]]
      errors.add(:configuration, "timezone is not a recognized timezone")
    end
  end

  # Validates that scheduled_at is a parseable ISO 8601 datetime.
  # This only checks format — schedule_due? interprets the value relative to
  # the configured timezone. Past datetimes are allowed ("fire ASAP" semantics).
  #
  # Also normalizes the value: HTML datetime-local inputs submit "YYYY-MM-DDTHH:MM"
  # (no seconds), but Time.iso8601 requires seconds. Appends ":00" if needed.
  def validate_one_time_schedule_configuration
    value = configuration["scheduled_at"]

    # Normalize datetime-local format (YYYY-MM-DDTHH:MM) to full ISO 8601
    if value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}\z/)
      configuration["scheduled_at"] = "#{value}:00"
      value = configuration["scheduled_at"]
    end

    parsed = begin
      Time.iso8601(value)
    rescue ArgumentError, TypeError
      nil
    end
    unless parsed
      errors.add(:configuration, "scheduled_at must be a valid datetime (ISO 8601 format)")
    end
  end

  def validate_recurring_schedule_configuration
    unit = configuration["unit"]
    if unit.blank?
      errors.add(:configuration, "must include unit for Schedule conditions")
      return
    end

    unless SCHEDULE_UNITS.include?(unit)
      errors.add(:configuration, "unit must be one of: #{SCHEDULE_UNITS.join(', ')}")
      return
    end

    interval = configuration["interval"]
    if interval.blank?
      errors.add(:configuration, "must include interval for Schedule conditions")
      return
    end

    interval_val = interval.to_i
    if interval_val < 1
      errors.add(:configuration, "interval must be at least 1")
    end

    if %w[days weeks].include?(unit) && configuration["time"].blank?
      errors.add(:configuration, "must include time for #{unit} schedules")
    end

    if unit == "weeks" && configuration["day_of_week"].blank?
      errors.add(:configuration, "must include day_of_week for weekly schedules")
    end

    if configuration["day_of_week"].present? && !DAYS_OF_WEEK.include?(configuration["day_of_week"])
      errors.add(:configuration, "day_of_week must be one of: #{DAYS_OF_WEEK.join(', ')}")
    end

    if configuration["time"].present? && !configuration["time"].match?(/\A([01]\d|2[0-3]):[0-5]\d\z/)
      errors.add(:configuration, "time must be in HH:MM format")
    end
  end

  def validate_ao_event_configuration
    event_name = configuration["event_name"]
    if event_name.blank?
      errors.add(:configuration, "must include event_name for Zimmer Event conditions")
      return
    end

    unless AO_EVENT_NAMES.include?(event_name)
      errors.add(:configuration, "event_name must be one of: #{AO_EVENT_NAMES.join(', ')}")
    end

    if configuration.key?("watched_session_id") && configuration["watched_session_id"].present?
      raw = configuration["watched_session_id"]
      session_id = raw.is_a?(Integer) ? raw : raw.to_s.to_i

      if session_id <= 0
        errors.add(:configuration, "watched_session_id must be a positive integer")
      elsif !Session.where(id: session_id).exists?
        errors.add(:configuration, "watched_session_id #{session_id} does not reference an existing session")
      else
        # Normalize to integer so JSON storage is canonical
        configuration["watched_session_id"] = session_id
      end
    end
  end
end
