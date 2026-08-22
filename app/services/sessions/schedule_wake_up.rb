# frozen_string_literal: true

module Sessions
  # Schedules a one-time wake-up for an existing session by creating a schedule
  # Trigger bound to it (reuse_session + last_session_id), mirroring
  # POST /api/v1/triggers.
  #
  # The sleep is NOT a separate step: Trigger's `after_create
  # :sleep_target_session_if_applicable` callback transitions the target session
  # to waiting (or sets pending_sleep on a running one) inside the same
  # transaction that persists the trigger. Creating the trigger IS the atomic
  # sleep+schedule, which is why nothing here calls Session#sleep! itself.
  #
  # Two surfaces share this: the `wake_me_up_later` MCP tool an agent calls on
  # itself, and the "Pause Until" control a human clicks in the web UI. They
  # validate identically because the validation lives here — a past-dated wake
  # leaves a session permanently asleep no matter who asked for it.
  class ScheduleWakeUp
    # Raised for every rejected request. `code` lets a caller add its own
    # remediation sentence without re-deriving why the call failed.
    class Error < StandardError
      attr_reader :code

      def initialize(message, code: nil)
        super(message)
        @code = code
      end
    end

    # Reject wake-ups that resolve to <= 30 seconds in the future. Anything inside
    # this window is effectively "now" — and the past-dated case (the bug this
    # guards against) silently fires-and-drops in the scheduler, leaving the
    # session permanently asleep.
    WAKE_AT_GRACE_WINDOW = 30.seconds

    # Reject inputs that don't look like a calendar+time: bare dates ("2026-04-15"),
    # trailing offsets ("...+05:00"), and `Z` paired with a non-UTC IANA timezone
    # (ambiguous — we'd have to pick one to honor and the other to ignore).
    NAIVE_DATETIME_REGEX = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?Z?\z/
    EXPLICIT_OFFSET_REGEX = /[+-]\d{2}:?\d{2}\z/

    UTC_ZONE_NAMES = %w[UTC Etc/UTC].freeze

    # `needs_input` → immediate sleep; `running` → deferred sleep via pending_sleep
    # metadata; `waiting` → already dormant, the trigger fires normally. Anything
    # else (failed, archived) would silently no-op the auto-sleep and leave the
    # caller with a trigger targeting a session that can't be woken.
    WAKEABLE_STATUSES = %w[needs_input running waiting].freeze

    # @param session [Session] the session to sleep and wake
    # @param wake_at [String] naive ISO-8601 wall-clock time, e.g. "2026-04-15T14:30:00"
    # @param prompt [String] the prompt the wake resumes the session with
    # @param timezone [String] IANA zone `wake_at` is expressed in
    # @param replace_existing [Boolean] cancel this session's unfired one-time
    #   schedule wakes first (see #supersede_existing_wakes!)
    # @return [Trigger] the persisted one-time wake trigger
    # @raise [Error] when the time or the session state makes the wake unschedulable
    def self.call(session:, wake_at:, prompt:, timezone: "UTC", replace_existing: false)
      new(session: session, wake_at: wake_at, prompt: prompt, timezone: timezone,
          replace_existing: replace_existing).call
    end

    def initialize(session:, wake_at:, prompt:, timezone: "UTC", replace_existing: false)
      @session = session
      @wake_at = normalize_seconds(wake_at.to_s)
      @prompt = prompt.to_s
      @timezone = timezone.presence || "UTC"
      @replace_existing = replace_existing
    end

    attr_reader :session, :wake_at, :prompt, :timezone

    def call
      # Cheapest validation runs first (no DB writes). A past-dated wake_at
      # silently fires-and-drops in the scheduler and leaves the session
      # permanently asleep, so reject it before any state change.
      wake_at_utc = parse_wake_at

      if wake_at_utc <= Time.current + WAKE_AT_GRACE_WINDOW
        raise Error.new(
          "wake_at \"#{wake_at}\" (timezone: #{timezone}) resolves to #{format_utc(wake_at_utc)} UTC, " \
          "which is in the past or within #{WAKE_AT_GRACE_WINDOW.to_i} seconds of the current server time " \
          "(#{format_utc(Time.current)} UTC). No trigger was created and no session state was changed.",
          code: :wake_at_too_soon
        )
      end

      unless WAKEABLE_STATUSES.include?(session.status.to_s)
        raise Error.new(
          "Session #{session.id} is in \"#{session.status}\" state and cannot be scheduled for wake-up. " \
          "Only sessions in #{WAKEABLE_STATUSES.join(', ')} can be woken up.",
          code: :not_wakeable
        )
      end

      raise Error.new("A wake-up prompt is required.", code: :missing_prompt) if prompt.blank?

      # One transaction: superseding the old wake and arming the new one are the
      # same act. Splitting them means a create that fails after the destroy
      # leaves an already-sleeping session with nothing armed at all — while the
      # error it raises says no changes were made.
      Trigger.transaction do
        supersede_existing_wakes! if @replace_existing
        create_wake_trigger!
      end
    end

    private

    # Cancel this session's unfired one-time schedule wakes before arming a new one.
    #
    # Off by default, because an agent arming several wakes at once is the
    # documented pattern: `wake_me_up_later` is routinely paired with
    # `wake_me_up_when_session_changes_state` watchers, whichever fires first wins,
    # and Trigger#destroy_sibling_wakes! cleans up the rest.
    #
    # The web UI's "Pause Until" is the opposite gesture. A human picking a second
    # time means "not then, THIS time" — and leaving the first wake armed would fire
    # at whichever is earlier, which is precisely the time they just replaced.
    #
    # Only triggers whose SOLE condition is an unfired one-time schedule are
    # destroyed: a trigger carrying other conditions (OR semantics) does other work,
    # and a session-scoped ao_event wake answers a different question ("when X
    # happens") that a chosen wall-clock time does not supersede.
    def supersede_existing_wakes!
      # preload, NOT includes. `includes` alongside `joins` + a `trigger_conditions`
      # WHERE turns this into a single eager-loading LEFT JOIN, so
      # `trigger.trigger_conditions` would come back holding only the conditions
      # that matched the filter. Both things below then break: a multi-condition
      # trigger looks single-condition and gets selected, and `destroy!` cascades
      # over the truncated association, leaving the unloaded rows behind to
      # violate their foreign key. preload issues a second, unfiltered query.
      candidates = Trigger
        .joins(:trigger_conditions)
        .where(reuse_session: true, last_session_id: session.id, status: "enabled")
        .where(trigger_conditions: { condition_type: "schedule", last_triggered_at: nil })
        .distinct
        .preload(:trigger_conditions)
        .select { |trigger| trigger.trigger_conditions.one? && trigger.trigger_conditions.sole.one_time_schedule? }

      return if candidates.empty?

      destroyed = candidates.map do |trigger|
        trigger.destroy!
        trigger.id
      end

      session.logs.create!(
        content: "[Pause Until] Superseded pending wake-up trigger(s) #{destroyed.join(', ')}",
        level: "info"
      )
    end

    # Minute-precision is accepted, but the value is stored on the trigger
    # condition and re-parsed with Time.iso8601 when it fires, which requires
    # seconds. TriggerCondition normalizes the bare "…T09:00" form itself but not
    # "…T09:00Z", so canonicalize here and store a value that always fires.
    def normalize_seconds(value)
      match = /\A(\d{4}-\d{2}-\d{2}T\d{2}:\d{2})(Z?)\z/.match(value)
      return value unless match

      "#{match[1]}:00#{match[2]}"
    end

    # Convert a naive ISO-8601 wall-clock string in `timezone` to an absolute
    # instant, using the same ActiveSupport::TimeZone#parse the scheduler itself
    # uses (TriggerCondition#schedule_due?) so validation and firing agree on
    # what the string means — including across DST boundaries.
    def parse_wake_at
      if wake_at.match?(EXPLICIT_OFFSET_REGEX)
        invalid_wake_at!('wake_at must not include a UTC offset (e.g., "+05:00"); pass the wall-clock time and an IANA timezone name (e.g., "America/New_York")')
      end

      unless wake_at.match?(NAIVE_DATETIME_REGEX)
        invalid_wake_at!('wake_at must be an ISO-8601 datetime like "2026-04-15T14:30:00" (date-only and other formats are not accepted)')
      end

      zone = ActiveSupport::TimeZone[timezone]
      invalid_wake_at!("\"#{timezone}\" is not a recognized IANA timezone name") if zone.nil?

      if wake_at.end_with?("Z") && !UTC_ZONE_NAMES.include?(timezone)
        invalid_wake_at!("wake_at ends with \"Z\" (UTC) but timezone is \"#{timezone}\". Either drop the trailing \"Z\" or set timezone to \"UTC\"")
      end

      parsed = begin
        zone.parse(wake_at.delete_suffix("Z"))
      rescue ArgumentError
        nil
      end
      invalid_wake_at!("Invalid wake_at value: \"#{wake_at}\"") if parsed.nil?

      parsed
    end

    def invalid_wake_at!(detail)
      raise Error.new(
        "Could not parse wake_at \"#{wake_at}\" with timezone \"#{timezone}\": #{detail}. " \
        "No trigger was created and no session state was changed.",
        code: :unparseable_wake_at
      )
    end

    def format_utc(time)
      time.utc.iso8601
    end

    def create_wake_trigger!
      Trigger.create!(
        name: "Wake session ##{session.id} at #{wake_at}",
        agent_root_name: trigger_agent_root_name,
        prompt_template: prompt,
        reuse_session: true,
        last_session_id: session.id,
        trigger_conditions_attributes: [
          {
            condition_type: "schedule",
            configuration: { "scheduled_at" => wake_at, "timezone" => timezone }
          }
        ]
      )
    rescue ActiveRecord::RecordInvalid => e
      raise Error.new(
        "Trigger creation failed: #{e.record.errors.full_messages.join(', ')}. " \
        "The session is still in its original state — no changes were made.",
        code: :trigger_invalid
      )
    end

    # Trigger requires agent_root_name, but a per-session wake-up trigger
    # (reuse_session + last_session_id + a one-time condition) never spawns a new
    # session — the target session is always reused — so the value is only ever
    # bookkeeping. Prefer the catalog root the session resolves to; fall back to
    # the runtime for sessions that predate agent roots.
    def trigger_agent_root_name
      session.agent_root_key.presence || session.agent_runtime
    end
  end
end
