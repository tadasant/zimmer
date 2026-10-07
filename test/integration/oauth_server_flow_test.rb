# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Zimmer as an OAuth 2.1 authorization server for /mcp, driven the way a remote
# MCP client (a Claude.ai custom connector) drives it: 401 → discovery →
# registration (DCR or a Client ID Metadata Document) → authorize with PKCE →
# token → /mcp → refresh → revoke. The static API key path runs beside it.
class OauthServerFlowTest < ActionDispatch::IntegrationTest
  include WebAuthTestHelpers

  ISSUER = "http://www.example.com"
  RESOURCE = "#{ISSUER}/mcp".freeze
  REDIRECT = "https://claude.ai/api/mcp/auth_callback"
  CLAUDE_CIMD = "https://claude.ai/oauth/mcp-oauth-client-metadata"
  ENV_KEYS = %w[API_KEYS OAUTH_SERVER_ISSUER OAUTH_SERVER_ALLOWED_DOMAINS
    ZIMMER_DEV_WEB_USER_EMAIL OAUTH_SERVER_ACCESS_TOKEN_TTL_SECONDS].freeze

  setup do
    @saved_env = ENV_KEYS.index_with { |k| ENV[k] }
    @api_key = "test_api_key_oauth_flow"
    ENV["API_KEYS"] = @api_key
    ENV["OAUTH_SERVER_ISSUER"] = ISSUER
    ENV["OAUTH_SERVER_ALLOWED_DOMAINS"] = "tadasant.com"
    # The web sign-in wall is off unless a test turns it on.
    WebAuth::Configuration.stubs(:current).returns(web_auth_configuration_with(client_id: nil, allowed_domains: nil))
    ENV["ZIMMER_DEV_WEB_USER_EMAIL"] = "tadas@tadasant.com"
    ENV.delete("OAUTH_SERVER_ACCESS_TOKEN_TTL_SECONDS")
  end

  teardown do
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # --- helpers ---

  def rpc(method, token: nil, headers: {}, path: "/mcp")
    headers = { "Content-Type" => "application/json", "Accept" => "application/json, text/event-stream" }.merge(headers)
    headers["Authorization"] = "Bearer #{token}" if token
    post path, params: { jsonrpc: "2.0", id: 1, method: method, params: {} }.to_json, headers: headers
    response.body.presence && JSON.parse(response.body)
  end

  def register(overrides = {})
    body = { client_name: "Test client", redirect_uris: [ REDIRECT ], token_endpoint_auth_method: "none",
      grant_types: %w[authorization_code refresh_token], response_types: [ "code" ] }.merge(overrides)
    post "/oauth/register", params: body.to_json, headers: { "Content-Type" => "application/json" }
    JSON.parse(response.body)
  end

  def pkce
    verifier = SecureRandom.urlsafe_base64(48)
    [ verifier, Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false) ]
  end

  def authorize_params(client_id, challenge, overrides = {})
    { response_type: "code", client_id: client_id, redirect_uri: REDIRECT, code_challenge: challenge,
      code_challenge_method: "S256", state: "xyz", resource: RESOURCE }.merge(overrides)
  end

  def redirect_params
    uri = URI.parse(response.location)
    [ "#{uri.scheme}://#{uri.host}#{uri.path}", URI.decode_www_form(uri.query.to_s).to_h ]
  end

  # Consent and approve; returns [code, verifier].
  def approve(client_id, overrides = {})
    verifier, challenge = pkce
    get "/oauth/authorize", params: authorize_params(client_id, challenge, overrides)
    assert_response :success
    post "/oauth/authorize", params: authorize_params(client_id, challenge, overrides).merge(decision: "approve")
    assert_response :found
    target, query = redirect_params
    assert_equal REDIRECT, target
    [ query.fetch("code"), verifier ]
  end

  def exchange(client_id, code, verifier, extra = {})
    post "/oauth/token", params: { grant_type: "authorization_code", client_id: client_id, code: code,
      code_verifier: verifier, redirect_uri: REDIRECT }.merge(extra)
    JSON.parse(response.body)
  end

  def refresh(client_id, refresh_token)
    post "/oauth/token", params: { grant_type: "refresh_token", client_id: client_id, refresh_token: refresh_token }
    JSON.parse(response.body)
  end

  def connect(client_id = register["client_id"])
    code, verifier = approve(client_id)
    [ client_id, exchange(client_id, code, verifier) ]
  end

  def stub_cimd_document(doc, cache_control: "public, max-age=300")
    OauthServer::ClientMetadataDocument.any_instance.stubs(:fetch).returns(
      [ doc.to_json, OauthServer::ClientMetadataDocument.allocate.send(:ttl_from, cache_control) ]
    )
  end

  def claude_document
    { client_id: CLAUDE_CIMD, client_name: "Claude", client_uri: "https://claude.ai", redirect_uris: [ REDIRECT ],
      grant_types: [ "authorization_code", "refresh_token", "urn:ietf:params:oauth:grant-type:jwt-bearer" ],
      response_types: [ "code" ], token_endpoint_auth_method: "none" }
  end

  # --- the 401 challenge ---

  test "an unauthenticated /mcp is a 401 whose WWW-Authenticate names the protected-resource metadata" do
    rpc("tools/list")

    assert_response :unauthorized
    assert_equal %(Bearer realm="zimmer", resource_metadata="#{ISSUER}/.well-known/oauth-protected-resource/mcp", scope="mcp"),
      response.headers["WWW-Authenticate"]
  end

  test "a bad credential on /mcp adds error=invalid_token to the challenge" do
    rpc("tools/list", token: "not-a-key")

    assert_response :unauthorized
    assert_includes response.headers["WWW-Authenticate"], 'error="invalid_token"'
  end

  test "the API key path is unchanged: X-API-Key and Bearer both work" do
    rpc("tools/list", headers: { "X-API-Key" => @api_key })
    assert_response :success

    body = rpc("tools/list", token: @api_key)
    assert_response :success
    assert body["result"]["tools"].any?
  end

  # --- discovery ---

  test "protected-resource metadata is served at both spellings" do
    [ "/.well-known/oauth-protected-resource/mcp", "/.well-known/oauth-protected-resource" ].each do |path|
      get path
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal RESOURCE, body["resource"]
      assert_equal [ ISSUER ], body["authorization_servers"]
      assert_equal [ "header" ], body["bearer_methods_supported"]
      assert_equal "*", response.headers["Access-Control-Allow-Origin"]
    end
  end

  test "authorization-server metadata advertises DCR, CIMD and S256" do
    [ "/.well-known/oauth-authorization-server", "/.well-known/oauth-authorization-server/mcp" ].each do |path|
      get path
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal ISSUER, body["issuer"]
      assert_equal "#{ISSUER}/oauth/authorize", body["authorization_endpoint"]
      assert_equal "#{ISSUER}/oauth/token", body["token_endpoint"]
      assert_equal "#{ISSUER}/oauth/register", body["registration_endpoint"]
      assert_equal [ "S256" ], body["code_challenge_methods_supported"]
      assert_equal true, body["client_id_metadata_document_supported"]
      assert_equal %w[authorization_code refresh_token], body["grant_types_supported"]
    end
  end

  test "the issuer defaults to https://APP_HOST" do
    ENV.delete("OAUTH_SERVER_ISSUER")
    previous = ENV["APP_HOST"]
    ENV["APP_HOST"] = "zimmer.example.org"
    get "/.well-known/oauth-authorization-server"
    assert_equal "https://zimmer.example.org", JSON.parse(response.body)["issuer"]
  ensure
    previous.nil? ? ENV.delete("APP_HOST") : ENV["APP_HOST"] = previous
  end

  test "outside development and test the issuer is never the request's own origin" do
    ENV.delete("OAUTH_SERVER_ISSUER")
    previous = ENV.delete("APP_HOST")
    Rails.env.stubs(:local?).returns(false)

    get "/.well-known/oauth-authorization-server"
    assert_response :service_unavailable
    get "/.well-known/oauth-protected-resource/mcp"
    assert_response :service_unavailable

    rpc("tools/list")
    assert_response :unauthorized
    refute_includes response.headers["WWW-Authenticate"], "resource_metadata"

    ENV["APP_HOST"] = "zimmer.tadasant.com"
    get "/.well-known/oauth-protected-resource/mcp", headers: { "Host" => "localhost:3000", "X-Forwarded-Proto" => "http" }
    body = JSON.parse(response.body)
    assert_equal "https://zimmer.tadasant.com/mcp", body["resource"], "behind a TLS-terminating edge, Rails sees http://localhost"
    assert_equal [ "https://zimmer.tadasant.com" ], body["authorization_servers"]
  ensure
    previous.nil? ? ENV.delete("APP_HOST") : ENV["APP_HOST"] = previous
  end

  test "an issuer that is not a bare origin is refused rather than half-used" do
    ENV["OAUTH_SERVER_ISSUER"] = "https://zimmer.tadasant.com/some/path"
    Rails.env.stubs(:local?).returns(false)

    get "/.well-known/oauth-authorization-server"
    assert_response :service_unavailable
  end

  test "CORS preflight on the machine endpoints" do
    process :options, "/oauth/token"
    assert_response :no_content
    assert_equal "*", response.headers["Access-Control-Allow-Origin"]
  end

  # --- DCR ---

  test "DCR registers a public client and narrows extra grant types instead of refusing them" do
    body = register(grant_types: [ "authorization_code", "refresh_token", "urn:ietf:params:oauth:grant-type:jwt-bearer" ],
      redirect_uris: [ REDIRECT, "https://claude.com/api/mcp/auth_callback" ])

    assert_response :created
    assert body["client_id"].start_with?("zmc_")
    assert_equal %w[authorization_code refresh_token], body["grant_types"]
    assert_equal "none", body["token_endpoint_auth_method"]
    assert_equal "dcr", OauthServer::Client.find_by!(client_id: body["client_id"]).registration_type
  end

  test "DCR accepts a loopback http redirect and refuses a public http one" do
    register(redirect_uris: [ "http://127.0.0.1:33418/callback" ])
    assert_response :created

    body = register(redirect_uris: [ "http://evil.example/callback" ])
    assert_response :bad_request
    assert_equal "invalid_redirect_uri", body["error"]
  end

  test "DCR refuses a confidential client, a custom scheme, and a client without the code flow" do
    assert_equal "invalid_client_metadata", register(token_endpoint_auth_method: "client_secret_basic")["error"]
    assert_equal "invalid_redirect_uri", register(redirect_uris: [ "myapp://callback" ])["error"]
    assert_equal "invalid_client_metadata", register(grant_types: [ "client_credentials" ])["error"]
    post "/oauth/register", params: "{not json", headers: { "Content-Type" => "application/json" }
    assert_equal "invalid_client_metadata", JSON.parse(response.body)["error"]
  end

  # --- the whole flow ---

  test "authorize → token → /mcp → refresh → revoke, with a DCR client" do
    client_id = register["client_id"]
    verifier, challenge = pkce

    get "/oauth/authorize", params: authorize_params(client_id, challenge)
    assert_response :success
    assert_includes response.body, "tadas@tadasant.com"
    assert_includes response.body, "self-registered"
    assert_equal "DENY", response.headers["X-Frame-Options"]
    # `no-referrer` would make the browser post the consent form with `Origin: null`,
    # which Rails' CSRF origin check refuses.
    assert_equal "same-origin", response.headers["Referrer-Policy"]

    post "/oauth/authorize", params: authorize_params(client_id, challenge).merge(decision: "approve")
    assert_response :found
    _, query = redirect_params
    assert_equal "xyz", query["state"]
    assert_equal ISSUER, query["iss"]

    tokens = exchange(client_id, query["code"], verifier)
    assert_response :success
    assert tokens["access_token"].start_with?("zmr_oat_")
    assert tokens["refresh_token"].start_with?("zmr_ort_")
    assert_equal 3600, tokens["expires_in"]
    assert_equal "no-store", response.headers["Cache-Control"]

    # Only digests are stored.
    refute OauthServer::Token.exists?(token_digest: tokens["access_token"])
    assert OauthServer::Token.exists?(token_digest: OauthServer.digest(tokens["access_token"]))

    body = rpc("tools/list", token: tokens["access_token"])
    assert_response :success
    assert_operator body["result"]["tools"].size, :>, 10

    # ?tool_groups= is honoured for an OAuth caller the same as for a key.
    post "/mcp?tool_groups=self_session", params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "application/json", "Authorization" => "Bearer #{tokens['access_token']}" }
    assert_response :success
    assert_equal Mcp::Registry.tools_for([ "self_session" ]).size, JSON.parse(response.body)["result"]["tools"].size

    # The code is single use.
    assert_equal "invalid_grant", exchange(client_id, query["code"], verifier)["error"]

    rotated = refresh(client_id, tokens["refresh_token"])
    assert_response :success
    refute_equal tokens["refresh_token"], rotated["refresh_token"]
    rpc("tools/list", token: rotated["access_token"])
    assert_response :success

    post "/oauth/revoke", params: { token: rotated["refresh_token"] }
    assert_response :success
    rpc("tools/list", token: rotated["access_token"])
    assert_response :unauthorized
    assert_includes response.headers["WWW-Authenticate"], 'error="invalid_token"'
  end

  test "with CSRF protection on, approving from the consent page works and a forged post does not" do
    ActionController::Base.allow_forgery_protection = true
    client_id = register["client_id"]
    _, challenge = pkce

    get "/oauth/authorize", params: authorize_params(client_id, challenge)
    token = response.body[/name="authenticity_token" value="([^"]+)"/, 1]
    assert token

    post "/oauth/authorize", params: authorize_params(client_id, challenge).merge(decision: "approve"),
      headers: { "Origin" => ISSUER }
    assert_response :unprocessable_entity

    post "/oauth/authorize", params: authorize_params(client_id, challenge).merge(decision: "approve", authenticity_token: CGI.unescapeHTML(token)),
      headers: { "Origin" => ISSUER }
    assert_response :found
  ensure
    ActionController::Base.allow_forgery_protection = false
  end

  test "a wrong PKCE verifier, a different client, or a different redirect_uri cannot redeem the code" do
    client_id = register["client_id"]
    other_id = register["client_id"]

    code, verifier = approve(client_id)
    assert_equal "invalid_grant", exchange(client_id, code, "x" * 43)["error"]

    code, verifier = approve(client_id)
    assert_equal "invalid_grant", exchange(other_id, code, verifier)["error"]
    exchange(client_id, code, verifier)
    assert_response :success, "another client presenting the code does not burn it"

    code, verifier = approve(client_id)
    assert_equal "invalid_grant", exchange(client_id, code, verifier, redirect_uri: "https://claude.ai/elsewhere")["error"]
  end

  test "the token endpoint refuses an unknown client, an unknown grant type, and a foreign resource" do
    exchange("zmc_nope", "code", "v" * 43)
    assert_response :unauthorized

    post "/oauth/token", params: { grant_type: "password", client_id: register["client_id"] }
    assert_equal "unsupported_grant_type", JSON.parse(response.body)["error"]

    client_id = register["client_id"]
    code, verifier = approve(client_id)
    assert_equal "invalid_target", exchange(client_id, code, verifier, resource: "https://elsewhere.example/mcp")["error"]
  end

  test "an access token expires; the refresh token outlives it" do
    client_id, tokens = connect

    travel 61.minutes do
      rpc("tools/list", token: tokens["access_token"])
      assert_response :unauthorized

      rotated = refresh(client_id, tokens["refresh_token"])
      assert_response :success
      rpc("tools/list", token: rotated["access_token"])
      assert_response :success
    end
  end

  test "token lifetimes are configurable" do
    ENV["OAUTH_SERVER_ACCESS_TOKEN_TTL_SECONDS"] = "600"
    _, tokens = connect
    assert_equal 600, tokens["expires_in"]
  end

  test "a spent refresh token replayed inside the grace window is refused; later, it revokes the grant" do
    client_id, tokens = connect
    rotated = refresh(client_id, tokens["refresh_token"])

    assert_equal "invalid_grant", refresh(client_id, tokens["refresh_token"])["error"]
    rpc("tools/list", token: rotated["access_token"])
    assert_response :success, "a retry inside the grace window does not end the connection"

    travel 2.minutes do
      assert_equal "invalid_grant", refresh(client_id, tokens["refresh_token"])["error"]
      rpc("tools/list", token: rotated["access_token"])
      assert_response :unauthorized
      assert_equal "invalid_grant", refresh(client_id, rotated["refresh_token"])["error"]
    end
  end

  test "a token bound to another resource is refused on /mcp" do
    _, tokens = connect
    ENV["OAUTH_SERVER_ISSUER"] = "https://zimmer.elsewhere.example"

    rpc("tools/list", token: tokens["access_token"])
    assert_response :unauthorized
  end

  test "taking the email's domain off the allowlist stops refresh and revokes the grant" do
    client_id, tokens = connect
    ENV["OAUTH_SERVER_ALLOWED_DOMAINS"] = "example.org"

    assert_equal "invalid_grant", refresh(client_id, tokens["refresh_token"])["error"]
    assert OauthServer::Grant.last.revoked?
  end

  test "the plugin endpoint does not take an OAuth access token, and its 401 carries no OAuth challenge" do
    _, tokens = connect

    rpc("tools/list", token: tokens["access_token"], path: "/mcp/external_app")
    assert_response :unauthorized
    assert_nil response.headers["WWW-Authenticate"]
  end

  test "the REST API does not take an OAuth access token" do
    _, tokens = connect

    get "/api/v1/sessions", headers: { "X-API-Key" => tokens["access_token"] }
    assert_response :unauthorized
  end

  # --- authorize: who may consent, and where errors go ---

  test "nobody signed in: a page, no code" do
    ENV.delete("ZIMMER_DEV_WEB_USER_EMAIL")
    _, challenge = pkce

    get "/oauth/authorize", params: authorize_params(register["client_id"], challenge)
    assert_response :unauthorized
    assert_includes response.body, "Sign in to Zimmer first"
  end

  test "with the web sign-in wall on: login round-trips back to /oauth/authorize with every parameter, then a token" do
    ENV.delete("ZIMMER_DEV_WEB_USER_EMAIL")
    ENV.delete("OAUTH_SERVER_ALLOWED_DOMAINS")
    enable_web_auth
    identity = sign_in_and_enroll
    reset!
    travel 1.minute

    client_id = register["client_id"]
    verifier, challenge = pkce
    sent = authorize_params(client_id, challenge, resource: "#{RESOURCE}?tool_groups=sessions", state: "st/ate+with=chars&more").merge(scope: "mcp")

    get "/oauth/authorize", params: sent
    assert_redirected_to "/login"

    sign_in_with_google
    assert_redirected_to second_factor_path
    post second_factor_path, params: { code: current_totp_code(identity.reload.totp_secret) }

    assert_response :redirect
    back = URI.parse(response.location)
    assert_equal "/oauth/authorize", back.path
    assert_equal sent.transform_keys(&:to_s).transform_values(&:to_s), URI.decode_www_form(back.query).to_h,
      "client_id, redirect_uri, state, code_challenge, code_challenge_method, resource and scope all survive the login"

    follow_redirect!
    assert_response :success
    assert_includes response.body, "tadas@tadasant.com"

    post "/oauth/authorize", params: authorize_params(client_id, challenge).merge(decision: "approve")
    _, query = redirect_params
    tokens = exchange(client_id, query["code"], verifier)
    assert_response :success, "the token endpoint is a machine path, outside the wall"

    rpc("tools/list", token: tokens["access_token"])
    assert_response :success
  end

  test "with the wall on, the dev email is ignored and a signed-out POST is refused" do
    enable_web_auth
    _, challenge = pkce

    post "/oauth/authorize", params: authorize_params(register["client_id"], challenge).merge(decision: "approve")
    assert_response :unauthorized
    assert_equal 0, OauthServer::AuthorizationCode.count
  end

  test "signed out: no metadata document is fetched and no error is redirected anywhere" do
    ENV.delete("ZIMMER_DEV_WEB_USER_EMAIL")
    OauthServer::ClientMetadataDocument.any_instance.expects(:fetch).never
    _, challenge = pkce

    get "/oauth/authorize", params: authorize_params(CLAUDE_CIMD, challenge)
    assert_response :unauthorized

    # A registered redirect_uri plus a bad parameter would otherwise bounce a
    # signed-out visitor to whatever URI anyone registered: an open redirect.
    client_id = register(redirect_uris: [ "https://evil.example/phish" ])["client_id"]
    get "/oauth/authorize", params: authorize_params(client_id, challenge, redirect_uri: "https://evil.example/phish", response_type: "bogus")
    assert_response :unauthorized
    assert_nil response.location
  end

  test "signed in outside the allowed domain: a page, no code — even when posting the consent form directly" do
    ENV["ZIMMER_DEV_WEB_USER_EMAIL"] = "someone@gmail.com"
    client_id = register["client_id"]
    _, challenge = pkce

    get "/oauth/authorize", params: authorize_params(client_id, challenge)
    assert_response :forbidden
    assert_includes response.body, "@tadasant.com"

    post "/oauth/authorize", params: authorize_params(client_id, challenge).merge(decision: "approve")
    assert_response :forbidden
    assert_equal 0, OauthServer::AuthorizationCode.count
  end

  test "no allowed domain configured anywhere: nothing is issued" do
    ENV.delete("OAUTH_SERVER_ALLOWED_DOMAINS")
    _, challenge = pkce

    get "/oauth/authorize", params: authorize_params(register["client_id"], challenge)
    assert_response :forbidden
  end

  test "the allowed domains fall back to the web sign-in's" do
    ENV.delete("OAUTH_SERVER_ALLOWED_DOMAINS")
    WebAuth::Configuration.stubs(:current).returns(web_auth_configuration_with(client_id: nil, allowed_domains: "example.org, tadasant.com"))
    _, challenge = pkce

    get "/oauth/authorize", params: authorize_params(register["client_id"], challenge)
    assert_response :success
  end

  test "an unknown client or an unregistered redirect_uri is a page here, never a redirect" do
    _, challenge = pkce

    get "/oauth/authorize", params: authorize_params("zmc_unknown", challenge)
    assert_response :bad_request

    get "/oauth/authorize", params: authorize_params(register["client_id"], challenge, redirect_uri: "https://evil.example/cb")
    assert_response :bad_request
    assert_includes response.body, "is not one registered for this client"
  end

  test "once the redirect_uri is trusted, request errors go back to the client" do
    client_id = register["client_id"]
    _, challenge = pkce

    {
      { code_challenge_method: "plain" } => "invalid_request",
      { code_challenge_method: nil } => "invalid_request",
      { code_challenge: "short" } => "invalid_request",
      { response_type: "token" } => "unsupported_response_type",
      { resource: "https://elsewhere.example/mcp" } => "invalid_target"
    }.each do |override, error|
      get "/oauth/authorize", params: authorize_params(client_id, challenge, override).compact
      assert_response :found
      _, query = redirect_params
      assert_equal error, query["error"], override.inspect
      assert_equal "xyz", query["state"]
    end
  end

  test "a resource with a query string or trailing slash still names /mcp" do
    client_id = register["client_id"]
    code, verifier = approve(client_id, resource: "#{RESOURCE}/?tool_groups=sessions")
    exchange(client_id, code, verifier)
    assert_response :success
  end

  test "deny redirects back with access_denied" do
    client_id = register["client_id"]
    _, challenge = pkce

    post "/oauth/authorize", params: authorize_params(client_id, challenge).merge(decision: "deny")
    _, query = redirect_params
    assert_equal "access_denied", query["error"]
    assert_equal 0, OauthServer::AuthorizationCode.count
  end

  test "the consent screen escapes the client's own name" do
    client_id = register(client_name: "<img src=x onerror=alert(1)>")["client_id"]
    _, challenge = pkce

    get "/oauth/authorize", params: authorize_params(client_id, challenge)
    assert_response :success
    refute_includes response.body, "<img src=x"
  end

  test "a loopback redirect gets a warning on the consent screen" do
    client_id = register(redirect_uris: [ "http://127.0.0.1:6274/oauth/callback" ])["client_id"]
    _, challenge = pkce

    get "/oauth/authorize", params: authorize_params(client_id, challenge, redirect_uri: "http://127.0.0.1:6274/oauth/callback")
    assert_response :success
    assert_includes response.body, "a program on this computer"
  end

  # --- CIMD ---

  test "a Client ID Metadata Document client connects with no registration" do
    stub_cimd_document(claude_document)

    code, verifier = approve(CLAUDE_CIMD)
    tokens = exchange(CLAUDE_CIMD, code, verifier)
    assert_response :success

    client = OauthServer::Client.find_by!(client_id: CLAUDE_CIMD)
    assert client.cimd?
    assert_equal "Claude", client.client_name

    rpc("tools/list", token: tokens["access_token"])
    assert_response :success
  end

  test "the consent screen names the host that published the document" do
    stub_cimd_document(claude_document)
    _, challenge = pkce

    get "/oauth/authorize", params: authorize_params(CLAUDE_CIMD, challenge)
    assert_response :success
    assert_includes response.body, "published by"
    assert_includes response.body, "claude.ai</code>"
  end

  test "a document is cached for its max-age, then fetched again" do
    stub_cimd_document(claude_document)
    _, challenge = pkce
    get "/oauth/authorize", params: authorize_params(CLAUDE_CIMD, challenge)

    OauthServer::ClientMetadataDocument.any_instance.expects(:fetch).never
    get "/oauth/authorize", params: authorize_params(CLAUDE_CIMD, challenge)
    assert_response :success

    travel 6.minutes do
      OauthServer::ClientMetadataDocument.any_instance.unstub(:fetch)
      stub_cimd_document(claude_document.merge(client_name: "Claude (renamed)"))
      get "/oauth/authorize", params: authorize_params(CLAUDE_CIMD, challenge)
      assert_includes response.body, "Claude (renamed)"
    end
  end

  test "a document whose client_id is not its own URL is refused" do
    stub_cimd_document(claude_document.merge(client_id: "https://claude.ai/other"))
    _, challenge = pkce

    get "/oauth/authorize", params: authorize_params(CLAUDE_CIMD, challenge)
    assert_response :bad_request
    assert_includes response.body, "does not equal the URL"
  end

  test "a redirect_uri the document does not list is a page, not a redirect" do
    stub_cimd_document(claude_document)
    _, challenge = pkce

    get "/oauth/authorize", params: authorize_params(CLAUDE_CIMD, challenge, redirect_uri: "https://evil.example/cb")
    assert_response :bad_request
    assert_includes response.body, "metadata document at claude.ai"
  end

  test "a document carrying a client secret is refused" do
    stub_cimd_document(claude_document.merge(client_secret: "s3cret", token_endpoint_auth_method: "client_secret_post"))
    _, challenge = pkce

    get "/oauth/authorize", params: authorize_params(CLAUDE_CIMD, challenge)
    assert_response :bad_request
  end

  test "an http, private or path-less client_id URL is refused before anything is fetched" do
    OauthServer::ClientMetadataDocument.any_instance.expects(:fetch).never
    _, challenge = pkce

    %w[http://claude.ai/meta https://127.0.0.1/meta https://10.0.0.5/meta https://claude.ai/ https://claude.ai/a/../b].each do |client_id|
      get "/oauth/authorize", params: authorize_params(client_id, challenge)
      assert_response :bad_request, client_id
    end
  end

  test "clients nobody consented to are pruned after a week; ones with a grant are kept" do
    stale_dcr = travel_to(8.days.ago) { register["client_id"] }
    kept_id, = travel_to(8.days.ago) { connect }
    stale_cimd = OauthServer::Client.create!(client_id: "https://old.example/meta", registration_type: "cimd",
      redirect_uris: [ REDIRECT ], grant_types: [ "authorization_code" ], metadata_expires_at: 8.days.ago)

    register
    refute OauthServer::Client.exists?(client_id: stale_dcr)
    refute OauthServer::Client.exists?(stale_cimd.id)
    assert OauthServer::Client.exists?(client_id: kept_id)
  end

  test "a refresh deletes the connection's expired tokens" do
    client_id, tokens = connect
    travel 61.minutes do
      refresh(client_id, tokens["refresh_token"])
      assert_equal 3, OauthServer::Grant.last.tokens.count, "the expired access token is gone; spent refresh, new pair remain"
    end
  end

  # --- the settings page ---

  test "the API keys page lists a connection and revokes it" do
    _, tokens = connect
    grant = OauthServer::Grant.last

    get "/settings/api_keys"
    assert_response :success
    assert_includes response.body, "MCP connections"
    assert_includes response.body, "tadas@tadasant.com"

    post "/settings/api_keys/oauth_grants/#{grant.id}/revoke"
    assert_redirected_to "/settings/api_keys#oauth-connections"
    assert grant.reload.revoked?

    rpc("tools/list", token: tokens["access_token"])
    assert_response :unauthorized
  end
end
