# frozen_string_literal: true

require "test_helper"

class XOauthCredentialTest < ActiveSupport::TestCase
  def build_credential(**attrs)
    XOauthCredential.create!({
      account_key: "tadasayy",
      access_token_env_var: "X_OAUTH_ACCESS_TOKEN",
      access_token: "old-access",
      refresh_token: "old-refresh",
      expires_at: 1.hour.from_now,
      token_endpoint: XOauthCredential::DEFAULT_TOKEN_ENDPOINT
    }.merge(attrs))
  end

  # Stub Net::HTTP.new so refresh!/exchange hit a fake endpoint, returning the
  # caller block's result plus the captured Net::HTTP::Post request (for header/
  # body assertions).
  def with_token_endpoint(code:, body:)
    captured = nil
    response = Net::HTTPResponse.new("1.1", code.to_s, "")
    response.stubs(:code).returns(code.to_s)
    response.stubs(:body).returns(body.is_a?(String) ? body : body.to_json)
    mock_http = Object.new
    mock_http.define_singleton_method(:use_ssl=) { |_| }
    mock_http.define_singleton_method(:request) { |req| captured = req; response }
    result = Net::HTTP.stub(:new, mock_http) { yield }
    [ result, captured ]
  end

  setup do
    XOauthCredential.stubs(:client_id).returns("test-client-id")
    XOauthCredential.stubs(:client_secret).returns("test-client-secret")
  end

  # --- validations ---

  test "requires account_key and access_token_env_var" do
    cred = XOauthCredential.new(token_endpoint: XOauthCredential::DEFAULT_TOKEN_ENDPOINT)
    assert_not cred.valid?
    assert cred.errors[:account_key].any?
    assert cred.errors[:access_token_env_var].any?
  end

  test "account_key and access_token_env_var are unique" do
    build_credential
    dup = XOauthCredential.new(
      account_key: "tadasayy", access_token_env_var: "X_OAUTH_ACCESS_TOKEN",
      token_endpoint: XOauthCredential::DEFAULT_TOKEN_ENDPOINT
    )
    assert_not dup.valid?
    assert dup.errors[:account_key].any?
    assert dup.errors[:access_token_env_var].any?
  end

  # --- expiry / refresh predicates ---

  test "active? is true only for an unexpired token" do
    assert build_credential(expires_at: 1.hour.from_now).active?
    assert_not build_credential(account_key: "b", access_token_env_var: "X_OAUTH_ACCESS_TOKEN_B", expires_at: 1.minute.ago).active?
    assert_not build_credential(account_key: "c", access_token_env_var: "X_OAUTH_ACCESS_TOKEN_C", expires_at: nil).active?
  end

  test "needs_refresh? is true within the threshold or when unknown" do
    assert build_credential(expires_at: 5.minutes.from_now).needs_refresh?
    assert_not build_credential(account_key: "b", access_token_env_var: "X_OAUTH_ACCESS_TOKEN_B", expires_at: 1.hour.from_now).needs_refresh?
    assert build_credential(account_key: "c", access_token_env_var: "X_OAUTH_ACCESS_TOKEN_C", expires_at: nil).needs_refresh?
  end

  test "can_refresh? requires a refresh token and client creds" do
    assert build_credential.can_refresh?
    assert_not build_credential(account_key: "b", access_token_env_var: "X_OAUTH_ACCESS_TOKEN_B", refresh_token: nil).can_refresh?

    cred = build_credential(account_key: "c", access_token_env_var: "X_OAUTH_ACCESS_TOKEN_C")
    XOauthCredential.stubs(:client_secret).returns(nil)
    assert_not cred.can_refresh?
  end

  # --- refresh! ---

  test "refresh! rotates the refresh token and updates the access token via HTTP Basic auth" do
    cred = build_credential(expires_at: 5.minutes.from_now)
    body = { access_token: "new-access", refresh_token: "new-refresh", expires_in: 7200, scope: "tweet.read bookmark.write" }

    _result, req = with_token_endpoint(code: 200, body: body) { cred.refresh! }

    cred.reload
    assert_equal "new-access", cred.access_token
    assert_equal "new-refresh", cred.refresh_token, "must persist the rotated refresh token"
    assert_operator cred.expires_at, :>, 1.hour.from_now
    assert_nil cred.last_refresh_error
    assert cred.last_refreshed_at.present?

    # Confidential client → HTTP Basic auth header (NOT client_secret in the body)
    assert_match(/\ABasic /, req["Authorization"])
    decoded = Base64.decode64(req["Authorization"].sub("Basic ", ""))
    assert_equal "test-client-id:test-client-secret", decoded
    assert_includes req.body, "grant_type=refresh_token"
    assert_not_includes req.body, "client_secret"
  end

  test "refresh! keeps the current refresh token when the response omits one" do
    cred = build_credential
    with_token_endpoint(code: 200, body: { access_token: "a2", expires_in: 7200 }) { cred.refresh! }
    assert_equal "old-refresh", cred.reload.refresh_token
  end

  test "refresh! returns :rate_limited on 429 without mutating tokens" do
    cred = build_credential
    result, = with_token_endpoint(code: 429, body: "rate limited") { cred.refresh! }
    assert_equal :rate_limited, result
    assert_equal "old-refresh", cred.reload.refresh_token
    assert_equal "old-access", cred.access_token
  end

  test "refresh! returns :server_error on 5xx" do
    cred = build_credential
    result, = with_token_endpoint(code: 503, body: "unavailable") { cred.refresh! }
    assert_equal :server_error, result
    assert_equal "old-refresh", cred.reload.refresh_token
  end

  test "refresh! clears the refresh token on a permanent invalid_grant" do
    cred = build_credential
    result, = with_token_endpoint(code: 400, body: { error: "invalid_grant" }) { cred.refresh! }
    assert_equal false, result
    assert_nil cred.reload.refresh_token
    assert_match(/permanent/, cred.last_refresh_error)
  end

  test "refresh! clears the refresh token on 401" do
    cred = build_credential
    with_token_endpoint(code: 401, body: "unauthorized") { cred.refresh! }
    assert_nil cred.reload.refresh_token
  end

  test "refresh! raises when refresh token is missing" do
    cred = build_credential(refresh_token: nil)
    assert_raises(RuntimeError) { cred.refresh! }
  end

  # --- current_access_token ---

  test "current_access_token returns the existing token without refreshing when fresh" do
    cred = build_credential(expires_at: 1.hour.from_now)
    # No HTTP stub: a refresh attempt would raise (Net::HTTP.new unstubbed hits
    # nothing resolvable), so this passing proves no refresh happened.
    assert_equal "old-access", cred.current_access_token
  end

  test "current_access_token refreshes on demand when expiring" do
    cred = build_credential(expires_at: 1.minute.from_now)
    with_token_endpoint(code: 200, body: { access_token: "fresh", refresh_token: "r2", expires_in: 7200 }) do
      assert_equal "fresh", cred.current_access_token
    end
    assert_equal "r2", cred.reload.refresh_token
  end

  test "current_access_token serves the existing token if a refresh fails" do
    cred = build_credential(expires_at: 1.minute.from_now)
    with_token_endpoint(code: 500, body: "boom") do
      assert_equal "old-access", cred.current_access_token
    end
  end
end
