# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The web sign-in gate through the whole stack: routing, the wall, Google's
# callback, the second factor, the cookies, and the machine paths that must not
# notice any of it. Google is faked only at the token-endpoint POST
# (WebAuthTestHelpers#stub_google_id_token); every claim check runs for real.
class WebSignInTest < ActionDispatch::IntegrationTest
  include WebAuthTestHelpers

  API_KEY = "web-sign-in-test-api-key"

  setup do
    @original_api_keys = ENV[ApiKey::ENV_VAR]
    ENV[ApiKey::ENV_VAR] = API_KEY
  end

  teardown do
    @original_api_keys.nil? ? ENV.delete(ApiKey::ENV_VAR) : ENV[ApiKey::ENV_VAR] = @original_api_keys
  end

  # --- gate off --------------------------------------------------------------

  test "with the gate off the web UI behaves as it always has" do
    WebAuth::Configuration.stubs(:current).returns(WebAuth::Configuration.new({}))

    get root_path
    assert_response :success
    get settings_path
    assert_response :success
    assert_includes response.body, "ZIMMER_WEB_AUTH_GOOGLE_CLIENT_ID"
    get "/supervisor"
    assert_response :success

    get login_path
    assert_redirected_to root_path
  end

  # --- the wall --------------------------------------------------------------

  test "a signed-out page load goes to the login page, and comes back after sign-in" do
    enable_web_auth

    get settings_path
    assert_redirected_to "/login"
    follow_redirect!
    assert_response :success
    assert_includes response.body, "Sign in with Google"
    assert_includes response.body, "tadasant.com"

    sign_in_and_enroll
    assert_select "a[href=?]", settings_path, text: "Continue to Zimmer"
  end

  test "a signed-out write, fragment fetch or JSON request gets a bare 401, not a redirect" do
    enable_web_auth

    get root_path, headers: { "Accept" => "*/*" }
    assert_redirected_to "/login", "curl and the deploy smoke test ask for */*"

    post archive_session_path(1)
    assert_response :unauthorized
    get root_path, headers: { "Turbo-Frame" => "sessions" }
    assert_response :unauthorized
    get root_path, headers: { "Accept" => "application/json" }
    assert_response :unauthorized
  end

  test "/supervisor and /jobs are behind the wall too" do
    enable_web_auth

    get "/supervisor"
    assert_redirected_to "/login"
    get "/jobs"
    assert_redirected_to "/login"
    # A request into an engine leaves its mount point in the integration
    # session's URL options; start clean so the route helpers below are unprefixed.
    reset!

    sign_in_and_enroll
    get "/supervisor/web_identities"
    assert_response :success
    assert_includes response.body, "tadas@tadasant.com"
    get "/jobs"
    # GoodJob's own redirect to its localized index: past the wall.
    assert_redirected_to %r{/jobs/jobs}
  end

  # --- machine paths ---------------------------------------------------------

  test "the REST API answers to its API key, gate or no gate" do
    enable_web_auth

    get api_v1_sessions_path, headers: { "X-API-Key" => API_KEY }
    assert_response :success

    get api_v1_sessions_path
    assert_response :unauthorized
    assert_equal "application/json", response.media_type
  end

  test "POST /mcp answers to its bearer key, gate or no gate" do
    enable_web_auth

    post "/mcp",
      params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json,
      headers: { "Authorization" => "Bearer #{API_KEY}", "Content-Type" => "application/json", "Accept" => "application/json, text/event-stream" }
    assert_response :success
    assert JSON.parse(response.body).dig("result", "tools").any?
  end

  test "/up, /up/deep, the webhooks and a 404 never meet the login wall" do
    enable_web_auth

    get "/up"
    assert_response :success
    get "/up/deep"
    assert_includes [ 200, 503 ], response.status
    refute_equal "/login", URI(response.location.to_s).path

    post webhooks_slack_path, params: "{}", headers: { "Content-Type" => "application/json" }
    refute_includes [ 302, 303 ], response.status
    post webhooks_github_path, params: "{}", headers: { "Content-Type" => "application/json" }
    refute_includes [ 302, 303 ], response.status

    get "/api/v1/no-such-thing"
    assert_response :not_found
    assert_equal "application/json", response.media_type
  end

  # --- Google ----------------------------------------------------------------

  test "the login page sends you to Google with PKCE and a state" do
    enable_web_auth

    post google_sign_in_path
    location = URI(response.location)
    query = Rack::Utils.parse_query(location.query)

    assert_equal "accounts.google.com", location.host
    assert_equal "http://localhost:3000/auth/google/callback", query["redirect_uri"]
    assert query["state"].present?
    assert_equal "S256", query["code_challenge_method"]
  end

  test "an account from another domain is refused and stays signed out" do
    enable_web_auth

    sign_in_with_google(google_claims(hd: "example.org", email: "someone@example.org"))
    assert_response :forbidden
    assert_includes response.body, "That account belongs to example.org"
    assert_equal 0, WebIdentity.count

    get root_path
    assert_redirected_to "/login"
  end

  test "a personal account with an allowed-looking address is refused" do
    enable_web_auth

    sign_in_with_google(google_claims(hd: nil, email: "tadas@tadasant.com"))
    assert_response :forbidden
    assert_includes response.body, "personal Google account"
    assert_equal 0, WebIdentity.count
  end

  test "an unverified email is refused" do
    enable_web_auth

    sign_in_with_google(google_claims(email_verified: false))
    assert_response :forbidden
    assert_includes response.body, "not verified"
    assert_equal 0, WebIdentity.count
  end

  test "a callback whose state did not start in this browser is refused" do
    enable_web_auth
    post google_sign_in_path
    stub_google_id_token(google_claims)

    get google_sign_in_callback_path, params: { code: "c", state: "forged" }
    assert_response :unprocessable_entity
    assert_includes response.body, "did not start in this browser"
    assert_equal 0, WebIdentity.count
  end

  test "a half-configured gate fails closed and says what is missing" do
    enable_web_auth(client_secret: nil)

    get root_path
    assert_redirected_to "/login"
    follow_redirect!
    assert_includes response.body, "ZIMMER_WEB_AUTH_GOOGLE_CLIENT_SECRET is not set"
    assert_not_includes response.body, "Sign in with Google"

    post google_sign_in_path
    assert_response :service_unavailable
  end

  test "a store that has never answered is a 503, not an open door" do
    WebAuth::Configuration.stubs(:current).raises(WebAuth::Configuration::Unavailable, "the secret store did not answer")

    get root_path
    assert_response :service_unavailable
    get api_v1_sessions_path, headers: { "X-API-Key" => API_KEY }
    assert_response :success
  end

  # --- the second factor -----------------------------------------------------

  test "first sign-in sets up an authenticator, shows recovery codes once, and lands on the dashboard" do
    enable_web_auth

    identity = sign_in_and_enroll
    assert_select "[data-testid=recovery-codes] li", 10
    assert_predicate identity, :totp_enrolled?

    get root_path
    assert_response :success
  end

  test "Google alone does not get in: an enrolled account is asked for its code" do
    enable_web_auth
    identity = sign_in_and_enroll
    reset!

    travel 1.minute
    sign_in_with_google
    assert_redirected_to second_factor_path
    get root_path
    assert_redirected_to "/login"

    get second_factor_path
    assert_response :success
    post second_factor_path, params: { code: "000000" }
    assert_response :unprocessable_entity

    post second_factor_path, params: { code: current_totp_code(identity.totp_secret), trust_device: "1" }
    assert_redirected_to root_path
    get root_path
    assert_response :success
  end

  test "a browser that has only passed Google cannot replace the authenticator" do
    enable_web_auth
    sign_in_and_enroll
    reset!

    sign_in_with_google
    get second_factor_setup_path
    assert_redirected_to second_factor_path
    post second_factor_setup_path, params: { code: "123456" }
    assert_redirected_to second_factor_path
  end

  test "a recovery code signs in once" do
    enable_web_auth
    sign_in_and_enroll
    codes = css_select("[data-testid=recovery-codes] li").map { |li| li.text.strip }
    reset!

    sign_in_with_google
    post second_factor_path, params: { code: codes.first }
    assert_redirected_to root_path
    assert_match "9 left", flash[:notice]
    reset!

    sign_in_with_google
    post second_factor_path, params: { code: codes.first }
    assert_response :unprocessable_entity
  end

  test "a trusted browser skips the code at its next Google sign-in, and an untrusted one does not" do
    enable_web_auth
    sign_in_and_enroll

    delete logout_path
    assert_redirected_to login_path
    get root_path
    assert_redirected_to "/login"

    sign_in_with_google
    assert_redirected_to root_path

    reset!
    sign_in_with_google
    assert_redirected_to second_factor_path
  end

  test "the deployment's second-factor reset sends an enrolled account back to setup" do
    enable_web_auth
    sign_in_and_enroll

    travel 1.hour
    enable_web_auth(second_factor_reset_before: Time.current.iso8601)
    delete logout_path
    sign_in_with_google
    assert_redirected_to second_factor_setup_path, "a reset must void the trusted-device cookie too"
  end

  test "with second_factor=google, Google is the whole sign-in" do
    enable_web_auth(second_factor: "google")

    sign_in_with_google
    assert_redirected_to root_path
    get root_path
    assert_response :success

    enable_web_auth(second_factor: "totp")
    get root_path
    assert_redirected_to "/login", "a session that never passed TOTP must not count once TOTP is required"
  end

  # --- the long-lived session ------------------------------------------------

  test "the session rolls: used every 60 days it lasts indefinitely, left for 91 it lapses" do
    enable_web_auth
    sign_in_and_enroll

    travel 60.days
    get root_path
    assert_response :success
    travel 60.days
    get root_path
    assert_response :success

    travel 91.days
    get root_path
    assert_redirected_to "/login"
  end

  test "signing out everywhere ends every browser's session" do
    enable_web_auth
    sign_in_and_enroll
    other_browser_cookie = cookies[WebAuth::Cookies::SIGN_IN.to_s]

    post logout_everywhere_path
    assert_redirected_to login_path

    cookies[WebAuth::Cookies::SIGN_IN.to_s] = other_browser_cookie
    get root_path
    assert_redirected_to "/login"
  end

  test "an identity whose domain is no longer allowed is signed out" do
    enable_web_auth
    sign_in_and_enroll

    enable_web_auth(allowed_domains: "someone-else.com")
    get root_path
    assert_redirected_to "/login"
  end

  test "Settings says who is signed in and offers sign-out and a new authenticator" do
    enable_web_auth
    sign_in_and_enroll

    get settings_path
    assert_response :success
    assert_includes response.body, "Signed in as"
    assert_includes response.body, "tadas@tadasant.com"
    assert_includes response.body, "10 recovery codes left"
    assert_select "a[href=?]", second_factor_setup_path
    assert_select "form[action=?]", logout_path

    get second_factor_setup_path
    assert_response :success
    assert_includes response.body, "Your current authenticator keeps working"
  end

  # --- review hardening ------------------------------------------------------

  test "starting a sign-in and signing out need the page's CSRF token" do
    enable_web_auth
    ActionController::Base.allow_forgery_protection = true

    post google_sign_in_path
    assert_response :unprocessable_entity
    delete logout_path
    assert_response :unprocessable_entity
  ensure
    ActionController::Base.allow_forgery_protection = false
  end

  test "return_to only ever names a path on this host" do
    controller = WebSignInsController.new

    assert_equal "/settings?x=1", controller.send(:safe_return_to, "/settings?x=1")
    [ "//evil.example/x", "/\\evil.example", "https://evil.example", "", nil ].each do |value|
      assert_equal "/", controller.send(:safe_return_to, value), value.inspect
    end
  end

  test "a trusted-device cookie only vouches for the identity it was issued to" do
    enable_web_auth
    other = google_claims(sub: "other-account", email: "julie@tadasant.com")
    sign_in_and_enroll(other)
    reset!

    sign_in_and_enroll
    delete logout_path
    sign_in_with_google(other)
    assert_redirected_to second_factor_path
  end

  test "signing out everywhere also voids this browser's trusted-device cookie" do
    enable_web_auth
    sign_in_and_enroll

    post logout_everywhere_path
    sign_in_with_google
    assert_redirected_to second_factor_path
  end

  test "wrong codes lock the second factor, and the lock answers 429" do
    enable_web_auth
    sign_in_and_enroll
    reset!

    sign_in_with_google
    WebIdentity::MAX_FAILED_ATTEMPTS.times do
      post second_factor_path, params: { code: "000000" }
      assert_response :unprocessable_entity
    end
    post second_factor_path, params: { code: "000000" }
    assert_response :too_many_requests
    assert_includes response.body, "Try again in 15 minutes"
  end

  test "replacing the authenticator keeps this browser signed in and signs out the rest" do
    enable_web_auth
    identity = sign_in_and_enroll
    other_browser_cookie = cookies[WebAuth::Cookies::SIGN_IN.to_s]
    old_secret = identity.totp_secret

    get second_factor_setup_path
    new_secret = identity.reload.totp_pending_secret
    refute_equal old_secret, new_secret
    post second_factor_setup_path, params: { code: current_totp_code(new_secret) }
    assert_response :success
    assert_select "[data-testid=recovery-codes] li", 10
    assert_equal new_secret, identity.reload.totp_secret

    get root_path
    assert_response :success

    cookies[WebAuth::Cookies::SIGN_IN.to_s] = other_browser_cookie
    get root_path
    assert_redirected_to "/login"
  end

  test "a typo in the second-factor mode fails closed" do
    enable_web_auth(second_factor: "google")
    sign_in_with_google
    get root_path
    assert_response :success

    enable_web_auth(second_factor: "topt")
    get root_path
    assert_redirected_to "/login", "a session that never passed TOTP must not survive a mistyped mode"
    follow_redirect!
    assert_includes response.body, "ZIMMER_WEB_AUTH_SECOND_FACTOR must be one of totp, google"
  end

  test "the setup page is not cacheable" do
    enable_web_auth
    sign_in_with_google
    get second_factor_setup_path

    assert_equal "no-store", response.headers["Cache-Control"]
  end
end
