# frozen_string_literal: true

module McpApps
  # A ceiling on how often one session's views may make Zimmer do work on their
  # behalf.
  #
  # A view is a loop with a network call in it. Nothing in the protocol stops one
  # from calling `tools/call` on every animation frame, or from sending the agent
  # a message per click — and the cost of either lands on somebody else: the MCP
  # server's rate limit, the operator's API bill, or a session's queue filling
  # with messages nobody asked for. The per-server allowlist decides whose code
  # runs; this decides how much of Zimmer's time that code may spend.
  #
  # Deliberately fail-open. It is backed by Rails.cache, and Zimmer's production
  # cache store swallows a Redis outage by returning nil rather than raising — so
  # a degraded cache must leave a working feature working, not silently switch the
  # panel off. The allowlist is the control that has to hold under every
  # condition; this one is a brake, and a brake that fails open is the right
  # trade for a UI a human is sitting in front of.
  class RequestThrottle
    WINDOW = 1.minute

    # Per session, per window. A human clicking around a widget produces a few
    # calls a minute; a loop produces thousands. The number only has to sit
    # between those.
    LIMIT = 60

    class << self
      # @param session [Session]
      # @param kind [String] which bucket — proxied requests and agent messages
      #   are counted separately, so a chatty widget cannot spend the quota that
      #   keeps the agent reachable
      # @return [Boolean] true when the caller is within its allowance
      def allow?(session, kind)
        key = [ "mcp_apps", "throttle", kind, session.id, Time.current.to_i / WINDOW.to_i ].join(":")
        count = Rails.cache.increment(key, 1, expires_in: WINDOW * 2)

        # nil means the store could not answer — no counter, no opinion.
        return true if count.nil?

        count <= LIMIT
      end
    end
  end
end
