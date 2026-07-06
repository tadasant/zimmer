# Stores pending OAuth flows initiated through the OAuth controller.
#
# When a user initiates OAuth for an MCP server, this record stores the OAuth
# flow state while they complete authentication with the OAuth provider.
# Contains all information needed to exchange the authorization code for tokens.
#
# Lifecycle:
# - Created by McpOauthController#initiate when user starts OAuth flow
# - Used by McpOauthController#callback to exchange code for tokens
# - Deleted after successful token exchange
# - Cleaned up by CleanupExpiredMcpOauthFlowsJob after 24 hours
#
# The `state` parameter serves dual purposes:
# 1. CSRF protection in the OAuth flow
# 2. Lookup key to resume the flow after OAuth provider callback
class McpOauthPendingFlow < ApplicationRecord
  # Pending flows expire after 24 hours
  EXPIRATION_DURATION = 24.hours

  belongs_to :session

  validates :server_name, presence: true
  validates :server_url, presence: true
  validates :state, presence: true, uniqueness: true
  validates :code_verifier, presence: true
  validates :authorization_endpoint, presence: true
  validates :token_endpoint, presence: true
  validates :client_id, presence: true
  validates :redirect_uri, presence: true
  validates :expires_at, presence: true
  validate :mcp_server_config_is_valid_hash

  # Flows that have not expired yet
  scope :active, -> { where("expires_at > ?", Time.current) }

  # Flows that have expired (for cleanup)
  scope :expired, -> { where("expires_at < ?", Time.current) }

  # Flows for a specific session
  scope :for_session, ->(session) { where(session: session) }

  # Creates a new pending flow with generated state and calculated expiration.
  #
  # @param session [Session] The session waiting for OAuth completion
  # @param server_name [String] Name of the MCP server
  # @param server_url [String] URL of the MCP server
  # @param oauth_metadata [Hash] OAuth metadata discovered from the server
  # @param redirect_uri [String] The callback URI to use
  # @param mcp_server_config [Hash] Full MCP server config for credential key computation
  # @return [McpOauthPendingFlow] The created flow
  def self.create_for_session!(session:, server_name:, server_url:, oauth_metadata:, redirect_uri:, mcp_server_config:)
    # Generate PKCE code verifier (43 characters from base64url alphabet)
    code_verifier = SecureRandom.urlsafe_base64(32).gsub(/=+$/, "")[0, 43]

    create!(
      session: session,
      server_name: server_name,
      server_url: server_url,
      state: SecureRandom.urlsafe_base64(32),
      code_verifier: code_verifier,
      authorization_endpoint: oauth_metadata[:authorization_endpoint],
      token_endpoint: oauth_metadata[:token_endpoint],
      registration_endpoint: oauth_metadata[:registration_endpoint],
      client_id: oauth_metadata[:client_id],
      client_secret: oauth_metadata[:client_secret],
      redirect_uri: redirect_uri,
      scopes: oauth_metadata[:scopes],
      resource: oauth_metadata[:resource],
      mcp_server_config: mcp_server_config,
      expires_at: EXPIRATION_DURATION.from_now
    )
  end

  # Returns true if this flow has expired
  def expired?
    expires_at < Time.current
  end

  # Returns true if this is a localhost OAuth flow
  # (redirect_uri points to localhost)
  def localhost_flow?
    redirect_uri.present? && (redirect_uri.include?("localhost") || redirect_uri.include?("127.0.0.1"))
  end

  # Computes the PKCE code challenge (S256 method)
  # @return [String] Base64URL-encoded SHA256 hash of the code_verifier
  def code_challenge
    digest = Digest::SHA256.digest(code_verifier)
    Base64.urlsafe_encode64(digest, padding: false)
  end

  # Builds the full authorization URL with all required OAuth parameters.
  #
  # For Google OAuth endpoints (*.google.com), automatically adds access_type=offline
  # and prompt=consent to request a refresh token. This is Google's proprietary
  # mechanism - they don't support the standard OIDC offline_access scope.
  #
  # For standard OIDC providers, the offline_access scope should be included
  # in the scopes field by the caller if the server advertises it.
  #
  # @return [String] The authorization URL to redirect the user to
  def authorization_url
    uri = URI(authorization_endpoint)
    params = {
      response_type: "code",
      client_id: client_id,
      redirect_uri: redirect_uri,
      state: state,
      code_challenge: code_challenge,
      code_challenge_method: "S256"
    }

    params[:scope] = scopes if scopes.present?

    # RFC 8707 resource indicator — tells the authorization server which MCP
    # resource server the issued token is for, so audience-binding servers
    # (e.g. Notion) accept it. Carried through token exchange and refresh too.
    params[:resource] = resource if resource.present?

    # Google OAuth requires access_type=offline to return a refresh token.
    # This is Google's proprietary extension - they don't support the standard
    # OIDC offline_access scope. We also add prompt=consent to ensure the
    # consent screen is shown, which guarantees a refresh token is returned
    # even if the user previously authorized the application.
    # See: https://developers.google.com/identity/protocols/oauth2/web-server
    if google_oauth_provider?
      params[:access_type] = "offline"
      params[:prompt] = "consent"
    end

    uri.query = URI.encode_www_form(params)
    uri.to_s
  end

  # Returns true if the OAuth provider is Google (google.com or *.google.com).
  # Google OAuth requires special handling because they don't support the standard
  # OIDC offline_access scope for refresh tokens - instead they require
  # access_type=offline as a query parameter.
  # @return [Boolean]
  def google_oauth_provider?
    return false unless authorization_endpoint.present?

    uri = URI(authorization_endpoint)
    host = uri.host
    return false unless host

    # Match exactly google.com or any subdomain (*.google.com)
    # Using strict matching to avoid spoofed domains like "evilgoogle.com"
    host == "google.com" || host.end_with?(".google.com")
  rescue URI::InvalidURIError
    false
  end

  # Computes the credential key for storing credentials after OAuth completes
  # @return [String] The credential key in "name|hash" format
  def credential_key
    config = mcp_server_config
    config = JSON.parse(config) if config.is_a?(String)
    McpOauthCredential.compute_credential_key(server_name, config.deep_symbolize_keys)
  end

  private

  def mcp_server_config_is_valid_hash
    return if mcp_server_config.is_a?(Hash)
    errors.add(:mcp_server_config, "must be a valid JSON object")
  end
end
