# frozen_string_literal: true

require "test_helper"

# The agent-login primitive over HTTP (tadasant/zimmer#220): mint behind the operator
# credential, exchange once for a cookie, refuse every non-active state with no
# cookie, revoke idempotently, and all of it closed unless the env gate is open.
class ConsoleLoginTest < ActionDispatch::IntegrationTest
  ENABLED_ENV = ConsoleLoginToken::ENABLED_ENV
  PASSWORD_ENV = OperatorHttpBasicAuth::PASSWORD_ENV
  PASSWORD = "console-login-test-password"
  COOKIE = ConsoleSession::COOKIE

  setup do
    @original_enabled = ENV[ENABLED_ENV]
    @original_password = ENV[PASSWORD_ENV]
    ENV[ENABLED_ENV] = "true"
    ENV[PASSWORD_ENV] = PASSWORD
  end

  teardown do
    restore_env(ENABLED_ENV, @original_enabled)
    restore_env(PASSWORD_ENV, @original_password)
  end

  # --- The env gate ---

  test "every endpoint is closed when the gate is unset, before any credential is looked at" do
    token, plaintext = ConsoleLoginToken.mint!(principal: "ci")
    ENV.delete(ENABLED_ENV)

    [
      -> { post console_login_tokens_path, params: { principal: "ci" }, headers: operator_headers, as: :json },
      -> { post revoke_console_login_token_path(token), headers: operator_headers, as: :json },
      -> { post console_login_path, params: { token: plaintext }, as: :json },
      -> { get console_login_path }
    ].each do |request|
      request.call
      assert_response :forbidden
      assert_nil response.headers["WWW-Authenticate"], "a closed deployment does not challenge"
      assert_nil cookies[COOKIE].presence, "a closed deployment sets no cookie"
      assert_includes response.parsed_body["message"], ENABLED_ENV
    end

    assert_predicate token.reload, :active?, "nothing was minted, consumed or revoked"
    assert_equal 1, ConsoleLoginToken.count
  end

  test "the gate opens only on the literal true" do
    ENV[ENABLED_ENV] = "1"
    get console_login_path
    assert_response :forbidden

    ENV[ENABLED_ENV] = "true"
    get console_login_path
    assert_response :unauthorized
  end

  # --- Mint ---

  test "mint needs the operator credential, and an API key is not it" do
    post console_login_tokens_path, params: { principal: "ci" }, as: :json
    assert_response :unauthorized
    assert_match(/Basic realm="#{OperatorHttpBasicAuth::REALM}"/, response.headers["WWW-Authenticate"])
    assert_includes response.parsed_body["message"], PASSWORD_ENV

    post console_login_tokens_path, params: { principal: "ci" }, headers: { "X-API-Key" => "any-api-key" }, as: :json
    assert_response :unauthorized

    post console_login_tokens_path, params: { principal: "ci" }, headers: operator_headers(password: "wrong"), as: :json
    assert_response :unauthorized

    assert_equal 0, ConsoleLoginToken.count
  end

  test "an unconfigured realm closes minting and says why, without a challenge" do
    ENV.delete(PASSWORD_ENV)

    post console_login_tokens_path, params: { principal: "ci" }, headers: operator_headers, as: :json

    assert_response :unauthorized
    assert_nil response.headers["WWW-Authenticate"]
    assert_includes response.parsed_body["message"], "#{PASSWORD_ENV} is unset or blank"
  end

  test "mint returns the token once, uncached, and stores only its digest" do
    post console_login_tokens_path, params: { principal: "ci-playwright", ttl_seconds: 120, session_ttl_seconds: 600 }, headers: operator_headers, as: :json

    assert_response :created
    assert_equal "no-store", response.headers["Cache-Control"]
    body = response.parsed_body
    plaintext = body["token"]
    row = body["console_login_token"]
    assert_match(/\Azlt_\d+\.[0-9a-f]{64}\z/, plaintext)
    assert_equal "ci-playwright", row["principal"]
    assert_equal "console", row["role"]
    assert_equal "active", row["status"]
    assert_equal 600, row["session_ttl_seconds"]
    assert_not row.key?("secret_digest")

    token = ConsoleLoginToken.find(row["id"])
    assert_in_delta 120.seconds.from_now, token.expires_at, 5.seconds
    assert_not_includes token.attributes.values.map(&:to_s), plaintext
    assert_equal ConsoleLoginToken.digest(plaintext.split(".").last), token.secret_digest
    assert_equal "127.0.0.1", token.minted_from_ip
  end

  test "mint clamps the windows into range, defaults them when absent, and refuses a non-integer" do
    post console_login_tokens_path, params: { principal: "ci", ttl_seconds: 99_999, session_ttl_seconds: 1 }, headers: operator_headers, as: :json
    assert_response :created
    row = response.parsed_body["console_login_token"]
    assert_equal ConsoleLoginToken::SESSION_TTL_SECONDS.begin, row["session_ttl_seconds"]
    assert_in_delta ConsoleLoginToken::TTL_SECONDS.end.seconds.from_now, Time.iso8601(row["expires_at"]), 5.seconds

    post console_login_tokens_path, params: { principal: "ci" }, headers: operator_headers, as: :json
    assert_response :created
    assert_equal ConsoleLoginToken::DEFAULT_SESSION_TTL_SECONDS, response.parsed_body["console_login_token"]["session_ttl_seconds"]

    post console_login_tokens_path, params: { principal: "ci", ttl_seconds: "soon" }, headers: operator_headers, as: :json
    assert_response :unprocessable_entity
    assert_includes response.parsed_body["message"], "ttl_seconds must be an integer"
    assert_equal 2, ConsoleLoginToken.count
  end

  test "mint refuses a blank principal with the model's message" do
    post console_login_tokens_path, params: { principal: "" }, headers: operator_headers, as: :json

    assert_response :unprocessable_entity
    assert_includes response.parsed_body["messages"], "Principal can't be blank"
    assert_equal 0, ConsoleLoginToken.count
  end

  # --- Exchange ---

  test "a token exchanges exactly once, for a cookie that reads back, and the second exchange is refused with no cookie" do
    _token, plaintext = ConsoleLoginToken.mint!(principal: "ci", session_ttl_seconds: 600)

    post console_login_path, params: { token: plaintext }, as: :json

    assert_response :ok
    assert_equal "no-store", response.headers["Cache-Control"]
    login = response.parsed_body["console_login"]
    assert_equal "ci", login["principal"]
    assert_equal "console", login["role"]
    assert_in_delta 600.seconds.from_now, Time.iso8601(login["expires_at"]), 5.seconds

    set_cookie = response.headers["Set-Cookie"].to_s
    assert_includes set_cookie, "#{COOKIE}="
    assert_match(/httponly/i, set_cookie)
    assert_match(/samesite=lax/i, set_cookie)
    assert_match(/max-age=(59[0-9]|600)\b/i, set_cookie)
    assert_no_match(/;\s*secure/i, set_cookie, "test answers over plain HTTP, so the cookie is not Secure here")

    # The cookie the integration session now holds authenticates the whoami.
    get console_login_path
    assert_response :ok
    assert_equal login, response.parsed_body["console_login"]

    # The same token again: refused, consumed, and no new cookie.
    post console_login_path, params: { token: plaintext }, as: :json
    assert_response :conflict
    assert_equal "consumed", response.parsed_body["reason"]
    assert_not_includes response.headers["Set-Cookie"].to_s, "#{COOKIE}="
  end

  test "a fresh client with no cookie is refused by the whoami" do
    get console_login_path

    assert_response :unauthorized
    assert_includes response.parsed_body["message"], "No console session"
  end

  test "a revoked, unconsumed token is refused with no cookie" do
    token, plaintext = ConsoleLoginToken.mint!(principal: "ci")
    token.revoke!

    post console_login_path, params: { token: plaintext }, as: :json

    assert_response :conflict
    assert_equal "revoked", response.parsed_body["reason"]
    assert_no_console_cookie
  end

  test "an expired token is refused with no cookie" do
    _token, plaintext = ConsoleLoginToken.mint!(principal: "ci", ttl_seconds: 10)

    travel 11.seconds do
      post console_login_path, params: { token: plaintext }, as: :json
    end

    assert_response :unauthorized
    assert_equal "expired", response.parsed_body["reason"]
    assert_no_console_cookie
  end

  test "a wrong secret, an unknown id and garbage all get the same 401 with no cookie" do
    token, _plaintext = ConsoleLoginToken.mint!(principal: "ci")

    [ "zlt_#{token.id}.#{"f" * 64}", "zlt_#{token.id + 1_000_000}.#{"f" * 64}", "garbage" ].each do |presented|
      post console_login_path, params: { token: presented }, as: :json
      assert_response :unauthorized
      assert_equal "invalid", response.parsed_body["reason"]
      assert_no_console_cookie
    end
    assert_predicate token.reload, :active?
  end

  test "a token in the query string is refused unread, and stays live" do
    token, plaintext = ConsoleLoginToken.mint!(principal: "ci")

    post "#{console_login_path}?token=#{plaintext}"
    assert_response :bad_request
    assert_includes response.parsed_body["message"], "not the query string"
    assert_predicate token.reload, :active?

    post console_login_path, params: {}, as: :json
    assert_response :bad_request
    assert_includes response.parsed_body["message"], "token is required"
  end

  test "the exchange also takes a form-encoded body" do
    _token, plaintext = ConsoleLoginToken.mint!(principal: "ci")

    post console_login_path, params: { token: plaintext }

    assert_response :ok
    get console_login_path
    assert_response :ok
  end

  test "the session cookie expires on its own schedule, after the token's window has closed" do
    _token, plaintext = ConsoleLoginToken.mint!(principal: "ci", ttl_seconds: 60, session_ttl_seconds: 120)
    post console_login_path, params: { token: plaintext }, as: :json
    assert_response :ok

    travel 90.seconds do
      get console_login_path
      assert_response :ok, "the token's own expiry does not end the session it issued"
    end

    travel 121.seconds do
      get console_login_path
      assert_response :unauthorized
    end
  end

  test "a forged or tampered cookie is not a session" do
    cookies[COOKIE] = "not-an-encrypted-cookie"
    get console_login_path
    assert_response :unauthorized

    _token, plaintext = ConsoleLoginToken.mint!(principal: "ci")
    post console_login_path, params: { token: plaintext }, as: :json
    cookies[COOKIE] = cookies[COOKIE].reverse
    get console_login_path
    assert_response :unauthorized
  end

  test "revoking the token after the exchange does not end the session" do
    token, plaintext = ConsoleLoginToken.mint!(principal: "ci")
    post console_login_path, params: { token: plaintext }, as: :json

    post revoke_console_login_token_path(token), headers: operator_headers, as: :json
    assert_response :ok
    assert_equal false, response.parsed_body["revoked"]
    assert_equal "consumed", response.parsed_body["console_login_token"]["status"]

    get console_login_path
    assert_response :ok
  end

  # --- Revoke ---

  test "revoke needs the operator credential and is idempotent" do
    token, plaintext = ConsoleLoginToken.mint!(principal: "ci")

    post revoke_console_login_token_path(token), as: :json
    assert_response :unauthorized
    assert_predicate token.reload, :active?

    post revoke_console_login_token_path(token), headers: operator_headers, as: :json
    assert_response :ok
    assert_equal true, response.parsed_body["revoked"]
    assert_equal "revoked", response.parsed_body["console_login_token"]["status"]

    post revoke_console_login_token_path(token), headers: operator_headers, as: :json
    assert_response :ok
    assert_equal false, response.parsed_body["revoked"]

    post console_login_path, params: { token: plaintext }, as: :json
    assert_response :conflict
    assert_no_console_cookie
  end

  test "revoking an id that was never minted is a 404" do
    post revoke_console_login_token_path(999_999_999), headers: operator_headers, as: :json

    assert_response :not_found
  end

  private

  def operator_headers(password: PASSWORD)
    { "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials("supervisor", password) }
  end

  def assert_no_console_cookie
    assert_not_includes response.headers["Set-Cookie"].to_s, "#{COOKIE}="
    assert_nil cookies[COOKIE].presence
  end

  def restore_env(key, value)
    value.nil? ? ENV.delete(key) : ENV[key] = value
  end
end
