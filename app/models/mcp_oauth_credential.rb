# Stores OAuth credentials for MCP servers that require OAuth authentication.
#
# These credentials are used to authenticate with OAuth-protected MCP servers
# when spawning agent sessions. Credentials are keyed by server_name and
# server_url_hash to uniquely identify each OAuth-protected server.
#
# The credential_key format is "server_name|url_hash" where url_hash is the
# first 16 chars of SHA256(compact_json({type, url, headers})).
#
# Usage:
#   credential = McpOauthCredential.for_server(server_name, server_url).first
#   credential.refresh! if credential.needs_refresh?
#   access_token = credential.access_token
class McpOauthCredential < ApplicationRecord
  PERMANENT_REFRESH_ERRORS = %w[
    invalid_grant
    invalid_client
    unauthorized_client
  ].freeze

  validates :server_name, presence: true
  validates :server_url, presence: true
  validates :credential_key, presence: true, uniqueness: true
  validates :client_id, presence: true
  validates :access_token, presence: true

  # Find credentials for a specific server by name and URL
  scope :for_server, ->(server_name, server_url) {
    where(server_name: server_name, server_url: server_url)
  }

  # Find credentials by the computed credential key
  scope :for_credential_key, ->(key) { where(credential_key: key) }

  # Credentials that have not expired yet
  scope :active, -> { where("expires_at IS NULL OR expires_at > ?", Time.current) }

  # Credentials expiring within the given duration
  scope :expiring_within, ->(duration) { where("expires_at IS NOT NULL AND expires_at < ?", duration.from_now) }

  # Credentials that have already expired
  scope :expired, -> { where("expires_at IS NOT NULL AND expires_at < ?", Time.current) }

  # Computes the credential key for a given server configuration.
  # This matches the format used by Claude Code's credential storage.
  #
  # @param server_name [String] The server name from the MCP config
  # @param server_config [Hash] The server configuration (type, url, headers)
  # @return [String] The credential key in "name|hash" format
  def self.compute_credential_key(server_name, server_config)
    return server_name unless server_config.is_a?(Hash)

    # Build the config hash in the same order Claude uses: type, url, headers
    # Use 'http' for streamable-http type (Claude Code uses 'http' in key computation)
    config_for_hash = {
      type: server_config[:type] == "streamable-http" ? "http" : server_config[:type],
      url: server_config[:url],
      headers: server_config[:headers] || {}
    }

    # Compute compact JSON (no spaces) and hash it
    compact_json = config_for_hash.to_json.gsub(": ", ":").gsub(", ", ",")
    hash_val = Digest::SHA256.hexdigest(compact_json)[0, 16]

    "#{server_name}|#{hash_val}"
  end

  # Returns true if the access token will expire within the given threshold.
  # @param threshold [ActiveSupport::Duration] Time threshold (default: 15.minutes)
  # @return [Boolean]
  def expiring_soon?(threshold = 15.minutes)
    return false if expires_at.nil?
    expires_at < threshold.from_now
  end

  # Returns true if the access token needs to be refreshed.
  # Tokens are considered in need of refresh if they expire within 15 minutes.
  def needs_refresh?
    expiring_soon?(15.minutes)
  end

  # Returns true if the access token has not expired.
  # Tokens without expiration are considered active.
  def active?
    expires_at.nil? || expires_at > Time.current
  end

  # Returns true if this credential can be refreshed (has a refresh_token and token_endpoint)
  def can_refresh?
    refresh_token.present? && token_endpoint.present?
  end

  # Returns true if this credential is expired and cannot refresh.
  def requires_reauth?
    !active? && !can_refresh?
  end

  # Runtime-specific serialization (e.g. the Claude Code mcpOAuth entry format)
  # lives in the matching RuntimeMcpCredentialWriter, not on this protocol-level
  # model. McpOauthCredentialInjector resolves these records into runtime-agnostic
  # ResolvedMcpCredential value objects which the writer then serializes.

  # Refreshes the access token using the refresh_token.
  #
  # Makes a POST request to the token_endpoint with the refresh_token grant.
  # Updates access_token, and optionally refresh_token and expires_at.
  #
  # @return [Boolean] true if refresh succeeded, false otherwise
  # @raise [RuntimeError] if refresh_token or token_endpoint is missing
  def refresh!
    raise "Cannot refresh: missing refresh_token" unless refresh_token.present?
    raise "Cannot refresh: missing token_endpoint" unless token_endpoint.present?

    uri = URI(token_endpoint)
    params = {
      grant_type: "refresh_token",
      refresh_token: refresh_token,
      client_id: client_id,
      client_secret: client_secret,
      # RFC 8707 resource indicator — must be sent on refresh too, since refreshes
      # run later from cron without re-running discovery. Audience-binding servers
      # (e.g. Notion) reject refreshed tokens minted without it.
      resource: resource
    }.compact

    response = Net::HTTP.post_form(uri, params)

    if response.code == "200"
      token_data = JSON.parse(response.body)
      # Unwrap the same nested shapes the initial exchange handles (e.g. Slack rotation
      # returns the user token under authed_user.access_token). Reading the top level
      # blindly would store nil and destroy a working credential on the next cron run.
      tokens = McpOauthService.new.extract_tokens(token_data)

      unless tokens && tokens["access_token"].present?
        Rails.logger.error "[McpOauthCredential] Token refresh returned no usable access token for #{server_name} (#{credential_key})"
        return false
      end

      update!(
        access_token: tokens["access_token"],
        refresh_token: tokens["refresh_token"] || self.refresh_token,
        expires_at: tokens["expires_in"] ? Time.current + tokens["expires_in"].to_i.seconds : nil
      )
      Rails.logger.info "[McpOauthCredential] Token refresh succeeded for #{server_name}"
      true
    else
      if permanent_refresh_failure?(response)
        invalidate_refresh_token!(response)
      else
        Rails.logger.error "[McpOauthCredential] Token refresh failed for #{server_name} (#{credential_key}): #{response.code} - #{response.body}"
      end
      false
    end
  end

  private

  # A refresh is permanently dead when the token endpoint rejects the
  # refresh_token grant with a 4xx. Some servers signal this with a
  # spec-compliant JSON body ({"error": "invalid_grant"}); others just return a
  # bare HTML "400 Bad Request". Both mean the same thing — the refresh token is
  # no longer usable and re-auth is required — so a 4xx is classified permanent
  # regardless of body format. The JSON error-field check remains as a
  # more-specific classifier layered on top (it also covers the rare provider
  # that returns one of these errors with a non-4xx status).
  #
  # Transient failures (429 rate-limit, 5xx outage) are excluded first: they
  # stay on the loud ERROR path with the refresh token intact so the next cron
  # run retries, matching XOauthCredential's transient/permanent split.
  def permanent_refresh_failure?(response)
    return false if transient_refresh_failure?(response)

    client_error?(response) || PERMANENT_REFRESH_ERRORS.include?(oauth_error(response.body))
  end

  # The endpoint is reachable but temporarily unwilling (rate limiting) or
  # broken (5xx) — the refresh token itself is not implicated, so never drop it.
  def transient_refresh_failure?(response)
    code = response.code.to_i
    code == 429 || (code >= 500 && code < 600)
  end

  def client_error?(response)
    code = response.code.to_i
    code >= 400 && code < 500
  end

  def invalidate_refresh_token!(response)
    # Drop the now-dead refresh token, but DO NOT discard a still-valid access
    # token. Rotating-refresh-token providers (e.g. Notion) issue a new refresh
    # token on every refresh and revoke the prior one; if a refresh response is
    # lost in flight and the old token is later re-sent, reuse-detection
    # permanently revokes the chain — yet the access token we already hold is
    # still valid for the remainder of its TTL. Force-expiring it here would
    # strand a live session into immediate re-auth for no reason. Re-auth
    # surfaces naturally once the access token actually lapses, since
    # requires_reauth? becomes true only when !active? && !can_refresh?.
    if active?
      update!(refresh_token: nil)
    else
      update!(refresh_token: nil, expires_at: Time.current)
    end
    Rails.logger.warn "[McpOauthCredential] Token refresh permanently invalid for #{server_name}: #{response.code} - #{response.body}"
  end

  def oauth_error(response_body)
    JSON.parse(response_body)["error"]
  rescue JSON::ParserError, TypeError
    nil
  end
end
