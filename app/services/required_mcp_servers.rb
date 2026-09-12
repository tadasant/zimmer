# frozen_string_literal: true

# The MCP servers a session cannot be left running without.
#
# [#521](https://github.com/tadasant/zimmer/issues/521) settled the general case:
# a handshake that fails costs the *capability*, not the session, so
# `AgentSessionJob` leaves the server out and the session runs on. That is right
# for every server whose tools the work merely uses, and it is wrong for exactly
# one class — the one that carries the session's own lifecycle.
#
# Zimmer's self-session surface is that class. `action_session` is how a session
# archives itself and how it reaches its parent; `wake_me_up_later` and
# `wake_me_up_when_session_changes_state` are how it waits; `get_session` is how
# it reads what a child it spawned transitioned to; the full-surface entry adds
# `start_session`, which is how a router creates the work it exists to create.
# None of that is a tool the work uses. It is how the session ends, hands off,
# and waits.
#
# So losing one of these is not a degradation, it is a session that fails soft in
# the worst way: it looks healthy, runs to completion, and does nothing. An alert
# router with no `start_session` reads the alert, posts a comment and parks,
# having started none of the triage the trigger fired for — four consecutive
# times, on one alert. An orchestrator woken mid-wait-loop cannot read what its
# child transitioned to and cannot re-register the wake that firing just spent,
# so the child runs unwatched with nobody following it up
# ([#1166](https://github.com/tadasant/zimmer/issues/1166)).
#
# ## What counts
#
# A Zimmer-native MCP entry whose endpoint carries the `self_session` tool group
# — either scoped to it, or unscoped and therefore full-surface. Nothing else:
# `zimmer-fleet`, `zimmer-sessions`, `zimmer-gate-decisions` and friends are
# scoped to tool groups that do not include it, and losing one of those costs a
# capability the session can report and work around, which is exactly what #521
# is for.
#
# "Zimmer-native" is decided by NAME, not by URL — `SelfSessionInjector`'s own
# rule, so a third-party server that happens to be served at some `/mcp` cannot
# be mistaken for one of ours. The tool groups come from the catalog entry's URL
# where there is one, and from the injector's own knowledge of what it writes
# where there is not (the two auto-injected entries are not catalog rows on every
# deployment).
#
# ## What it does when it cannot read the catalog
#
# The catalog is a subprocess away (`AirCatalogService` shells out to `air
# resolve`) and degrades to an empty list rather than raising, so "no entry for
# this name" and "no catalog at all" arrive here identically. Both fall back to
# the injector's own knowledge, which is the point: Zimmer WROTE those two
# entries and does not need a catalog to know what is in them, so a catalog blip
# cannot quietly reclassify a session's own lifecycle surface as optional.
#
# Every other `zimmer-*` name answers `false` when the catalog cannot be read —
# there is nothing else to go on, and the consequence of this predicate saying
# `true` is a failed session. A wrong `false` reproduces the behaviour that was
# already there; a wrong `true` kills sessions.
class RequiredMcpServers
  # The tool group that makes an entry a session's own lifecycle surface. An
  # entry scoped to it, or scoped to nothing at all (the full surface includes
  # every group), carries `action_session` and the wake tools.
  SELF_SESSION_TOOL_GROUP = "self_session"

  class << self
    # @param server_name [String, nil] an MCP server name as it appears in a
    #   session's `mcp_servers` / `injected_mcp_servers`
    # @return [Boolean] true when losing this server costs the session its own
    #   lifecycle, rather than a capability it can work around
    def required?(server_name)
      name = server_name.to_s
      return false if name.blank?
      return false unless SelfSessionInjector.zimmer_server_name?(name)

      groups = tool_groups_for(name)
      return false if groups.nil?

      groups.empty? || groups.include?(SELF_SESSION_TOOL_GROUP)
    rescue => e
      # Nothing below is expected to raise — the catalog read has its own rescue
      # — so this is the backstop for the unforeseen. Say "not required" and
      # leave the caller on the #521 path it would have taken anyway.
      Rails.logger.warn "[RequiredMcpServers] could not classify #{server_name.inspect}: #{e.class}: #{e.message}"
      false
    end

    # @param server_names [Array<String>, nil]
    # @return [Array<String>] those of them that are required, in the order given
    def among(server_names)
      Array(server_names).select { |name| required?(name) }
    end

    private

    # The tool groups this entry's endpoint is scoped to.
    #
    # The catalog first, because a deployment's own entry is the authority on
    # what its own endpoint serves. The injector's knowledge second, for the two
    # entries `RuntimeConfigPostProcessor` writes itself — which is also what
    # answers when the catalog cannot be read at all.
    #
    # @return [Array<String>, nil] `[]` for the full surface, nil when there is
    #   no way to tell
    def tool_groups_for(name)
      url = catalog_url(name)
      return SelfSessionInjector.tool_groups_in(url) if url

      case name
      when SelfSessionInjector::SELF_SESSION_SERVER_NAME then [ SELF_SESSION_TOOL_GROUP ]
      when SelfSessionInjector::SUBAGENT_SERVER_NAME then []
      end
    end

    # This entry's URL, only when there really is one and it can be read.
    #
    # A URL that will not parse is not a scope Zimmer can reason about, and
    # `SelfSessionInjector.tool_groups_in` reports one as `[]` — the full
    # surface, which is the *most* required answer there is. Returning nil sends
    # it to the name fallback instead.
    #
    # @return [String, nil]
    def catalog_url(name)
      url = ServersConfig.find(name)&.url
      return nil if url.blank?

      URI.parse(url)
      url
    rescue => e
      Rails.logger.warn "[RequiredMcpServers] could not read the catalog entry for " \
                        "#{name.inspect}: #{e.class}: #{e.message}"
      nil
    end
  end
end
