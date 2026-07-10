# frozen_string_literal: true

require "securerandom"
require "base64"
require "digest"

# One-time OAuth 2.0 (Authorization Code + PKCE) bootstrap for minting the
# durable X (Twitter) refresh token that XOauthCredential then rotates.
#
# X offers no non-interactive way to obtain a user-context token — a human must
# authorize in a browser once. Zimmer runs headless on a remote worker, so the
# loopback-callback flow the x-twitter server's `oauth-setup` command uses does
# not work here (nothing listens on the human's localhost). Instead this is a
# copy-the-code flow:
#
#   1. `authorize_url` builds the consent URL (PKCE S256, bookmark.write scope).
#   2. The human opens it, authorizes, and — because nothing listens on the
#      redirect URI — copies the `code` param out of the redirect URL bar.
#   3. `complete!` exchanges that code (HTTP Basic client auth) for tokens and
#      persists them onto an XOauthCredential row.
#
# The redirect URI must be registered on the X app. The ao-x-mcp-server app has
# http://localhost:8080/callback registered (used to mint the read-only seed).
class XOauthBootstrap
  SCOPES = XOauthCredential::OAUTH_SCOPES
  DEFAULT_REDIRECT_URI = "http://localhost:8080/callback"

  class ExchangeError < StandardError; end

  # PKCE code_verifier: 32 random bytes, base64url (no padding).
  def self.generate_verifier
    base64url(SecureRandom.random_bytes(32))
  end

  # CSRF state: 16 random bytes, base64url (no padding).
  def self.generate_state
    base64url(SecureRandom.random_bytes(16))
  end

  # Build the X consent URL for the given PKCE verifier + state.
  def self.authorize_url(client_id:, verifier:, state:, redirect_uri: DEFAULT_REDIRECT_URI)
    challenge = base64url(Digest::SHA256.digest(verifier))
    uri = URI(XOauthCredential::AUTHORIZE_ENDPOINT)
    uri.query = URI.encode_www_form(
      response_type: "code",
      client_id: client_id,
      redirect_uri: redirect_uri,
      scope: SCOPES,
      state: state,
      code_challenge: challenge,
      code_challenge_method: "S256"
    )
    uri.to_s
  end

  # Exchange an authorization code for tokens and persist them onto (or into) an
  # XOauthCredential row keyed by env_var. Returns the saved credential.
  #
  # @raise [ExchangeError] if the token endpoint returns a non-2xx response
  def self.complete!(account_key:, env_var:, code:, verifier:,
    redirect_uri: DEFAULT_REDIRECT_URI,
    client_id: XOauthCredential.client_id,
    client_secret: XOauthCredential.client_secret)
    raise ExchangeError, "missing X_OAUTH_CLIENT_ID/X_OAUTH_CLIENT_SECRET" if client_id.blank? || client_secret.blank?

    token_data = exchange_code(
      code: code, verifier: verifier, redirect_uri: redirect_uri,
      client_id: client_id, client_secret: client_secret
    )

    credential = XOauthCredential.find_or_initialize_by(access_token_env_var: env_var)
    credential.account_key = account_key if credential.account_key.blank?
    credential.token_endpoint = XOauthCredential::DEFAULT_TOKEN_ENDPOINT if credential.token_endpoint.blank?
    # Persist the required identity columns before apply_token_response! (which
    # uses update!) writes the rotating token fields.
    credential.save!
    credential.apply_token_response!(token_data)
    credential
  end

  # POST the authorization_code grant with HTTP Basic client auth. Returns the
  # parsed token response hash (access_token, refresh_token, expires_in, scope).
  def self.exchange_code(code:, verifier:, redirect_uri:, client_id:, client_secret:)
    uri = URI(XOauthCredential::DEFAULT_TOKEN_ENDPOINT)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    request = Net::HTTP::Post.new(uri)
    request.basic_auth(client_id, client_secret)
    request.set_form_data(
      grant_type: "authorization_code",
      code: code,
      redirect_uri: redirect_uri,
      code_verifier: verifier,
      client_id: client_id
    )

    response = http.request(request)
    unless response.code.start_with?("2")
      raise ExchangeError, "token exchange failed (HTTP #{response.code}): #{response.body}"
    end

    data = JSON.parse(response.body)
    raise ExchangeError, "no refresh_token in response (is offline.access granted?)" if data["refresh_token"].blank?
    data
  end

  def self.base64url(bytes)
    Base64.urlsafe_encode64(bytes).delete("=")
  end
end
