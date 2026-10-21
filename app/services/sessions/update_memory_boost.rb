# frozen_string_literal: true

module Sessions
  # Grants or ends a session's one-off memory boost (`memory_boost_mb`,
  # `memory_boost_expires_at`). What a boost is, and why it is carved out of the sessions
  # pool rather than added to it, is SessionMemoryBoost.
  #
  # Every surface that changes it routes through here: the web UI's memory-boost control
  # (`PATCH` / `DELETE /sessions/:id/memory_boost`) and the `set_memory_boost` /
  # `clear_memory_boost` MCP actions.
  #
  # The rules:
  # - `memory_mb` is an integer above the ordinary per-session bound and at most
  #   SessionMemoryBoost::MAX_MB, as an Integer or a string of digits.
  # - `hours` is an integer in 1..SessionMemoryBoost::MAX_HOURS; omitted means
  #   SessionMemoryBoost::DEFAULT_HOURS. The boost expires that long from now.
  # - An archived session cannot be boosted, and neither can any session on a deployment
  #   whose pool (ZIMMER_SESSIONS_MEMORY_MAX_MB) leaves no room for one — staging's 1 GiB
  #   pool, today.
  # - One boost at a time: a second session is refused while another holds one, and the
  #   refusal names it. Re-granting the session that already holds it replaces its size
  #   and expiry.
  #
  # It touches only the two columns and one log row, written together. The worker applies
  # the change within a minute (SessionMemoryBoostJob); nothing here touches a cgroup.
  class UpdateMemoryBoost
    class Error < StandardError; end
    # A value is missing or is not an integer.
    class InvalidParameter < Error; end
    # A value is an integer outside its bounds.
    class OutOfRange < Error; end
    # The session cannot take a boost right now: archived, or another session holds one.
    class Refused < Error; end

    ACTOR_LABELS = { web: "", mcp: " via MCP" }.freeze

    # @param session [Session]
    # @param memory_mb [Integer, String]
    # @param hours [Integer, String, nil]
    # @param actor [Symbol] :web or :mcp — named in the log row
    # @return [Session]
    def self.grant(session:, memory_mb:, hours: nil, actor: :web, now: Time.current)
      raise InvalidParameter, "memory_mb must be a positive integer" unless digits?(memory_mb)
      raise InvalidParameter, "hours must be a positive integer" unless hours.blank? || digits?(hours)

      mb = memory_mb.to_i
      unless mb.between?(SessionMemoryBoost.min_mb, SessionMemoryBoost::MAX_MB)
        raise OutOfRange, "memory_mb must be between #{SessionMemoryBoost.min_mb} and #{SessionMemoryBoost::MAX_MB} " \
          "(the ordinary per-session limit is #{SessionMemoryBoost.min_mb - 1} MB)"
      end
      duration = hours.blank? ? SessionMemoryBoost::DEFAULT_HOURS : hours.to_i
      unless duration.between?(1, SessionMemoryBoost::MAX_HOURS)
        raise OutOfRange, "hours must be between 1 and #{SessionMemoryBoost::MAX_HOURS}"
      end
      raise Refused, "An archived session cannot be given a memory boost." if session.archived?

      holder = Session.holding_memory_boost(now).where.not(id: session.id).first
      if holder
        raise Refused, "Session #{holder.id} already holds a memory boost (until " \
          "#{holder.memory_boost_expires_at.utc.iso8601}). Only one session can hold one at a time; " \
          "clear that one first."
      end

      grantable = SessionMemoryBoost.grantable_mb
      if grantable && grantable < SessionMemoryBoost.min_mb
        raise Refused, "This deployment's shared session pool (#{grantable + (SessionMemoryBoost::SHARED_FLOOR_BYTES / SessionMemoryBoost::MIB)} MB) " \
          "cannot pay for a boost above the ordinary #{SessionMemoryBoost.min_mb - 1} MB and still leave the other sessions " \
          "#{SessionMemoryBoost::SHARED_FLOOR_BYTES / SessionMemoryBoost::MIB} MB. A bigger boost needs a bigger pool " \
          "(ZIMMER_SESSIONS_MEMORY_MAX_MB), which is a deploy."
      end

      expires_at = now + duration.hours
      session.transaction do
        SessionMemoryBoost.clear_applied(session)
        session.update!(memory_boost_mb: mb, memory_boost_expires_at: expires_at)
        session.logs.create!(
          content: "Memory boost granted#{ACTOR_LABELS.fetch(actor, '')}: #{mb} MB per-session limit until " \
            "#{expires_at.utc.iso8601}, carved out of the memory every session shares; the worker applies it within a minute",
          level: "info"
        )
      end
      session
    end

    # @param session [Session]
    # @param actor [Symbol]
    # @return [Session]
    def self.clear(session:, actor: :web)
      return session if session.memory_boost_mb.nil? && session.memory_boost_expires_at.nil?

      session.transaction do
        SessionMemoryBoost.clear_applied(session)
        session.update!(memory_boost_mb: nil, memory_boost_expires_at: nil)
        session.logs.create!(
          content: "Memory boost cleared#{ACTOR_LABELS.fetch(actor, '')}; the session returns to the ordinary limit within a minute",
          level: "info"
        )
      end
      session
    end

    def self.digits?(value)
      value.to_s.match?(/\A\d+\z/)
    end
    private_class_method :digits?
  end
end
