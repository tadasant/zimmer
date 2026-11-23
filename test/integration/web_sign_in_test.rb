# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The web sign-in gate through the whole stack: routing, the wall, Google's
# callback, the second factor, the cookies, and the machine paths that must not
# notice any of it. Google is faked only at the token-endpoint POST
# (WebAuthTestHelpers#stub_google_id_token); every claim check runs for real.
class WebSignInTest < ActionDispatch::IntegrationTest
  include WebAuthTestHelpers
  include SecurityTelemetryTestHelpers

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
    assert_select "strong", text: "example.com"

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
    assert_includes response.body, "owner@example.com"
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

    sign_in_with_google(google_claims(hd: nil, email: "owner@example.com"))
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

  # The dashboard prefetches session pages into the HTTP cache with a short
  # max-age, which a browser serves without asking the server. Signing out
  # empties that cache so none of them outlives the sign-in.
  test "signing out clears this browser's cache for the site" do
    enable_web_auth
    sign_in_and_enroll

    delete logout_path
    assert_redirected_to login_path
    assert_equal '"cache"', response.headers["Clear-Site-Data"]
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
    assert_includes response.body, "owner@example.com"
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
    other = google_claims(sub: "other-account", email: "operator-b@example.com")
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
    report = with_security_telemetry do
      WebIdentity::MAX_FAILED_ATTEMPTS.times do
        post second_factor_path, params: { code: "000000" }
        assert_response :unprocessable_entity
      end
      post second_factor_path, params: { code: "000000" }
      assert_response :too_many_requests
    end
    assert_equal WebIdentity::MAX_FAILED_ATTEMPTS, report[:auth_failures_by_kind_and_reason]["web_second_factor"]["wrong_code"]
    assert_equal 1, report[:auth_failures_by_kind_and_reason]["web_second_factor"]["locked"]
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

  test "the setup page names this deployment's entry, by its configured base URL" do
    enable_web_auth
    AppUrl.stubs(:base_url).returns("https://hans.example.com")
    sign_in_with_google
    get second_factor_setup_path

    link = css_select("a").map { |a| a["href"] }.find { |href| href.to_s.start_with?("otpauth://") }
    assert link.start_with?("otpauth://totp/Zimmer%20%28hans.example.com%29%3A"), link
    assert_includes link, "issuer=Zimmer%20%28hans.example.com%29&"
    assert_select "[data-testid=totp-label]", text: /Zimmer \(hans\.example\.com\):/
  end

  test "a deployment with no base URL set names its entry by the host it was reached at" do
    enable_web_auth
    AppUrl.stubs(:base_url).returns(AppUrl::PLACEHOLDER_PROD_BASE_URL)
    sign_in_with_google
    get second_factor_setup_path

    assert_select "a[href*=?]", "issuer=Zimmer%20%28www.example.com%29"
  end

  test "a base URL with no host falls back to the host the browser asked for" do
    enable_web_auth
    sign_in_with_google
    [ "zimmer.example.com", "not a url" ].each do |base_url|
      AppUrl.stubs(:base_url).returns(base_url)
      get second_factor_setup_path
      assert_select "a[href*=?]", "issuer=Zimmer%20%28www.example.com%29", { count: 1 }, "base URL #{base_url.inspect}"
    end
  end

  test "a wrong code says to check it is this deployment's entry" do
    enable_web_auth
    AppUrl.stubs(:base_url).returns("https://hans.example.com")
    sign_in_and_enroll
    reset!

    sign_in_with_google
    post second_factor_path, params: { code: "000000" }
    assert_response :unprocessable_entity
    assert_includes response.body, "the entry you set up for this Zimmer (hans.example.com)"
  end

  test "the setup page is not cacheable" do
    enable_web_auth
    sign_in_with_google
    get second_factor_setup_path

    assert_equal "no-store", response.headers["Cache-Control"]
  end

  test "Google refusing the deployment's client logs at ERROR; any other failed exchange does not" do
    enable_web_auth
    { WebAuth::GoogleOauth::ClientRejected => "ERROR", WebAuth::GoogleOauth::ExchangeFailed => "WARN" }.each do |failure, level|
      post google_sign_in_path
      state = Rack::Utils.parse_query(URI(response.location).query).fetch("state")
      WebAuth::GoogleOauth.any_instance.stubs(:fetch_id_token).raises(failure, "Google's token endpoint answered")

      entries = capture_log_entries { get google_sign_in_callback_path, params: { code: "c", state: state } }
      assert_response :bad_gateway
      assert_equal [ level ], entries.select { |_, message| message.include?("Google sign-in failed") }.map(&:first)
    end
  end

  test "a sign-in cookie that cannot be read is signed out, not a 500" do
    enable_web_auth
    [ "%FF", "garbage", "bm90LW91cnM%3D--aXY%3D--dGFn" ].each do |raw|
      get settings_path, headers: { "Cookie" => "#{WebAuth::Cookies::SIGN_IN}=#{raw}" }
      assert_redirected_to login_path

      get login_path, headers: { "Cookie" => "#{WebAuth::Cookies::SIGN_IN}=#{raw}" }
      assert_response :success
    end
  end

  # --- security telemetry ----------------------------------------------------

  test "refused sign-ins and keys are counted for the monitoring plane, without labels from the request" do
    enable_web_auth
    sign_in_and_enroll
    reset!

    report = with_security_telemetry do
      sign_in_with_google
      2.times { post second_factor_path, params: { code: "000000" } }

      post google_sign_in_path
      get google_sign_in_callback_path, params: { code: "c", state: "forged" }

      get api_v1_sessions_path
      get api_v1_sessions_path, headers: { "X-API-Key" => "not-a-key" }
      get "/api/v1/no-such-thing", headers: { "X-API-Key" => API_KEY }
    end

    assert_equal 2, report[:auth_failures_by_kind_and_reason]["web_second_factor"]["wrong_code"]
    assert_equal 1, report[:auth_failures_by_kind_and_reason]["web_sign_in"]["flow_mismatch"]
    assert_equal 1, report[:auth_failures_by_kind_and_reason]["api_key"]["missing"]
    assert_equal 1, report[:auth_failures_by_kind_and_reason]["api_key"]["unknown"]
    assert_equal 2, report[:client_errors_by_surface_and_status]["api"]["401"]
    assert_equal 1, report[:client_errors_by_surface_and_status]["api"]["404"], "an unrouted probe lands on the surface it aimed at"
    assert_equal 3, report[:client_errors_by_surface_and_status]["web"]["422"], "two wrong codes and the forged callback"
  end

  test "the first sign-in is counted as completed when the authenticator is set up, not when Google answers" do
    enable_web_auth

    assert_equal({ "started" => 1, "completed" => 0 }, web_sign_ins { sign_in_with_google })
    reset!
    assert_equal({ "started" => 1, "completed" => 1 }, web_sign_ins { sign_in_and_enroll })
  end

  test "an enrolled account's sign-in is counted as completed on its code, and a wrong code is not one" do
    enable_web_auth
    identity = sign_in_and_enroll
    codes = css_select("[data-testid=recovery-codes] li").map { |li| li.text.strip }
    reset!
    travel 1.minute

    counts = web_sign_ins do
      sign_in_with_google
      post second_factor_path, params: { code: "000000" }
      assert_response :unprocessable_entity
    end
    assert_equal({ "started" => 1, "completed" => 0 }, counts)

    counts = web_sign_ins do
      post second_factor_path, params: { code: current_totp_code(identity.totp_secret) }
      assert_redirected_to root_path
    end
    assert_equal({ "started" => 0, "completed" => 1 }, counts)
    reset!

    counts = web_sign_ins do
      sign_in_with_google
      post second_factor_path, params: { code: codes.first }
      assert_redirected_to root_path
    end
    assert_equal({ "started" => 1, "completed" => 1 }, counts, "a recovery code is a completed sign-in")
  end

  test "a locked second factor completes nothing" do
    enable_web_auth
    identity = sign_in_and_enroll
    identity.update!(second_factor_locked_until: 10.minutes.from_now)
    reset!
    travel 1.minute

    counts = web_sign_ins do
      sign_in_with_google
      post second_factor_path, params: { code: current_totp_code(identity.totp_secret) }
      assert_response :too_many_requests
    end
    assert_equal({ "started" => 1, "completed" => 0 }, counts)
  end

  test "a trusted browser and a Google-only deployment complete at the callback" do
    enable_web_auth
    sign_in_and_enroll
    delete logout_path
    counts = web_sign_ins do
      sign_in_with_google
      assert_redirected_to root_path
    end
    assert_equal({ "started" => 1, "completed" => 1 }, counts)
    reset!

    enable_web_auth(second_factor: "google")
    counts = web_sign_ins do
      sign_in_with_google
      assert_redirected_to root_path
    end
    assert_equal({ "started" => 1, "completed" => 1 }, counts)
  end

  test "a sign-in that Google or Zimmer turns away is counted as started and not completed" do
    enable_web_auth

    [ WebAuth::GoogleOauth::ClientRejected, WebAuth::GoogleOauth::ExchangeFailed ].each do |failure|
      counts = web_sign_ins do
        post google_sign_in_path
        state = Rack::Utils.parse_query(URI(response.location).query).fetch("state")
        WebAuth::GoogleOauth.any_instance.stubs(:fetch_id_token).raises(failure, "Google's token endpoint answered")
        get google_sign_in_callback_path, params: { code: "c", state: state }
        assert_response :bad_gateway
      end
      assert_equal({ "started" => 1, "completed" => 0 }, counts, failure.name)
    end

    counts = web_sign_ins { sign_in_with_google(google_claims(hd: "example.org", email: "someone@example.org")) }
    assert_response :forbidden
    assert_equal({ "started" => 1, "completed" => 0 }, counts, "refused domain")

    counts = web_sign_ins do
      post google_sign_in_path
      get google_sign_in_callback_path, params: { error: "access_denied" }
    end
    assert_equal({ "started" => 1, "completed" => 0 }, counts, "cancelled at Google")

    counts = web_sign_ins do
      post google_sign_in_path
      get google_sign_in_callback_path, params: { code: "c", state: "forged" }
    end
    assert_equal({ "started" => 1, "completed" => 0 }, counts, "forged state")
  end

  test "Google refusing on its own page, so the browser never comes back, is started and not completed" do
    enable_web_auth

    counts = web_sign_ins do
      3.times do
        get login_path
        post google_sign_in_path
        assert_response :redirect
      end
    end
    assert_equal({ "started" => 3, "completed" => 0 }, counts)
  end

  test "a sign-in cookie that does not stick completes every time" do
    enable_web_auth(second_factor: "google")

    counts = web_sign_ins do
      3.times do
        sign_in_with_google
        cookies.delete(WebAuth::Cookies::SIGN_IN.to_s)
        get root_path
        assert_redirected_to "/login"
      end
    end
    assert_equal({ "started" => 3, "completed" => 3 }, counts)
  end

  test "re-issuing the sign-in cookie is neither started nor completed" do
    enable_web_auth
    sign_in_and_enroll
    before = cookies[WebAuth::Cookies::SIGN_IN.to_s]
    travel 2.days

    counts = web_sign_ins do
      get root_path
      assert_response :success
    end
    refute_equal before, cookies[WebAuth::Cookies::SIGN_IN.to_s], "the cookie was re-issued"
    assert_equal({ "started" => 0, "completed" => 0 }, counts)
  end

  test "a signed-out tab moves neither count, whatever it polls" do
    enable_web_auth

    counts = web_sign_ins do
      20.times do
        get live_updates_status_path
        follow_redirect!
        get root_path, headers: { "Turbo-Frame" => "sessions" }
        get root_path, headers: { "Accept" => "application/json" }
        get "/cable"
      end
      get second_factor_path
      get second_factor_setup_path
      get google_sign_in_callback_path, params: { code: "c", state: "s" }
    end
    assert_equal({ "started" => 0, "completed" => 0 }, counts)
  end

  test "an expired sign-in is signed out, and moves neither count" do
    enable_web_auth
    sign_in_and_enroll
    travel 91.days

    counts = web_sign_ins do
      get root_path
      assert_redirected_to "/login"
    end
    assert_equal({ "started" => 0, "completed" => 0 }, counts)
  end

  test "replacing the authenticator and signing out are not sign-ins" do
    enable_web_auth
    identity = sign_in_and_enroll
    before = cookies[WebAuth::Cookies::SIGN_IN.to_s]

    counts = web_sign_ins do
      get second_factor_setup_path
      post second_factor_setup_path, params: { code: current_totp_code(identity.reload.totp_pending_secret) }
      assert_response :success
      refute_equal before, cookies[WebAuth::Cookies::SIGN_IN.to_s], "it does write a new sign-in cookie"
      delete logout_path
    end
    assert_equal({ "started" => 0, "completed" => 0 }, counts)
  end

  test "a post that never reaches Google is not started" do
    enable_web_auth(client_secret: nil)
    counts = web_sign_ins do
      post google_sign_in_path
      assert_response :service_unavailable
    end
    assert_equal({ "started" => 0, "completed" => 0 }, counts, "nothing to sign in to")

    enable_web_auth
    ActionController::Base.allow_forgery_protection = true
    counts = web_sign_ins do
      post google_sign_in_path
      assert_response :unprocessable_entity
    end
    assert_equal({ "started" => 0, "completed" => 0 }, counts, "no CSRF token")
    ActionController::Base.allow_forgery_protection = false

    WebAuth::Configuration.stubs(:current).returns(WebAuth::Configuration.new({}))
    counts = web_sign_ins do
      post google_sign_in_path
      assert_redirected_to root_path
    end
    assert_equal({ "started" => 0, "completed" => 0 }, counts, "the gate is off")
  ensure
    ActionController::Base.allow_forgery_protection = false
  end

  test "a counter store that is down does not change a sign-in" do
    enable_web_auth(second_factor: "google")
    SecurityTelemetry.stubs(:pending).raises(StandardError, "down")

    sign_in_with_google
    assert_redirected_to root_path
    get root_path
    assert_response :success
  end

  private

  def web_sign_ins(&block)
    with_security_telemetry(&block)[:web_sign_ins_by_stage]
  end
end
