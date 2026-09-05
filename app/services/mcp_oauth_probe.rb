# frozen_string_literal: true

# Answers one question about a session: which of its MCP servers still need a
# human to authorize them?
#
# It is what puts the Authorize buttons on the session page after an MCP-server
# or plugin change, without waiting for a spawn to fail.
#
# It reads the session as it stands, so callers write the new selection first and
# probe after — Sessions::UpdateCatalogSelection does exactly that. There is no
# "probe this list instead" variant: assigning a list onto the record just to ask
# about it, and unassigning it in an `ensure`, is a second code path that can
# disagree with the first.
#
# It reads nothing from the clone's `.mcp.json`: server URLs and
# headers come from the catalog (`ServersConfig`) and tokens from
# `McpOauthCredential`, so the answer does not depend on whether the session's
# runtime config has been regenerated since the change.
#
#   McpOauthProbe.new(session).servers_needing_oauth
#   # => [{ server_name:, server_url:, credential_key:, ... }, ...]
class McpOauthProbe
  # Wall-clock budget for the network half of the probe.
  #
  # Answering "does this server require OAuth?" for a server we hold no
  # pre-registered client for means asking the server, and McpOauthService gives
  # each of those requests 30 seconds. A session may select up to 50 servers, so
  # without a budget an unreachable host — or a handful of them — turns a
  # config edit into a multi-minute request on whichever surface issued it.
  #
  # Running out is not an error: a server we could not reach in time is reported
  # as not needing OAuth, exactly as an individual failed probe already is. The
  # spawn gate asks again before the session next runs, and it is not racing a
  # caller who is waiting.
  PROBE_BUDGET_SECONDS = 20

  def initialize(session, oauth_service: McpOauthService.new, budget_seconds: PROBE_BUDGET_SECONDS)
    @session = session
    @oauth_service = oauth_service
    @budget_seconds = budget_seconds
  end

  # @return [Array<Hash>] one entry per server that cannot be used until someone
  #   authorizes it; empty when everything is already authorized, when the
  #   session selects no servers, or when it has no clone to check tokens against
  def servers_needing_oauth
    return [] if @session.user_selected_mcp_servers.blank?

    working_directory = @session.metadata&.dig("working_directory")
    return [] if working_directory.blank?

    # The same check AgentSessionJob runs before it spawns, so the page and the
    # spawn gate cannot disagree about which servers are ready.
    status = McpOauthCredentialInjector.new(@session, working_directory: working_directory).check_credentials_status
    return [] if status.empty?

    @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @budget_seconds
    status.filter_map { |server_name, server_status| requirement_for(server_name, server_status) }
  end

  private

  def budget_exhausted?
    @deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= @deadline
  end

  def requirement_for(server_name, server_status)
    return nil if server_status[:has_credential] && server_status[:credential_valid]

    server_url = server_status[:server_url]
    return nil if server_url.blank?

    # A server whose token has to be re-minted, and one whose catalog entry
    # pre-registers an OAuth client, are both known to need a flow — no probe.
    if server_status[:requires_reauth] || server_status[:has_preregistered_oauth]
      return {
        server_name: server_name,
        server_url: server_url,
        credential_key: server_status[:credential_key],
        preregistered_oauth: server_status[:preregistered_oauth_config]
      }
    end

    probe(server_name, server_url, server_status[:credential_key])
  end

  # Ask the server itself whether it requires OAuth. Passes through the
  # statically-configured client (catalog `oauth` block) so the resolved metadata
  # carries the pre-registered client rather than the fallback literal, and the
  # configured redirect so any registration this probe performs names the
  # redirect the authorization flow will actually send.
  def probe(server_name, server_url, credential_key)
    if budget_exhausted?
      Rails.logger.warn "[McpOauthProbe] Budget spent before probing '#{server_name}'; reporting it as not needing OAuth"
      return nil
    end

    catalog_server = ServersConfig.find(server_name)
    requirement = @oauth_service.check_oauth_requirement(
      server_url,
      configured_client_id: catalog_server&.oauth_client_id,
      configured_client_secret: catalog_server&.oauth_client_secret,
      configured_redirect_uri: catalog_server&.oauth_redirect_uri
    )
    return nil unless requirement.required

    {
      server_name: server_name,
      server_url: server_url,
      credential_key: credential_key,
      oauth_metadata: requirement.metadata
    }
  rescue => e
    # A probe that cannot reach the server says nothing about whether it needs
    # OAuth, and blocking the edit on that would be worse than missing a banner.
    Rails.logger.warn "[McpOauthProbe] Failed to check OAuth for '#{server_name}': #{e.message}"
    nil
  end
end
