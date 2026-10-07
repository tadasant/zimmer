# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The web sign-in wall with Zimmer behind a TLS-terminating local proxy
# (cloudflared in front of zimmer.tadasant.com): requests reach Rails from
# 127.0.0.1 over plain HTTP, carrying X-Forwarded-Proto: https and the public
# Host. Also the two things the MCP OAuth authorization server leans on: the
# machine paths it adds are never walled, and a browser sent to the wall from an
# authorize URL comes back to that URL byte for byte.
class WebSignInBehindProxyTest < ActionDispatch::IntegrationTest
  include WebAuthTestHelpers

  PUBLIC_HOST = "zimmer.example.com"
  BASE_URL = "https://#{PUBLIC_HOST}"
  PROXIED = { "X-Forwarded-Proto" => "https" }.freeze
  FROM_LOCAL_PROXY = { "REMOTE_ADDR" => "127.0.0.1" }.freeze

  # Shaped like the authorize request a Claude.ai custom connector sends: a
  # Client ID Metadata Document URL as client_id, percent-encoded URIs, PKCE,
  # and a state with URL-safe punctuation in it.
  AUTHORIZE_QUERY = "response_type=code" \
    "&client_id=https%3A%2F%2Fclaude.ai%2Foauth%2Fmcp-oauth-client-metadata" \
    "&redirect_uri=https%3A%2F%2Fclaude.ai%2Fapi%2Fmcp%2Fauth_callback" \
    "&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM" \
    "&code_challenge_method=S256" \
    "&state=af0ifjsldkj-Q_x.~abc" \
    "&scope=mcp" \
    "&resource=https%3A%2F%2Fzimmer.example.com%2Fmcp"

  setup do
    host! PUBLIC_HOST
    AppUrl.stubs(:base_url).returns(BASE_URL)
  end

  def proxied_get(path, **options)
    get path, headers: PROXIED.merge(options.delete(:headers) || {}), env: FROM_LOCAL_PROXY, **options
  end

  def proxied_post(path, **options)
    post path, headers: PROXIED.merge(options.delete(:headers) || {}), env: FROM_LOCAL_PROXY, **options
  end

  def set_cookie_line(name)
    Array(response.headers["Set-Cookie"]).flat_map { |h| h.split("\n") }.find { |line| line.start_with?("#{name}=") }
  end

  def proxied_sign_in_with_google(claims = google_claims)
    proxied_post google_sign_in_path
    state = Rack::Utils.parse_query(URI(response.location).query).fetch("state")
    stub_google_id_token(claims)
    proxied_get google_sign_in_callback_path, params: { code: "4/code", state: state }
  end

  # --- 1. behind the local proxy --------------------------------------------

  test "behind the proxy, the sign-in and trusted-device cookies are Secure, and the browser stays signed in" do
    enable_web_auth
    # The browser's side of the tunnel is HTTPS, so it sends Secure cookies back.
    https!

    proxied_sign_in_with_google
    assert_redirected_to second_factor_setup_path
    proxied_get second_factor_setup_path
    identity = WebIdentity.find_by!(google_sub: google_claims["sub"])
    proxied_post second_factor_setup_path, params: { code: current_totp_code(identity.reload.totp_pending_secret) }
    assert_response :success

    [ WebAuth::Cookies::SIGN_IN, WebAuth::Cookies::TRUSTED_DEVICE ].each do |name|
      line = set_cookie_line(name)
      assert line, "expected #{name} to be set"
      assert_match(/;\s*secure/i, line, "#{name} must be Secure behind a TLS-terminating proxy")
      assert_match(/;\s*httponly/i, line)
      assert_match(/;\s*samesite=lax/i, line)
    end

    proxied_get root_path
    assert_response :success
  end

  test "Secure follows the request, so plain HTTP with no forwarded proto gets no Secure flag" do
    enable_web_auth

    post google_sign_in_path
    state = Rack::Utils.parse_query(URI(response.location).query).fetch("state")
    stub_google_id_token(google_claims(sub: "plain-http"))
    get google_sign_in_callback_path, params: { code: "c", state: state }
    get second_factor_setup_path
    identity = WebIdentity.find_by!(google_sub: "plain-http")
    post second_factor_setup_path, params: { code: current_totp_code(identity.reload.totp_pending_secret) }

    refute_match(/;\s*secure/i, set_cookie_line(WebAuth::Cookies::SIGN_IN))
  end

  test "Google's redirect_uri comes from the configured base URL, never from the request's Host" do
    enable_web_auth

    host! "attacker.example"
    proxied_post google_sign_in_path
    query = Rack::Utils.parse_query(URI(response.location).query)

    assert_equal "#{BASE_URL}/auth/google/callback", query["redirect_uri"]
  end

  test "behind the proxy, a form post from the public origin passes CSRF and starts sign-in" do
    enable_web_auth
    ActionController::Base.allow_forgery_protection = true

    proxied_get login_path
    token = css_select("meta[name=csrf-token]").first["content"]
    proxied_post google_sign_in_path, params: { authenticity_token: token }, headers: { "Origin" => BASE_URL }
    assert_response :redirect
    assert_equal "accounts.google.com", URI(response.location).host
  ensure
    ActionController::Base.allow_forgery_protection = false
  end

  # --- 2. machine paths -----------------------------------------------------

  test "behind a proxy that rewrites Host, form posts fail CSRF, which is why the edge must pass Host through" do
    enable_web_auth
    ActionController::Base.allow_forgery_protection = true
    host! "localhost"

    proxied_get login_path
    token = css_select("meta[name=csrf-token]").first["content"]
    proxied_post google_sign_in_path, params: { authenticity_token: token }, headers: { "Origin" => BASE_URL }
    assert_response :unprocessable_entity
  ensure
    ActionController::Base.allow_forgery_protection = false
  end

  test "the MCP OAuth server's machine paths, /mcp and the API are exempt by path" do
    exempt = %w[
      /mcp /mcp.json /mcp/external_app /api /api/v1/sessions /webhooks /webhooks/slack /up /up.json /up/deep
      /oauth/token.json
      /.well-known/oauth-protected-resource /.well-known/oauth-protected-resource/mcp
      /.well-known/oauth-authorization-server /.well-known/oauth-authorization-server/mcp
      /oauth/register /oauth/token /oauth/revoke
    ]
    walled = %w[/ /settings /oauth/authorize /oauth/authorizeX /mcpx /mcp_oauth/callback /apix /webhooksx /oauth/register/extra /login]

    exempt.each { |path| assert_match WebSignInRequired::MACHINE_PATHS, path }
    walled.each { |path| refute_match WebSignInRequired::MACHINE_PATHS, path }
  end

  # The routes for /.well-known/oauth-* and /oauth/register|token|revoke arrive
  # with the MCP OAuth authorization server; until then they 404. So this asks
  # the wall itself, on a walled controller, what it does with each path.
  test "the wall lets machine paths through even on a controller that includes it" do
    enable_web_auth

    # SettingsController's own action, dispatched as a Rack app with the path
    # under test: past the wall it renders the Settings page (200); stopped by
    # it, a page load answers 302 /login.
    dispatch = lambda do |path|
      env = Rack::MockRequest.env_for("http://#{PUBLIC_HOST}#{path}", "HTTP_ACCEPT" => "text/html")
      env.merge!(Rails.application.env_config)
      env["rack.session"] = ActionController::TestSession.new
      SettingsController.action(:show).call(env)
    end

    %w[/oauth/token /oauth/register /oauth/revoke /.well-known/oauth-authorization-server /.well-known/oauth-protected-resource/mcp /mcp].each do |path|
      status, headers, = dispatch.call(path)
      assert_equal 200, status, "#{path} met the wall (Location: #{headers["location"].inspect})"
    end

    status, headers, = dispatch.call("/oauth/authorize?#{AUTHORIZE_QUERY}")
    assert_equal 302, status, "/oauth/authorize must stay behind the wall"
    assert_equal "/login", URI(headers["location"]).path
  end

  test "with the wall up, no machine path is ever answered with a redirect to /login" do
    enable_web_auth

    %w[/.well-known/oauth-protected-resource/mcp /.well-known/oauth-authorization-server /oauth/register /oauth/token /oauth/revoke].each do |path|
      proxied_get path
      refute_equal "/login", (response.location && URI(response.location).path), "#{path} met the login wall"
      post path, params: {}
      refute_equal "/login", (response.location && URI(response.location).path), "POST #{path} met the login wall"
    end
  end

  # --- 3. back to the authorize URL, query intact --------------------------

  test "first sign-in, through authenticator setup, returns to the authorize URL with its query byte for byte" do
    enable_web_auth
    authorize = "/settings?#{AUTHORIZE_QUERY}"

    proxied_get authorize
    assert_redirected_to "/login"

    proxied_sign_in_with_google
    assert_redirected_to second_factor_setup_path
    proxied_get second_factor_setup_path
    identity = WebIdentity.find_by!(google_sub: google_claims["sub"])
    proxied_post second_factor_setup_path, params: { code: current_totp_code(identity.reload.totp_pending_secret) }

    continue = css_select("a").find { |a| a.text.strip == "Continue to Zimmer" }
    assert_equal authorize, continue["href"]
  end

  test "a returning sign-in through the authenticator code returns to the authorize URL with its query byte for byte" do
    enable_web_auth
    identity = sign_in_and_enroll
    reset!
    host! PUBLIC_HOST
    authorize = "/settings?#{AUTHORIZE_QUERY}"

    proxied_get authorize
    proxied_sign_in_with_google
    assert_redirected_to second_factor_path
    # A fresh time step, since enrolling used up the current one.
    travel 1.minute
    proxied_post second_factor_path, params: { code: current_totp_code(identity.totp_secret) }

    assert_equal "https://#{PUBLIC_HOST}#{authorize}", response.location
  end

  test "a trusted browser's Google-only sign-in returns to the authorize URL with its query byte for byte" do
    enable_web_auth
    sign_in_and_enroll
    delete logout_path
    authorize = "/settings?#{AUTHORIZE_QUERY}"

    get authorize
    post google_sign_in_path
    state = Rack::Utils.parse_query(URI(response.location).query).fetch("state")
    stub_google_id_token(google_claims)
    get google_sign_in_callback_path, params: { code: "c", state: state }

    assert_equal "http://#{PUBLIC_HOST}#{authorize}", response.location
  end

  test "the return_to guard passes an authorize path through untouched and refuses other hosts" do
    controller = WebSignInsController.new
    path = "/oauth/authorize?#{AUTHORIZE_QUERY}"

    assert_equal path, controller.send(:safe_return_to, path)
    assert_equal "/", controller.send(:safe_return_to, "https://claude.ai/oauth/authorize?#{AUTHORIZE_QUERY}")
    assert_operator ActiveSupport::JSON.encode(path).bytesize, :<=, WebSignInRequired::RETURN_TO_MAX_BYTES,
      "a realistic authorize URL fits under the stored-path cap"
  end

  test "a return path too long for the session cookie is dropped, not a 500" do
    enable_web_auth
    long = "/settings?" + Array.new(250) { |i| "a#{i}=b" }.join("&")

    get long
    assert_redirected_to "/login"
    follow_redirect!
    assert_response :success
  end
end
