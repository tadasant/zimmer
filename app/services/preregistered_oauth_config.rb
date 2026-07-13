# frozen_string_literal: true

# Service class for loading pre-registered OAuth client configurations from Rails credentials.
#
# Pre-registered OAuth is used for OAuth providers that don't support Dynamic Client Registration (DCR)
# or OAuth metadata discovery (RFC 8414/9728). When OAuth client credentials are configured in Rails
# credentials, the OAuth flow should be triggered before starting sessions, regardless of what the
# server probe returns.
#
# Credentials format (in config/credentials/{environment}.yml.enc):
#   mcp_oauth_clients:
#     bigquery-example:
#       client_id: "your-client-id.apps.googleusercontent.com"
#       client_secret: "GOCSPX-your-client-secret"
#       authorization_endpoint: "https://accounts.google.com/o/oauth2/v2/auth"
#       token_endpoint: "https://oauth2.googleapis.com/token"
#       scopes: "https://www.googleapis.com/auth/bigquery"
#
# Required fields: client_id, client_secret, authorization_endpoint, token_endpoint
# Optional fields: scopes
#
# The key under mcp_oauth_clients must exactly match the server name (e.g., "bigquery-example").
# Google OAuth automatically adds access_type=offline and prompt=consent for refresh tokens
# (detected via authorization_endpoint containing google.com).
class PreregisteredOauthConfig
  # OAuth client configuration
  class OAuthClient
    attr_reader :key, :client_id, :client_secret, :authorization_endpoint, :token_endpoint, :scopes

    def initialize(key:, client_id:, client_secret:, authorization_endpoint:, token_endpoint:, scopes: nil)
      @key = key
      @client_id = client_id
      @client_secret = client_secret
      @authorization_endpoint = authorization_endpoint
      @token_endpoint = token_endpoint
      @scopes = scopes
    end

    def to_h
      {
        key: key,
        client_id: client_id,
        client_secret: client_secret,
        authorization_endpoint: authorization_endpoint,
        token_endpoint: token_endpoint,
        scopes: scopes
      }
    end

    # Returns a hash without sensitive data (client_secret) for status/logging
    def to_public_h
      {
        key: key,
        client_id: client_id,
        authorization_endpoint: authorization_endpoint,
        token_endpoint: token_endpoint,
        scopes: scopes
      }
    end
  end

  class << self
    # Find OAuth client configuration for a server name
    #
    # Matches server names to OAuth client keys using exact match only.
    #
    # @param server_name [String] The MCP server name (e.g., "bigquery-example")
    # @return [OAuthClient, nil] The OAuth client config or nil if not found
    def find_for_server(server_name)
      return nil unless server_name.present?

      load_client(server_name)
    end

    # Check if a server has pre-registered OAuth configuration
    #
    # @param server_name [String] The MCP server name
    # @return [Boolean] True if pre-registered OAuth config exists
    def exists_for_server?(server_name)
      find_for_server(server_name).present?
    end

    # Get all configured OAuth clients
    #
    # @return [Array<OAuthClient>] List of all OAuth clients
    def all
      @all ||= load_all_clients
    end

    # Reload configuration from credentials
    def reload!
      @all = nil
      @oauth_clients_config = nil
      all
    end

    private

    # Load OAuth client configuration for a specific key
    def load_client(key)
      config = oauth_clients_config&.dig(key.to_sym)
      return nil unless config&.dig(:client_id).present? && config&.dig(:client_secret).present?

      authorization_endpoint = config[:authorization_endpoint]
      token_endpoint = config[:token_endpoint]

      # Validate required endpoints are present
      # Without these, OAuth flow cannot proceed
      return nil unless authorization_endpoint.present? && token_endpoint.present?

      OAuthClient.new(
        key: key,
        client_id: config[:client_id],
        client_secret: config[:client_secret],
        authorization_endpoint: authorization_endpoint,
        token_endpoint: token_endpoint,
        scopes: config[:scopes]
      )
    end

    # Load all OAuth clients from credentials
    def load_all_clients
      return [] unless oauth_clients_config.present?

      oauth_clients_config.keys.filter_map do |key|
        load_client(key.to_s)
      end
    end

    # Get the raw mcp_oauth_clients config from Rails credentials
    def oauth_clients_config
      @oauth_clients_config ||= begin
        Rails.application.credentials.mcp_oauth_clients
      rescue ActiveSupport::MessageEncryptor::InvalidMessage, NoMethodError
        nil
      end
    end
  end
end
