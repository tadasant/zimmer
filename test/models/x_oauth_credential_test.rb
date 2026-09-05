# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class XOauthCredentialTest < ActiveSupport::TestCase
  include XOauthTestHelpers

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

  # --- token_endpoint scheme (#850) ---
  #
  # The column decides both where the request goes and whether TLS is used, and
  # the X client secret rides along as HTTP Basic, so a non-https value publishes
  # a long-lived confidential-client secret in the clear. The field is
  # operator-editable through the supervisor panel, so the model is the guard.

  test "token_endpoint rejects anything that is not a plain https URL with a host" do
    [
      "http://api.x.com/2/oauth2/token",
      "http://127.0.0.1:8080/2/oauth2/token",
      "http://localhost:8080/2/oauth2/token",
      "ftp://api.x.com/2/oauth2/token",
      "api.x.com/2/oauth2/token",
      "https:/api.x.com/2/oauth2/token", # single slash — parses, but has no host
      "https://",
      "https://user:pass@api.x.com/2/oauth2/token", # basic_auth would silently ignore these
      "https://api.x.com/2/oauth2/token " # trailing space — starts right, still unusable
    ].each do |endpoint|
      cred = XOauthCredential.new(
        account_key: "tadasayy", access_token_env_var: "X_OAUTH_ACCESS_TOKEN",
        token_endpoint: endpoint
      )
      assert_not cred.valid?, "#{endpoint.inspect} should have been rejected"
      assert_predicate cred.errors[:token_endpoint], :any?, "no token_endpoint error for #{endpoint.inspect}"
    end
  end

  test "token_endpoint accepts https, case-insensitively on the scheme" do
    [ XOauthCredential::DEFAULT_TOKEN_ENDPOINT, "https://api.x.com/2/oauth2/token", "HTTPS://api.x.com/2/oauth2/token" ].each do |endpoint|
      cred = XOauthCredential.new(
        account_key: "tadasayy", access_token_env_var: "X_OAUTH_ACCESS_TOKEN",
        token_endpoint: endpoint
      )
      assert cred.valid?, "#{endpoint.inspect} should have been accepted: #{cred.errors.full_messages.join(", ")}"
    end
  end

  test "an unparseable token_endpoint is rejected rather than raising" do
    cred = XOauthCredential.new(
      account_key: "tadasayy", access_token_env_var: "X_OAUTH_ACCESS_TOKEN",
      token_endpoint: "https://api.x.com/a path"
    )
    assert_not cred.valid?
    assert_equal [ "is not a valid URL" ], cred.errors[:token_endpoint]
  end

  test "a blank token_endpoint reports only the presence error, not a scheme one" do
    cred = XOauthCredential.new(
      account_key: "tadasayy", access_token_env_var: "X_OAUTH_ACCESS_TOKEN", token_endpoint: ""
    )
    assert_not cred.valid?
    assert_equal [ "can't be blank" ], cred.errors[:token_endpoint]
  end

  # An http:// row can only exist if it predates the validation (the migration
  # repairs those) or was written with update_column. Guard the shape anyway: the
  # save that carries the refreshed tokens is what would refuse it.
  test "a legacy http row cannot be saved back through the ordinary update path" do
    cred = build_credential
    cred.update_column(:token_endpoint, "http://api.x.com/2/oauth2/token")

    assert_raises(ActiveRecord::RecordInvalid) { cred.reload.update!(access_token: "new") }
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

  # --- HTTP timeouts (#732) ---

  # Unset, both fall back to Net::HTTP's 60-second default, which is a minute of
  # a held thread against a token endpoint that goes silent.
  test "the token request bounds both connect and read at TOKEN_REQUEST_TIMEOUT" do
    cred = build_credential
    with_token_endpoint(code: 200, body: { access_token: "a", refresh_token: "r", expires_in: 7200 }) do
      cred.refresh!
    end

    assert_equal [ XOauthCredential::TOKEN_REQUEST_TIMEOUT, XOauthCredential::TOKEN_REQUEST_TIMEOUT ],
      observed_timeouts
    assert_equal 10, XOauthCredential::TOKEN_REQUEST_TIMEOUT
  end
end
