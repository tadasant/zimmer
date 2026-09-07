# frozen_string_literal: true

# The write-side counterpart of McpServerOptions: given the MCP servers a
# session is about to be created with, say which of them Zimmer cannot start
# right now, and in what words.
#
# The read surfaces have said this for a while — the Connectors page renders it
# per row, `get_configs` omits unstartable servers from an agent's options, and
# the pickers badge them. The write paths said nothing: `Mcp::Tools::StartSession`
# and `SessionsController#create` checked only that each name is in the catalog,
# so a caller naming a server whose `${VAR}` does not resolve got a session that
# was accepted and then failed at prepare time — the slowest and least legible
# place to find out.
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
# The readiness computation itself is `ConnectorStatusProbe`'s, read through
# `McpServerOptions` so this shares that class's request-scoped memo and its
# fallback — the same numbers the picker shows, never a second opinion.
class McpServerReadiness
  # One server the caller asked for that Zimmer cannot start.
  Unavailable = Struct.new(:name, :reason, keyword_init: true)

  class << self
    # Which of these servers cannot start right now.
    #
    # Never raises: a readiness answer is advisory, and a spawn must not fail
    # because the advice could not be computed. `McpServerOptions.build` already
    # degrades a broken probe to a flagless list; this catches the residue (a
    # catalog that will not resolve at all) and reports "nothing to warn about"
    # rather than taking the create down with it.
    #
    # @param server_names [Array<String>, nil] the session's final MCP servers
    # @return [Array<Unavailable>] in the order the caller named them
    def unavailable_among(server_names)
      wanted = Array(server_names).map(&:to_s).reject(&:blank?)
      return [] if wanted.empty?

      by_name = McpServerOptions.all.index_by { |option| option[:name] }

      wanted.filter_map do |name|
        option = by_name[name]
        next unless option && option[:unavailable]

        Unavailable.new(name: name, reason: option[:unavailable_reason])
      end
    rescue => e
      Rails.logger.warn "[McpServerReadiness] could not check availability: #{e.class}: #{e.message}"
      []
    end

    # The one sentence both write paths say, so a human reading a flash and an
    # agent reading a tool result are told the same thing.
    #
    # @param unavailable [Array<Unavailable>]
    # @return [String, nil] nil when every server can start
    def warning_for(unavailable)
      return nil if unavailable.blank?

      listed = unavailable.map { |entry| entry.reason.present? ? "#{entry.name} (#{entry.reason})" : entry.name }
      "Zimmer cannot start #{'MCP server'.pluralize(unavailable.size)} #{listed.to_sentence} right now. " \
        "The session was created anyway, but preparing it is expected to fail until " \
        "#{unavailable.one? ? 'that server is' : 'those servers are'} fixed at /connectors — " \
        "or the session is started without #{unavailable.one? ? 'it' : 'them'}."
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
    # @param session [Session] a persisted session
    # @return [String, nil] nil when every server can start
    def warn_for_session(session)
      warning = warning_about(session.user_selected_mcp_servers)
      return nil if warning.nil?

      begin
        session.logs.create!(content: warning, level: "warning")
      rescue => e
        Rails.logger.warn "[McpServerReadiness] could not log availability warning " \
                          "(session=#{session.id}): #{e.class}: #{e.message}"
      end

      warning
    end
  end
end
