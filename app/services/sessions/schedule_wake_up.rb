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
  # The `wake_me_up_later` MCP tool an agent calls on itself is the surface over
  # this, and the validation lives here rather than in the tool — a past-dated
  # wake leaves a session permanently asleep no matter who asked for it.
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
    # @return [Trigger] the persisted one-time wake trigger
    # @raise [Error] when the time or the session state makes the wake unschedulable
    def self.call(session:, wake_at:, prompt:, timezone: "UTC")
      new(session: session, wake_at: wake_at, prompt: prompt, timezone: timezone).call
    end

    def initialize(session:, wake_at:, prompt:, timezone: "UTC")
      @session = session
      @wake_at = normalize_seconds(wake_at.to_s)
      @prompt = prompt.to_s
      @timezone = timezone.presence || "UTC"
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

      # Wakes are ADDITIVE, and deliberately: an agent arming several at once is
      # the documented pattern — `wake_me_up_later` is routinely paired with
      # `wake_me_up_when_session_changes_state` watchers, whichever fires first
      # wins, and Trigger#hold_wake_group! cleans up the rest. The one
      # gesture that replaces rather than adds is a park into the spot queue,
      # which runs Sessions::SupersedePendingWakes itself.
      create_wake_trigger!
    end

    private

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
    # session — the target session is always reused — so the value is a label on
    # the trigger and nothing more. Prefer the catalog root the session resolves
    # to; fall back to the runtime for sessions that predate agent roots, or
    # whose root has since left the catalog.
    #
    # That fallback names no catalog root, and it does not have to. Only the path
    # that SPAWNS a session fails on a name it cannot resolve, so a wake carrying
    # an unresolvable one still fires and still resumes its session. That is a
    # guarantee of Trigger#create_session!, which raises from
    # #heal_stale_agent_root! only after every reuse path has returned, and it is
    # covered by a test there — before it held, this fallback bricked the wake it
    # was arming (https://github.com/tadasant/zimmer/issues/600). Do not "fix"
    # this by guessing a default root: a wake must never arm a root the session
    # would not have run as.
    def trigger_agent_root_name
      session.agent_root_key.presence || session.agent_runtime
    end
  end
end
