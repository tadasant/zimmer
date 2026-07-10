# frozen_string_literal: true

# Durable store for an X (Twitter) OAuth 2.0 user-context credential.
#
# Why this exists (and why it is NOT just an mcp_secrets entry): X rotates
# refresh tokens SINGLE-USE — every `grant_type=refresh_token` exchange returns a
# brand-new refresh token and invalidates the one just used (they also expire
# ~6 months). A static seed in git-committed Rails credentials would work for at
# most one refresh; the rotating token must live in a runtime-writable store.
# This row is that store, mirroring how web-app's ProctorOauthCredential persists
# rotating OAuth tokens in a DB row.
#
# Auth split:
#   - Static confidential-client creds (client id + secret) live in Rails
#     credentials (mcp_secrets: X_OAUTH_CLIENT_ID / X_OAUTH_CLIENT_SECRET),
#     mirroring the gmail servers. Read via the class-level accessors below.
#   - The rotating access/refresh tokens live on this row.
#
# Session-prep integration: SecretsInterpolator resolves ${access_token_env_var}
# (e.g. ${X_OAUTH_ACCESS_TOKEN}) to `current_access_token` at session launch, so
# the x-twitter MCP server runs in static access-token mode with a freshly-minted
# token. See XOauthTokenVendor.
#
# Security: access_token / refresh_token are stored as plain text, consistent
# with McpOauthCredential and ProctorOauthCredential. Security relies on database
# access controls.
class XOauthCredential < ApplicationRecord
  # OAuth error codes that indicate a permanent failure — retrying is futile and
  # the user must re-authorize (re-run the bootstrap consent flow).
  PERMANENT_REFRESH_ERRORS = %w[invalid_grant invalid_client unauthorized_client].freeze

  # Scopes minted by the bootstrap consent flow. bookmark.write (private
  # bookmarks only) is the sole write scope; offline.access yields a refresh
  # token. No scope permitting a PUBLIC action is ever requested.
  OAUTH_SCOPES = "tweet.read users.read bookmark.read bookmark.write offline.access"

  DEFAULT_TOKEN_ENDPOINT = "https://api.x.com/2/oauth2/token"
  AUTHORIZE_ENDPOINT = "https://x.com/i/oauth2/authorize"

  # Access tokens live ~2h; refresh when they fall within this window.
  DEFAULT_REFRESH_THRESHOLD = 15.minutes

  validates :account_key, presence: true, uniqueness: true
  validates :access_token_env_var, presence: true, uniqueness: true
  validates :token_endpoint, presence: true

  scope :active, -> { where("expires_at IS NULL OR expires_at > ?", Time.current) }
  scope :refreshable, -> { where.not(refresh_token: [ nil, "" ]) }

  # Static confidential-client creds. Kept off the row so the single source of
  # truth is the encrypted credentials file (matching the gmail servers). Sourced
  # from Rails credentials (mcp_secrets) first, then process ENV — the same
  # fallback chain SecretsInterpolator uses, so a deploy that injects these via
  # Kamal secrets/ENV works without a credentials round-trip.
  def self.client_id
    SecretsLoader.get("X_OAUTH_CLIENT_ID").presence || ENV["X_OAUTH_CLIENT_ID"].presence
  end

  def self.client_secret
    SecretsLoader.get("X_OAUTH_CLIENT_SECRET").presence || ENV["X_OAUTH_CLIENT_SECRET"].presence
  end

  # True when the access token will expire within the given threshold.
  def expiring_soon?(threshold = DEFAULT_REFRESH_THRESHOLD)
    return true if expires_at.nil?
    expires_at < threshold.from_now
  end

  # True when the access token should be proactively refreshed.
  def needs_refresh?(threshold = DEFAULT_REFRESH_THRESHOLD)
    expiring_soon?(threshold)
  end

  # True when the access token has not expired. A nil expiry is treated as
  # unknown/expired so a bare row (refresh token only) is not served as active.
  def active?
    expires_at.present? && expires_at > Time.current
  end

  # True when this credential has what it needs to perform a refresh.
  def can_refresh?
    refresh_token.present? && token_endpoint.present? &&
      self.class.client_id.present? && self.class.client_secret.present?
  end

  # Returns a currently-valid access token, refreshing on demand if it is
  # expiring. Serializes concurrent refreshes with a row lock so two sessions
  # preparing at once don't both rotate the single-use refresh token (the second
  # sees the freshly-refreshed token and skips its own refresh).
  #
  # Best-effort: if a refresh fails, returns whatever access token we hold rather
  # than nil, so the session still launches and the server surfaces a clear auth
  # error instead of session-prep hard-failing on a missing env var.
  #
  # @return [String, nil] a bearer access token, or nil if none exists at all
  def current_access_token
    with_lock do
      reload
      refresh! if needs_refresh? && can_refresh?
      access_token
    end
  rescue => e
    Rails.logger.warn "[XOauthCredential] On-demand refresh for #{account_key} failed: #{e.class}: #{e.message}; serving existing token"
    access_token
  end

  # Exchanges the stored refresh token for a fresh access token, persisting the
  # rotated refresh token. Confidential client → HTTP Basic auth at the token
  # endpoint (X requires the client secret in the Authorization header, not the
  # body).
  #
  # @return [true] on success
  # @return [:rate_limited] on HTTP 429
  # @return [:server_error] on HTTP 5xx
  # @return [false] on any other non-2xx (permanent failures clear the token)
  # @raise [RuntimeError] if refresh_token / token_endpoint / client creds are missing
  # @raise network errors (Net::OpenTimeout, Errno::ECONNRESET, ...) — the caller
  #   (RefreshXOauthTokensJob) classifies these as retryable vs ambiguous.
  def refresh!
    raise "Cannot refresh: missing refresh_token" if refresh_token.blank?
    raise "Cannot refresh: missing token_endpoint" if token_endpoint.blank?

    client_id = self.class.client_id
    client_secret = self.class.client_secret
    raise "Cannot refresh: missing X_OAUTH_CLIENT_ID/X_OAUTH_CLIENT_SECRET in credentials" if client_id.blank? || client_secret.blank?

    response = post_token_request(
      client_id: client_id,
      client_secret: client_secret,
      form: { grant_type: "refresh_token", refresh_token: refresh_token, client_id: client_id }
    )

    case response.code
    when /\A2/
      apply_token_response!(JSON.parse(response.body))
      Rails.logger.info "[XOauthCredential] Token refresh succeeded for #{account_key}"
      true
    when "429"
      :rate_limited
    when /\A5/
      :server_error
    else
      handle_non_transient_failure!(response)
      false
    end
  end

  # Persists a token endpoint response (from a refresh OR the initial
  # authorization-code exchange), rotating the refresh token. X returns a new
  # refresh token on every exchange; fall back to the current one only if the
  # response omits it.
  def apply_token_response!(token_data)
    update!(
      access_token: token_data["access_token"],
      refresh_token: token_data["refresh_token"].presence || refresh_token,
      expires_at: token_data["expires_in"] ? Time.current + token_data["expires_in"].to_i.seconds : nil,
      scopes: token_data["scope"].presence || scopes,
      last_refreshed_at: Time.current,
      last_refresh_attempted_at: Time.current,
      last_refresh_error: nil
    )
  end

  private

  def post_token_request(client_id:, client_secret:, form:)
    uri = URI(token_endpoint)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    request = Net::HTTP::Post.new(uri)
    request.basic_auth(client_id, client_secret)
    request.set_form_data(form)
    http.request(request)
  end

  def handle_non_transient_failure!(response)
    if permanent_refresh_failure?(response)
      # Drop the dead refresh token so the refresher stops retrying; re-auth
      # surfaces once the access token lapses (active? && can_refresh? both false).
      update_columns(
        refresh_token: nil,
        last_refresh_attempted_at: Time.current,
        last_refresh_error: "permanent: #{response.code} #{oauth_error(response.body)}".strip
      )
      Rails.logger.warn "[XOauthCredential] Refresh permanently invalid for #{account_key} (#{response.code}); cleared refresh token"
    else
      update_columns(
        last_refresh_attempted_at: Time.current,
        last_refresh_error: "#{response.code} response"
      )
      Rails.logger.error "[XOauthCredential] Token refresh failed for #{account_key}: #{response.code} - #{response.body}"
    end
  end

  def permanent_refresh_failure?(response)
    return true if %w[401 404].include?(response.code)
    PERMANENT_REFRESH_ERRORS.include?(oauth_error(response.body))
  end

  def oauth_error(response_body)
    JSON.parse(response_body)["error"]
  rescue JSON::ParserError, TypeError
    nil
  end
end
