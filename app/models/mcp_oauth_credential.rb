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
  include HttpsTokenEndpoint

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

  # #refresh! posts the client_secret and the refresh token to this endpoint as
  # form parameters, and McpOauthService#post_form derives `use_ssl` from the
  # very same string — so an http:// value publishes both in the clear, and the
  # refresh still returns 200 (#892).
  #
  # Deliberately *not* a presence validation: the column is nullable and blank is
  # a meaningful state, meaning "this credential cannot be renewed, re-authorize
  # it" (see #can_refresh? / #requires_reauth?). It is also what the repair
  # migration writes into a legacy row. Requiring presence here would make those
  # rows unsavable, which is the failure this validation exists to avoid.
  #
  # There is no loopback carve-out. Unlike XOauthCredential's endpoint, this one
  # is *discovered* — McpOauthService reads it out of the MCP server's own
  # authorization-server metadata — so an exception would be triggerable by the
  # one party outside our control. A remote server naming Zimmer's own loopback
  # has no legitimate meaning: it would aim a POST carrying an operator-supplied
  # client secret (the catalog `oauth` block's, threaded through discovery) at
  # whatever answers on this host's port. The endpoint is operator-editable too,
  # through the supervisor panel, and one rule with no exceptions is what makes
  # that surface reviewable.
  validate :token_endpoint_must_be_https

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

  # Returns true if this credential can be refreshed: it has a refresh_token, and
  # an endpoint Zimmer is willing to send it to.
  #
  # The scheme check is what keeps a row the validation cannot reach — one
  # written with update_column, or one the repair migration has not run over yet
  # — from ever reaching the wire. Every caller of #refresh! gates on this
  # (RefreshMcpOauthTokensJob, McpOauthCredentialInjector), so a credential
  # pointed at a cleartext endpoint is simply never refreshed: no POST, no
  # rotation, and no half-completed refresh whose save then fails validation.
  # It reads as requires_reauth? once the access token lapses, which is the
  # truth — the endpoint has to be rediscovered before this can be renewed.
  def can_refresh?
    refresh_token.present? && HttpsTokenEndpoint.secure?(token_endpoint)
  end

  # Returns true if this credential is expired and cannot refresh.
  def requires_reauth?
    !active? && !can_refresh?
  end

  # True when this credential will need re-authorizing by hand, on a schedule,
  # for as long as it exists.
  #
  # A server that does not issue a refresh token (it advertises no
  # `offline_access` scope, or simply declines to mint one) hands Zimmer a
  # one-shot credential: RefreshMcpOauthTokensJob has nothing to send, so the
  # access token lapses and the next session stops for consent. That is a
  # permanent property of the server, knowable the moment a token exchange
  # leaves no refresh token on the credential — `refresh_token_unsupported`
  # records it there (McpOauthController#store_tokens_and_resume) so it can be said
  # once, up front, instead of resurfacing later as "the agent randomly needs me
  # to authorize this again".
  #
  # The `refresh_token` check keeps the claim honest in the other direction: if a
  # refresh token later arrives (a runtime-captured rotation, a re-auth against a
  # server that changed its mind), the credential is no longer one-shot and the
  # warning goes away without a second write.
  def requires_periodic_reauth?
    refresh_token_unsupported? && refresh_token.blank?
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
    # Stated here as well as in #can_refresh? because this method is the one that
    # puts the secret on the wire, and a direct caller that skipped the predicate
    # must not get a cleartext POST out of it.
    raise "Cannot refresh: token_endpoint #{HttpsTokenEndpoint.describe(token_endpoint)} is not https" unless HttpsTokenEndpoint.secure?(token_endpoint)

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

    # Post through McpOauthService, whose post_form bounds both the connect and the
    # read at McpOauthService::REQUEST_TIMEOUT — the same bound the initial exchange
    # uses. `Net::HTTP.post_form` cannot be given timeouts and falls back to
    # Net::HTTP's 60-second defaults, which are per-read: a token endpoint that
    # answers slowly enough holds a GoodJob thread for as long as it likes, and this
    # runs unattended from cron (RefreshMcpOauthTokensJob).
    oauth = McpOauthService.new
    response = oauth.post_form(uri, params)

    if response.code == "200"
      token_data = JSON.parse(response.body)
      # Unwrap the same nested shapes the initial exchange handles (e.g. Slack rotation
      # returns the user token under authed_user.access_token). Reading the top level
      # blindly would store nil and destroy a working credential on the next cron run.
      tokens = oauth.extract_tokens(token_data)

      unless tokens && tokens["access_token"].present?
        Rails.logger.error "[McpOauthCredential] Token refresh returned no usable access token for #{server_name} (#{credential_key})"
        return false
      end

      update!(
        access_token: tokens["access_token"],
        refresh_token: tokens["refresh_token"] || self.refresh_token,
        expires_at: tokens["expires_in"] ? Time.current + tokens["expires_in"].to_i.seconds : nil,
        # A refresh that succeeded is proof the server supports refreshing,
        # whatever was recorded at issuance. The column holds the last observed
        # truth, so a later invalidate_refresh_token! cannot resurrect a
        # "this server issued no refresh token" claim this refresh just disproved.
        refresh_token_unsupported: false
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
