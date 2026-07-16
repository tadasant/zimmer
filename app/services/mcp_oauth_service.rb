# Service for handling MCP OAuth flows.
#
# This service handles OAuth operations for MCP servers:
# - OAuth metadata discovery (RFC 9728 / RFC 8414)
# - Dynamic Client Registration (RFC 7591)
# - Token exchange
# - Checking if servers require OAuth
#
# Usage:
#   service = McpOauthService.new
#   if service.requires_oauth?(server_url)
#     metadata = service.fetch_oauth_metadata(server_url)
#     # ... initiate OAuth flow
#   end
class McpOauthService
  # Request timeout in seconds
  REQUEST_TIMEOUT = 30

  # User agent for OAuth requests
  USER_AGENT = "Zimmer/1.0".freeze

  # Result of checking a server's OAuth requirements
  OAuthRequirement = Struct.new(:required, :metadata, :error, keyword_init: true)

  # OAuth metadata from a server
  OAuthMetadata = Struct.new(
    :authorization_endpoint,
    :token_endpoint,
    :registration_endpoint,
    :scopes_supported,
    :client_id,
    :client_secret,
    :resource,
    keyword_init: true
  )

  # Checks if an MCP server requires OAuth authentication.
  # Probes the server with a request and checks for 401 with OAuth metadata.
  #
  # @param server_url [String] The MCP server URL
  # @param configured_client_id [String, nil] Statically-configured OAuth client
  #   id for this server (from the catalog `oauth` block). When present it is used
  #   in place of Dynamic Client Registration and the `agent-orchestrator` fallback.
  # @param configured_client_secret [String, nil] Optional client secret paired
  #   with the configured client id (confidential clients only).
  # @return [OAuthRequirement] Result with :required, :metadata, and :error
  def check_oauth_requirement(server_url, configured_client_id: nil, configured_client_secret: nil)
    # First try to fetch protected resource metadata (RFC 9728)
    metadata = fetch_oauth_metadata(server_url, configured_client_id: configured_client_id, configured_client_secret: configured_client_secret)
    if metadata
      return OAuthRequirement.new(required: true, metadata: metadata, error: nil)
    end

    # Probe the server with a request to check for 401
    probe_result = probe_server_for_oauth(server_url, configured_client_id: configured_client_id, configured_client_secret: configured_client_secret)
    probe_result
  rescue => e
    Rails.logger.error "[McpOauthService] Error checking OAuth requirement for #{server_url}: #{e.message}"
    OAuthRequirement.new(required: false, metadata: nil, error: e.message)
  end

  # Fetches OAuth metadata from a server using RFC 9728 and RFC 8414 discovery.
  #
  # Discovery order:
  # 1. RFC 8414: /.well-known/oauth-authorization-server (OAuth Authorization Server Metadata)
  # 2. RFC 9728: /.well-known/oauth-protected-resource (Protected Resource Metadata)
  #
  # @param server_url [String] The MCP server URL
  # @param configured_client_id [String, nil] Statically-configured OAuth client
  #   id (see {#check_oauth_requirement}).
  # @param configured_client_secret [String, nil] Optional configured client secret.
  # @return [OAuthMetadata, nil] OAuth metadata if found, nil otherwise
  def fetch_oauth_metadata(server_url, configured_client_id: nil, configured_client_secret: nil)
    uri = URI(server_url)
    base_url = "#{uri.scheme}://#{uri.host}#{uri.port != uri.default_port ? ":#{uri.port}" : ""}"

    # Fetch Protected Resource Metadata (RFC 9728) up front to capture the
    # canonical `resource` identifier for RFC 8707 audience binding. We read it
    # regardless of whether RFC 8414 also resolves the authorization server,
    # because servers that enforce audience binding (e.g. Notion) reject tokens
    # minted without a matching resource indicator.
    protected_resource = fetch_json("#{base_url}/.well-known/oauth-protected-resource")
    resource = protected_resource&.dig("resource")

    # Try RFC 8414 directly at the MCP server URL first
    # This works when the MCP server IS the authorization server (e.g., Linear)
    auth_server = fetch_authorization_server_metadata(base_url)
    scopes_supported = auth_server&.dig("scopes_supported")

    # If RFC 8414 didn't work, resolve the authorization server via the
    # Protected Resource Metadata (RFC 9728) we already fetched.
    if auth_server.nil? && protected_resource && protected_resource["authorization_servers"]&.any?
      auth_server_url = protected_resource["authorization_servers"].first
      auth_server = fetch_authorization_server_metadata(auth_server_url)
      scopes_supported = protected_resource["scopes_supported"] || auth_server&.dig("scopes_supported")
    end

    return nil unless auth_server

    # Prefer the PRM-advertised resource; fall back to the canonical MCP server
    # URL so the resource indicator is always present (RFC 8707).
    resource = canonical_resource(resource, server_url)

    # Resolve the client_id. A statically-configured client id (from the server's
    # catalog `oauth` block) takes precedence over Dynamic Client Registration and
    # over the `agent-orchestrator` fallback: servers like Slack require a
    # pre-registered client and expose no DCR endpoint we can use, so a
    # freshly-registered or placeholder client id would always be rejected.
    client_id = nil
    client_secret = nil
    dcr_attempted = false

    if configured_client_id.present?
      client_id = configured_client_id
      client_secret = configured_client_secret
    elsif auth_server["registration_endpoint"]
      dcr_attempted = true
      dcr_result = perform_dcr(auth_server["registration_endpoint"], server_url, auth_server_metadata: auth_server)
      if dcr_result
        client_id = dcr_result["client_id"]
        client_secret = dcr_result["client_secret"]
      else
        Rails.logger.warn "[McpOauthService] DCR failed for #{auth_server['registration_endpoint']} - server requires registration but registration failed"
      end
    end

    # Only use fallback client_id if neither a configured client nor DCR produced one.
    # If DCR was attempted but failed, return nil client_id so the caller can handle the error
    # Using a fake client_id when the server expects registered clients will always fail
    client_id ||= "agent-orchestrator" unless dcr_attempted

    OAuthMetadata.new(
      authorization_endpoint: auth_server["authorization_endpoint"],
      token_endpoint: auth_server["token_endpoint"],
      registration_endpoint: auth_server["registration_endpoint"],
      scopes_supported: scopes_supported || auth_server["scopes_supported"],
      client_id: client_id,
      client_secret: client_secret,
      resource: resource
    )
  end

  # Returns the RFC 8707 resource indicator: the canonical resource identifier
  # the MCP server expects. Prefers the value advertised in the server's
  # Protected Resource Metadata (RFC 9728); falls back to the MCP server's
  # canonical URL (scheme + host + port + path, minus query/fragment and any
  # trailing slash) when the PRM omits it.
  #
  # @param prm_resource [String, nil] the `resource` field from RFC 9728 metadata
  # @param server_url [String] the MCP server URL
  # @return [String] the canonical resource identifier
  def canonical_resource(prm_resource, server_url)
    return prm_resource if prm_resource.present?

    uri = URI(server_url)
    port = (uri.port && uri.port != uri.default_port) ? ":#{uri.port}" : ""
    path = uri.path.to_s.chomp("/")
    "#{uri.scheme}://#{uri.host}#{port}#{path}"
  rescue URI::Error
    server_url
  end

  # Fetches authorization server metadata from the given URL.
  #
  # @param auth_server_url [String] The authorization server URL
  # @return [Hash, nil] The metadata if found, nil otherwise
  def fetch_authorization_server_metadata(auth_server_url)
    uri = URI(auth_server_url)
    base_url = "#{uri.scheme}://#{uri.host}#{uri.port != uri.default_port ? ":#{uri.port}" : ""}"

    # Try RFC 8414 well-known endpoint
    metadata = fetch_json("#{base_url}/.well-known/oauth-authorization-server")
    return metadata if metadata && (metadata["authorization_endpoint"] || metadata["token_endpoint"])

    # Try OpenID Connect discovery as fallback
    metadata = fetch_json("#{auth_server_url}/.well-known/openid-configuration")
    return metadata if metadata && (metadata["authorization_endpoint"] || metadata["token_endpoint"])

    nil
  end

  # Performs Dynamic Client Registration (RFC 7591).
  #
  # @param registration_endpoint [String] The DCR endpoint URL
  # @param server_url [String] The MCP server URL (for redirect URI)
  # @param auth_server_metadata [Hash] The authorization server metadata (from RFC 8414 discovery)
  # @return [Hash, nil] DCR response with client_id, or nil if failed
  def perform_dcr(registration_endpoint, server_url, auth_server_metadata: {})
    # Build redirect URI - use the app's OAuth callback endpoint
    redirect_uri = build_redirect_uri

    # Pick a token_endpoint_auth_method supported by the server.
    # Preference order: "none" (public client), "client_secret_post" (matches our token exchange
    # which uses POST body params), then first available method as fallback.
    supported_auth_methods = auth_server_metadata["token_endpoint_auth_methods_supported"]
    auth_method = if supported_auth_methods.is_a?(Array) && supported_auth_methods.any?
      if supported_auth_methods.include?("none")
        "none"
      elsif supported_auth_methods.include?("client_secret_post")
        "client_secret_post"
      else
        supported_auth_methods.first
      end
    else
      "none"
    end

    body = {
      redirect_uris: [ redirect_uri ],
      client_name: "Claude Code (Zimmer)",
      grant_types: [ "authorization_code", "refresh_token" ],
      response_types: [ "code" ],
      token_endpoint_auth_method: auth_method
    }

    # Include scopes if the server advertises them — some servers require this in DCR
    scopes = auth_server_metadata["scopes_supported"]
    if scopes.is_a?(Array) && scopes.any?
      body[:scope] = scopes.join(" ")
    end

    response = post_json(registration_endpoint, body)
    return nil unless response && response["client_id"]

    response
  rescue => e
    Rails.logger.warn "[McpOauthService] DCR failed for #{registration_endpoint}: #{e.message}"
    nil
  end

  # Exchanges an authorization code for tokens.
  #
  # @param pending_flow [McpOauthPendingFlow] The pending OAuth flow
  # @param code [String] The authorization code from the OAuth callback
  # @return [Hash, nil] Token response with access_token, or nil if failed
  def exchange_code_for_tokens(pending_flow, code)
    params = {
      grant_type: "authorization_code",
      code: code,
      redirect_uri: pending_flow.redirect_uri,
      code_verifier: pending_flow.code_verifier,
      client_id: pending_flow.client_id
    }

    params[:client_secret] = pending_flow.client_secret if pending_flow.client_secret.present?

    # RFC 8707 resource indicator — binds the issued token's audience to the MCP
    # resource server. Required by servers that enforce audience binding (Notion).
    params[:resource] = pending_flow.resource if pending_flow.resource.present?

    uri = URI(pending_flow.token_endpoint)
    response = Net::HTTP.post_form(uri, params)

    if response.code == "200"
      parse_token_response(response)
    else
      Rails.logger.error "[McpOauthService] Token exchange failed: #{response.code} - #{response.body}"
      nil
    end
  rescue => e
    Rails.logger.error "[McpOauthService] Token exchange error: #{e.message}"
    nil
  end

  # Builds the redirect URI for OAuth callbacks.
  # Uses the configured application host or falls back to localhost for development.
  #
  # @return [String] The redirect URI
  def build_redirect_uri
    host = ENV.fetch("APP_HOST") { "localhost:3000" }
    scheme = host.include?("localhost") ? "http" : "https"
    "#{scheme}://#{host}/mcp_oauth/callback"
  end

  private

  # Probes a server for OAuth requirement by making a request and checking response
  def probe_server_for_oauth(server_url, configured_client_id: nil, configured_client_secret: nil)
    uri = URI(server_url)

    # Make a GET request to see if the server requires auth
    # We use GET instead of OPTIONS because some servers (like Linear)
    # only return 401 on actual resource requests, not OPTIONS
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = REQUEST_TIMEOUT
    http.read_timeout = REQUEST_TIMEOUT

    request = Net::HTTP::Get.new(uri.request_uri)
    request["User-Agent"] = USER_AGENT
    request["Accept"] = "application/json"

    response = http.request(request)

    # Check for 401 with WWW-Authenticate header
    if response.code == "401"
      www_auth = response["WWW-Authenticate"]
      if www_auth&.include?("Bearer")
        # Server requires OAuth - try to extract resource_metadata URL
        resource_metadata_url = extract_resource_metadata_url(www_auth)
        if resource_metadata_url
          metadata = fetch_oauth_metadata_from_url(resource_metadata_url, server_url: server_url, configured_client_id: configured_client_id, configured_client_secret: configured_client_secret)
          if metadata
            return OAuthRequirement.new(required: true, metadata: metadata, error: nil)
          end
        end

        # Fall back to standard discovery
        metadata = fetch_oauth_metadata(server_url, configured_client_id: configured_client_id, configured_client_secret: configured_client_secret)
        return OAuthRequirement.new(required: true, metadata: metadata, error: nil)
      end
    end

    OAuthRequirement.new(required: false, metadata: nil, error: nil)
  rescue => e
    Rails.logger.warn "[McpOauthService] Probe failed for #{server_url}: #{e.message}"
    OAuthRequirement.new(required: false, metadata: nil, error: e.message)
  end

  # Extracts resource_metadata URL from WWW-Authenticate header
  def extract_resource_metadata_url(www_auth)
    match = www_auth.match(/resource_metadata="([^"]+)"/)
    return nil unless match

    url = match[1].strip
    return nil if url.empty?
    return nil unless url.start_with?("http://", "https://")

    url
  end

  # Fetches OAuth metadata from a specific resource_metadata URL
  def fetch_oauth_metadata_from_url(resource_metadata_url, server_url:, configured_client_id: nil, configured_client_secret: nil)
    protected_resource = fetch_json(resource_metadata_url)
    return nil unless protected_resource && protected_resource["authorization_servers"]&.any?

    auth_server_url = protected_resource["authorization_servers"].first
    auth_server = fetch_authorization_server_metadata(auth_server_url)
    return nil unless auth_server

    # Capture the RFC 8707 resource indicator (PRM-advertised, with canonical
    # MCP-server-URL fallback) the same way the primary discovery path does.
    resource = canonical_resource(protected_resource["resource"], server_url)

    # Resolve the client_id. A statically-configured client id takes precedence
    # over DCR and the `agent-orchestrator` fallback (see {#fetch_oauth_metadata}).
    client_id = nil
    client_secret = nil
    dcr_attempted = false

    if configured_client_id.present?
      client_id = configured_client_id
      client_secret = configured_client_secret
    elsif auth_server["registration_endpoint"]
      dcr_attempted = true
      dcr_result = perform_dcr(auth_server["registration_endpoint"], resource_metadata_url, auth_server_metadata: auth_server)
      if dcr_result
        client_id = dcr_result["client_id"]
        client_secret = dcr_result["client_secret"]
      else
        Rails.logger.warn "[McpOauthService] DCR failed for #{auth_server['registration_endpoint']} (from resource metadata) - server requires registration but registration failed"
      end
    end

    # Only use fallback client_id if neither a configured client nor DCR produced one.
    # If DCR was attempted but failed, return nil client_id so the caller can handle the error
    client_id ||= "agent-orchestrator" unless dcr_attempted

    OAuthMetadata.new(
      authorization_endpoint: auth_server["authorization_endpoint"],
      token_endpoint: auth_server["token_endpoint"],
      registration_endpoint: auth_server["registration_endpoint"],
      scopes_supported: protected_resource["scopes_supported"] || auth_server["scopes_supported"],
      client_id: client_id,
      client_secret: client_secret,
      resource: resource
    )
  end

  # Fetches JSON from a URL with timeout
  def fetch_json(url)
    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = REQUEST_TIMEOUT
    http.read_timeout = REQUEST_TIMEOUT

    request = Net::HTTP::Get.new(uri.request_uri)
    request["Accept"] = "application/json"
    request["User-Agent"] = USER_AGENT

    response = http.request(request)
    return nil unless response.code == "200"

    JSON.parse(response.body)
  rescue => e
    Rails.logger.debug "[McpOauthService] Failed to fetch #{url}: #{e.message}"
    nil
  end

  # Posts JSON to a URL
  def post_json(url, body)
    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = REQUEST_TIMEOUT
    http.read_timeout = REQUEST_TIMEOUT

    request = Net::HTTP::Post.new(uri.request_uri)
    request["Content-Type"] = "application/json"
    request["Accept"] = "application/json"
    request["User-Agent"] = USER_AGENT
    request.body = body.to_json

    response = http.request(request)
    unless response.code == "200" || response.code == "201"
      Rails.logger.warn "[McpOauthService] POST #{url} returned #{response.code}: #{response.body}"
      return nil
    end

    JSON.parse(response.body)
  rescue => e
    Rails.logger.debug "[McpOauthService] Failed to POST #{url}: #{e.message}"
    nil
  end

  # Parses token response, handling both JSON and URL-encoded formats
  def parse_token_response(response)
    body = response.body
    content_type = response["Content-Type"]

    # Try JSON first
    if content_type&.include?("application/json") || body.start_with?("{")
      begin
        return JSON.parse(body)
      rescue JSON::ParserError
        # Fall through to URL-encoded
      end
    end

    # Try URL-encoded format
    if content_type&.include?("application/x-www-form-urlencoded") || body.include?("=")
      begin
        parsed = URI.decode_www_form(body).to_h
        return parsed if parsed["access_token"]
      rescue ArgumentError
        # Fall through
      end
    end

    nil
  end
end
