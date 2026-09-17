# frozen_string_literal: true

module Sessions
  # Writes a session's heartbeat settings — the on/off flag and the beat
  # interval — and nothing else.
  #
  # Every surface that can change them routes through here: the web UI's heart
  # popout (`PATCH /sessions/:id/toggle_heartbeat` and
  # `PATCH /sessions/:id/update_heartbeat_interval`), `PATCH
  # /api/v1/sessions/:id/heartbeat`, and the `set_heartbeat` MCP action. Before
  # this service there were four copies of the same two validations, and they
  # had drifted: the web toggle treated a blank `enabled` as "flip it" rather
  # than as a mistake, the web interval action let `"60abc"` through because
  # ActiveRecord casts it to 60, and only the MCP copy checked the interval
  # against Session::HEARTBEAT_MIN/MAX_INTERVAL_SECONDS itself instead of
  # letting the model's numericality validator phrase the refusal.
  #
  # The strictest copy is the canonical one. A caller that names a setting has
  # to name it in a form the service can read; nothing is guessed from an
  # unreadable value.
  #
  # This service does ONE `update!` on two columns. It does not beat the
  # heartbeat, does not touch `heartbeat_last_beat_at`, and does not resume
  # anything — HeartbeatSweepJob owns all of that. Turning a heartbeat on here
  # only makes a session eligible for the next sweep.
  class UpdateHeartbeat
    class Error < StandardError; end

    # Passed as `enabled:` by a surface whose control is a toggle rather than a
    # value — the web heart button, which knows the session should flip but not
    # which way. Resolved against the row inside the same call, so a flip can
    # never write the nil that a bad cast used to risk putting in a NOT NULL
    # column.
    TOGGLE = :toggle

    # A whole non-negative number and nothing else. Deliberately stricter than
    # ActiveRecord's integer cast, which reads "60abc" as 60 and "abc" as 0.
    INTEGER_STRING = /\A\d+\z/

    # @param session [Session]
    # @param enabled [Boolean, String, TOGGLE, nil] nil leaves the flag alone
    # @param interval_seconds [Integer, String, nil] nil leaves the interval alone
    # @return [Session] the updated session
    # @raise [Error] on an unreadable value, an out-of-range interval, or no settings at all
    def self.call(session:, enabled: nil, interval_seconds: nil)
      new(session: session, enabled: enabled, interval_seconds: interval_seconds).call
    end

    def initialize(session:, enabled: nil, interval_seconds: nil)
      @session = session
      @enabled = enabled
      @interval_seconds = interval_seconds
    end

    attr_reader :session

    def call
      attrs = {}
      attrs[:heartbeat_enabled] = resolved_enabled unless @enabled.nil?
      attrs[:heartbeat_interval_seconds] = resolved_interval unless @interval_seconds.nil?

      if attrs.empty?
        raise Error, "Provide at least one of enabled or interval_seconds."
      end

      session.update!(attrs)
      session
    end

    private

    def resolved_enabled
      return !session.heartbeat_enabled if @enabled == TOGGLE

      casted = ActiveModel::Type::Boolean.new.cast(@enabled)
      # ActiveModel's boolean cast answers nil for nothing but blank — every
      # other string is true — so this catches exactly `enabled=`, the shape an
      # HTML form submits for a control the user never touched. A value the
      # caller sent but the server cannot read is a mistake to report, not a
      # coin to flip, and it must never reach the NOT NULL column.
      raise Error, "enabled must be a boolean." if casted.nil?

      casted
    end

    def resolved_interval
      unless @interval_seconds.to_s.match?(INTEGER_STRING)
        raise Error, "interval_seconds must be an integer."
      end

      seconds = @interval_seconds.to_i
      min = Session::HEARTBEAT_MIN_INTERVAL_SECONDS
      max = Session::HEARTBEAT_MAX_INTERVAL_SECONDS
      unless seconds.between?(min, max)
        raise Error, "interval_seconds must be between #{min} and #{max}."
      end

      seconds
    end
  end
end
