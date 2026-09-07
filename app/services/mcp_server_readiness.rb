# frozen_string_literal: true

# The write-side counterpart of McpServerOptions: given the MCP servers a
# session is about to be created with, say which of them Zimmer cannot start
# right now, and what that costs this session.
#
# The read surfaces have said the first half for a while — the Connectors page
# renders it per row, `get_configs` omits unstartable servers from an agent's
# options, and the pickers badge them. The write paths said nothing:
# `Mcp::Tools::StartSession` and `SessionsController#create` checked only that
# each name is in the catalog, so a caller naming a server whose `${VAR}` does
# not resolve got a session that was accepted and then failed at prepare time —
# the slowest and least legible place to find out.
#
# **This warns; it never rejects.** Readiness is a moment in time computed from
# Zimmer's own local view, and that view is deliberately generous about the
# states that mean "could not find out" (`:store_unavailable`, `:probe_failed`
# report as available). Making it authoritative on the spawn path would turn a
# Parameter Store blip into an outage that blocks spawning rather than a badge on
# a page. It would also strand a connection restricted by `allowed_agent_roots`:
# such a caller must pass its root's `default_mcp_servers` exactly, so a reject
# would make that root unspawnable with no legal way to comply. A warning cannot
# wedge anything, and it reaches the caller at the moment it can still act.
#
# The readiness computation is `ConnectorStatusProbe`'s — the same probe and the
# same `Status#available?` the Connectors page renders, `get_configs` partitions
# on and `McpServerOptions` flags with, so the four surfaces cannot disagree
# about which servers cannot start. It probes only the servers the session
# actually names rather than the whole catalog, because this runs on the spawn
# path with a caller waiting, and because the per-server `state` is what makes
# the sentence below honest.
class McpServerReadiness
  # One server the caller asked for that Zimmer cannot start.
  Unavailable = Struct.new(:name, :state, :reason, keyword_init: true)

  class << self
    # Which of these servers cannot start right now.
    #
    # Never raises: a readiness answer is advisory, and a spawn must not fail
    # because the advice could not be computed. `ConnectorStatusProbe#call`
    # already degrades one bad entry to `:probe_failed` rather than raising;
    # this catches everything above that — a catalog that will not resolve at
    # all, a secret provider that blows up outside the probe's own rescue — and
    # reports "nothing to warn about" rather than taking the create down with it.
    #
    # A name that is not in the catalog is skipped rather than reported. Catalog
    # membership is already a Session validation (CatalogArtifactReferences), and
    # telling a caller to go and fix a connector that does not exist is worse
    # than saying nothing.
    #
    # @param server_names [Array<String>, nil] the session's final MCP servers
    # @return [Array<Unavailable>] in the order the caller named them
    def unavailable_among(server_names)
      wanted = Array(server_names).map(&:to_s).reject(&:blank?).uniq
      return [] if wanted.empty?

      # One interpolator across the whole list, exactly as ConnectorStatusProbe.all
      # does it: the Parameter Store link holds a per-instance namespace snapshot,
      # so sharing it makes a multi-server session one read rather than N.
      interpolator = SecretsInterpolator.new

      wanted.filter_map do |name|
        server = ServersConfig.find(name)
        next if server.nil?

        status = ConnectorStatusProbe.new(server, interpolator: interpolator).call
        next if status.available?

        Unavailable.new(name: name, state: status.state, reason: status.unavailable_reason(markdown: false))
      end
    rescue => e
      Rails.logger.warn "[McpServerReadiness] could not check availability: #{e.class}: #{e.message}"
      []
    end

    # The one sentence every write path says, so a human reading a flash and an
    # agent reading a tool result are told the same thing.
    #
    # @param unavailable [Array<Unavailable>]
    # @return [String, nil] nil when every server can start
    def warning_for(unavailable)
      return nil if unavailable.blank?

      # The catalog authors its own `unavailable` reason and tends to end it with a
      # full stop; the probe's own reasons do not. Trimming it keeps the list from
      # reading "(… no OAuth discovery.)." mid-sentence.
      listed = unavailable.map do |entry|
        reason = entry.reason.presence&.strip&.delete_suffix(".")
        reason ? "#{entry.name} (#{reason})" : entry.name
      end
      "Zimmer cannot start #{'MCP server'.pluralize(unavailable.size)} #{listed.to_sentence}. " +
        consequence_for(unavailable)
    end

    # Check and phrase in one call, for a caller that only wants the sentence.
    #
    # @param server_names [Array<String>, nil]
    # @return [String, nil]
    def warning_about(server_names)
      warning_for(unavailable_among(server_names))
    end

    # Warn about a session's own MCP servers, at the moment it is created.
    #
    # Reads the session's *resolved* list rather than whatever the caller
    # passed, so it covers the case the caller cannot see: an agent root whose
    # `default_mcp_servers` carries an unstartable server, inherited by a spawn
    # that named no servers at all. That is also the restricted-connection case
    # — such a caller is required to pass its root's defaults exactly, so if one
    # of them is unavailable the warning is the only thing it can be given.
    #
    # The warning is written to the session's own log as well as returned. The
    # log is where both the human and the agent still find it after a flash has
    # faded and a tool result has scrolled away, and it sits next to the prepare
    # failure it predicts.
    #
    # Every step is guarded, including reading the server list — that read walks
    # the session's plugins into the catalog, so it is not the plain column
    # access it looks like, and an exception escaping here would 500 a create
    # whose row is already committed and whose agent job is already queued.
    #
    # @param session [Session] a persisted session
    # @return [String, nil] nil when every server can start
    def warn_for_session(session)
      warning =
        begin
          warning_about(session.user_selected_mcp_servers)
        rescue => e
          Rails.logger.warn "[McpServerReadiness] could not read the session's MCP servers " \
                            "(session=#{session.id}): #{e.class}: #{e.message}"
          nil
        end
      return nil if warning.nil?

      begin
        session.logs.create!(content: warning, level: "warning")
      rescue => e
        Rails.logger.warn "[McpServerReadiness] could not log availability warning " \
                          "(session=#{session.id}): #{e.class}: #{e.message}"
      end

      warning
    end

    private

    # What being unable to start actually costs THIS session, which is not the
    # same for all four of ConnectorStatusProbe::BLOCKING_STATES — and saying it
    # was would contradict two first-class flows:
    #
    #   :missing_configuration — `air prepare` exits 1 on the unresolved `${VAR}`
    #     (AirPrepareService::UNRESOLVED_VARIABLE_PATTERN), so the WHOLE session
    #     fails before the agent runs. The expensive one, and the reason this
    #     warning exists.
    #   :needs_authorization / :needs_reauth — prepare succeeds; AgentSessionJob's
    #     pre-spawn OAuth gate parks the session with Authorize buttons on its
    #     page. A designed flow, not a failure.
    #   :declared_unavailable — nothing local stops the session. The server does
    #     not connect and AgentSessionJob leaves the SERVER out, not the session.
    #
    # The worst state present is the one named. It is the one the caller has to
    # act on, and stacking three clauses onto a flash toast helps nobody.
    def consequence_for(unavailable)
      states = unavailable.map(&:state)

      if states.include?(:missing_configuration)
        "The session was created anyway, but preparing it is expected to fail outright until the " \
        "missing value is set — /connectors names the variable and where it goes."
      elsif states.intersect?(%i[needs_authorization needs_reauth])
        "The session was created anyway, but it will park for OAuth authorization before the agent " \
        "runs — authorize it at /connectors."
      else
        "The session was created anyway and will run without those tools; the catalog entry has to " \
        "change, and nothing at /connectors will fix it."
      end
    end
  end
end
