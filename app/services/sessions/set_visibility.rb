# frozen_string_literal: true

module Sessions
  # Writes a session's board visibility — and nothing else.
  #
  # Every surface that can hide or snooze a session (the web UI's menu, PATCH
  # /api/v1/sessions/:id/visibility, and the `set_visibility` MCP action) routes
  # through here, so all three agree on what a snooze time means and on which
  # values are refusable.
  #
  # This service deliberately performs ONE `update!` on two presentation columns.
  # It does not touch `status`, does not arm or cancel a trigger, does not enter
  # or leave the spot queue, and does not consult the quota gate — snoozing a
  # session changes what the operator sees and changes nothing about when Zimmer
  # runs it. That is the whole contract of the feature; anything added here that
  # reaches into the lifecycle is a bug rather than a feature.
  #
  # Contrast Sessions::ScheduleWakeUp, which `wake_me_up_later`
  # control uses: that one really does sleep the session.
  class SetVisibility
    class Error < StandardError; end

    # Same wall-clock contract Sessions::ScheduleWakeUp uses: the browser sends a NAIVE local
    # datetime plus the IANA zone it is expressed in, and the server resolves it
    # there. Sending the naive value alone would let the server read it as UTC and
    # silently shift every snooze by the operator's offset — which is how "Tomorrow,
    # 9 AM" turns into 3am.
    NAIVE_DATETIME_REGEX = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?Z?\z/
    EXPLICIT_OFFSET_REGEX = /[+-]\d{2}:?\d{2}\z/
    UTC_ZONE_NAMES = %w[UTC Etc/UTC].freeze

    # @param session [Session]
    # @param visibility [String] "visible", "hidden" or "snoozed"
    # @param snoozed_until [String, Time, nil] required for "snoozed"; a naive
    #   wall-clock string ("2026-09-05T09:00") read in `timezone`, or a Time
    # @param timezone [String] IANA zone the naive string is expressed in
    # @return [Session] the updated session
    # @raise [Error] on an unknown visibility or an unusable snooze time
    def self.call(session:, visibility:, snoozed_until: nil, timezone: "UTC")
      new(session: session, visibility: visibility, snoozed_until: snoozed_until, timezone: timezone).call
    end

    def initialize(session:, visibility:, snoozed_until: nil, timezone: "UTC")
      @session = session
      @visibility = visibility.to_s.strip
      @snoozed_until = snoozed_until
      @timezone = timezone.presence || "UTC"
    end

    attr_reader :session, :visibility, :timezone

    def call
      unless SessionVisibility::VISIBILITIES.include?(visibility)
        raise Error, "Unknown visibility \"#{visibility}\". Valid values: #{SessionVisibility::VISIBILITIES.join(', ')}."
      end

      if visibility == SessionVisibility::SNOOZED
        session.update!(visibility: visibility, snoozed_until: resolved_snooze_time)
      else
        # A hidden or visible session carries no snooze time. Clearing it here
        # rather than leaving it behind is what keeps `snoozed_until` readable as
        # "when this comes back" instead of "when it last would have".
        session.update!(visibility: visibility, snoozed_until: nil)
      end

      session
    end

    private

    def resolved_snooze_time
      raise Error, "snoozed_until is required to snooze a session." if @snoozed_until.blank?

      at = @snoozed_until.is_a?(String) ? parse_naive(@snoozed_until.strip) : @snoozed_until.to_time

      # A snooze in the past would be over the instant it was set — an operator
      # clicking a control that visibly does nothing. Say so instead.
      if at <= Time.current
        raise Error, "snoozed_until #{at.utc.iso8601} is in the past; pick a time in the future."
      end

      at
    end

    def parse_naive(value)
      if value.match?(EXPLICIT_OFFSET_REGEX)
        raise Error, "snoozed_until must not carry a UTC offset; send the wall-clock time and an IANA timezone name (e.g. \"America/New_York\")."
      end

      unless value.match?(NAIVE_DATETIME_REGEX)
        raise Error, "snoozed_until must be an ISO-8601 datetime like \"2026-09-05T09:00:00\"."
      end

      zone = ActiveSupport::TimeZone[timezone]
      raise Error, "\"#{timezone}\" is not a recognized IANA timezone name." if zone.nil?

      if value.end_with?("Z") && !UTC_ZONE_NAMES.include?(timezone)
        raise Error, "snoozed_until ends with \"Z\" (UTC) but timezone is \"#{timezone}\". Drop the \"Z\" or set timezone to \"UTC\"."
      end

      parsed = begin
        zone.parse(value.delete_suffix("Z"))
      rescue ArgumentError
        nil
      end
      raise Error, "Could not parse snoozed_until \"#{value}\"." if parsed.nil?

      parsed
    end
  end
end
