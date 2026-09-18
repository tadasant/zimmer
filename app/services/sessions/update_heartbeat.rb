# frozen_string_literal: true

module Sessions
  # Writes a session's heartbeat SETTINGS — the on/off flag and the beat
  # interval — and nothing else.
  #
  # Every surface that lets somebody change them routes through here: the web
  # UI's heart popout (`PATCH /sessions/:id/toggle_heartbeat` and
  # `PATCH /sessions/:id/update_heartbeat_interval`), `PATCH
  # /api/v1/sessions/:id/heartbeat`, and the `set_heartbeat` MCP action. One
  # writer is what keeps the four doors agreeing on which values are refusable.
  #
  # The rule is that a caller names a setting in a form the server can read, or
  # is told it cannot be read. Nothing is inferred from an unreadable value.
  # That is the strictest of the readings the four doors could take,
  # deliberately: a guess is indistinguishable from a working request at the
  # call site, and surfaces later as a heartbeat nobody asked for.
  #
  # `enabled` is cast by ActiveModel, which answers nil for blank and true for
  # every other non-blank string — so `enabled=maybe` turns a heartbeat on and
  # only `enabled=` is refused. That is ActiveModel's contract rather than a
  # choice made here, and `Sessions::UpdateHeartbeatTest` pins it so this
  # service cannot tighten it by accident.
  #
  # Scope: ONE `update!` on two columns. This does not beat the heartbeat, does
  # not stamp `heartbeat_last_beat_at`, and does not resume anything —
  # HeartbeatSweepJob owns all of that, and enabling a heartbeat here only makes
  # the session eligible for the next sweep. Two other writers touch
  # `heartbeat_enabled` as a side effect of something else, and neither is a
  # settings write: HeartbeatSweepJob auto-disables the flag on a terminal
  # session, and SessionStatusSummaryGenerator clears it on the fork it spawns.
  class UpdateHeartbeat
    class Error < StandardError; end

    # A call that named no setting at all. Distinct from Error so a surface can
    # classify it as a missing parameter rather than an unreadable one — the
    # REST API separates those two in its `error` field.
    class MissingSetting < Error; end

    # A whole non-negative number and nothing else. Stricter than ActiveRecord's
    # integer cast, which reads "60abc" as 60 and "abc" as 0, on purpose: a
    # truncated interval is a silently wrong cadence.
    INTEGER_STRING = /\A\d+\z/

    # @param session [Session]
    # @param enabled [Boolean, String, nil] nil leaves the flag alone
    # @param interval_seconds [Integer, String, nil] nil leaves the interval alone
    # @return [Session] the updated session
    # @raise [MissingSetting] when neither setting is named
    # @raise [Error] on an unreadable value or an out-of-range interval
    def self.call(session:, enabled: nil, interval_seconds: nil)
      new(session: session, enabled: enabled, interval_seconds: interval_seconds).call
    end

    def initialize(session:, enabled: nil, interval_seconds: nil)
      @session = session
      @enabled = enabled
      @interval_seconds = interval_seconds
    end

    attr_reader :session, :enabled, :interval_seconds

    def call
      attrs = {}
      attrs[:heartbeat_enabled] = resolved_enabled unless enabled.nil?
      attrs[:heartbeat_interval_seconds] = resolved_interval unless interval_seconds.nil?

      raise MissingSetting, "Provide at least one of enabled or interval_seconds." if attrs.empty?

      # Both values resolve before anything is assigned, so a bad interval leaves
      # a good `enabled` unwritten rather than half-applying the call.
      session.update!(attrs)
      session
    end

    private

    def resolved_enabled
      casted = ActiveModel::Type::Boolean.new.cast(enabled)
      # Blank is the one value ActiveModel cannot read, and it is the shape an
      # HTML form submits for a control nobody touched. Refusing it is what keeps
      # a nil away from the NOT NULL column.
      raise Error, "enabled must be a boolean." if casted.nil?

      casted
    end

    def resolved_interval
      unless interval_seconds.to_s.match?(INTEGER_STRING)
        raise Error, "interval_seconds must be an integer."
      end

      seconds = interval_seconds.to_i
      min = Session::HEARTBEAT_MIN_INTERVAL_SECONDS
      max = Session::HEARTBEAT_MAX_INTERVAL_SECONDS
      unless seconds.between?(min, max)
        raise Error, "interval_seconds must be between #{min} and #{max}."
      end

      seconds
    end
  end
end
