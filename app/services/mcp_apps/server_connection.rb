# frozen_string_literal: true

module McpApps
  # Resolves "which MCP server is this, and how does Zimmer talk to it" for one
  # session, and hands back a Client wired with that server's real credentials.
  #
  # The credentials are the session's own, resolved the same way they are for the
  # agent: `${VAR}` interpolation through SecretsInterpolator for a static-header
  # server, and the stored McpOauthCredential (refreshed if it is due) for an OAuth
  # one. That is what lets the browser stay out of it entirely — the view's
  # `tools/call` goes to Rails, and Rails is the only party holding a token.
  #
  # Every gate this feature has is checked here, in one place, so that no caller
  # can reach a server by a route that skipped one:
  #
  #   * the session actually has that server attached;
  #   * an operator has opted that server into MCP Apps (Policy);
  #   * the server is a remote one the catalog knows about.
  class ServerConnection
    class UnavailableError < StandardError; end

    attr_reader :session, :server_name

    # @param session [Session]
    # @param server_name [String] catalog name of an MCP server on that session
    def initialize(session, server_name)
      @session = session
      @server_name = server_name.to_s
    end

    # @raise [UnavailableError] when any gate says no
    # @return [McpApps::Client]
    def client
      @client ||= begin
        authorize!
        Client.new(url: resolved_url, headers: resolved_headers)
      end
    end

    # Whether this session may talk to this server for MCP Apps at all. Cheap —
    # no network, no credential resolution — so it is safe on a render path.
    #
    # @return [Boolean]
    def available?
      authorize!
      true
    rescue UnavailableError
      false
    end

    # @return [ServersConfig::Server, nil]
    def server
      return @server if defined?(@server)

      @server = ServersConfig.find(@server_name)
    end

    private

    def authorize!
      unless session.all_mcp_servers.include?(@server_name)
        raise UnavailableError, "session #{session.id} has no MCP server named #{@server_name}"
      end
      unless Policy.allows?(@server_name)
        raise UnavailableError, "MCP Apps is not enabled for #{@server_name}"
      end
      raise UnavailableError, "unknown MCP server #{@server_name}" if server.nil?
      unless Policy::REMOTE_TYPES.include?(server.type)
        raise UnavailableError, "#{@server_name} is a #{server.type} server; MCP Apps needs a remote one"
      end

      true
    end

    def resolved_url
      interpolator.resolve(server.url.to_s)
    rescue SecretsInterpolator::MissingVariableError => e
      raise UnavailableError, "#{@server_name} url is not resolvable: #{e.message}"
    end

    # Static headers first, then the OAuth bearer if one is stored — an OAuth
    # server has no static credential header to conflict with, and a server that
    # does have one is never OAuth-capable (McpOauthCredentialInjector says so).
    def resolved_headers
      headers = server.headers.to_h.transform_values(&:to_s)
      begin
        interpolator.resolve_hash_values!(headers)
      rescue SecretsInterpolator::MissingVariableError => e
        raise UnavailableError, "#{@server_name} header is not resolvable: #{e.message}"
      end

      token = oauth_access_token
      headers["Authorization"] = "Bearer #{token}" if token.present?
      headers
    end

    def oauth_access_token
      config = ServersConfig.credential_config(@server_name)
      return nil unless config

      key = McpOauthCredential.compute_credential_key(@server_name, config)
      credential = McpOauthCredential.for_credential_key(key).first
      return nil unless credential

      if credential.needs_refresh? && credential.can_refresh?
        begin
          credential.refresh!
        rescue StandardError => e
          Rails.logger.warn("[mcp-apps] token refresh failed for #{@server_name}: #{e.class}")
        end
      end

      credential.active? ? credential.access_token : nil
    end

    def interpolator
      @interpolator ||= SecretsInterpolator.new
    end
  end
end
