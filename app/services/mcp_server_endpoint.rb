# frozen_string_literal: true

# Where and how Zimmer itself reaches a remote catalog MCP server: its URL and
# headers with every `${VAR}` resolved through the secrets chain, plus the stored
# OAuth access token (refreshed when due) as `Authorization: Bearer`.
#
# Shared by the two places the Rails process — rather than an agent CLI — speaks
# to a catalog server: MCP Apps (McpApps::ServerConnection) and the live modes'
# tool bridge (LiveConversations::CatalogServer).
class McpServerEndpoint
  class UnresolvableError < StandardError; end

  attr_reader :server

  def initialize(server, interpolator: SecretsInterpolator.new)
    @server = server
    @interpolator = interpolator
  end

  def url
    @interpolator.resolve(server.url.to_s)
  rescue SecretsInterpolator::MissingVariableError => e
    raise UnresolvableError, "url is not resolvable: #{e.message}"
  end

  def headers
    headers = server.headers.to_h.transform_values(&:to_s)
    begin
      @interpolator.resolve_hash_values!(headers)
    rescue SecretsInterpolator::MissingVariableError => e
      raise UnresolvableError, "header is not resolvable: #{e.message}"
    end

    token = oauth_access_token
    headers["Authorization"] = "Bearer #{token}" if token.present?
    headers
  end

  private

  def oauth_access_token
    config = ServersConfig.credential_config(server.name)
    return nil unless config

    key = McpOauthCredential.compute_credential_key(server.name, config)
    credential = McpOauthCredential.for_credential_key(key).first
    return nil unless credential

    if credential.needs_refresh? && credential.can_refresh?
      begin
        credential.refresh!
      rescue StandardError => e
        Rails.logger.warn("[mcp-endpoint] token refresh failed for #{server.name}: #{e.class}")
      end
    end

    credential.active? ? credential.access_token : nil
  end
end
