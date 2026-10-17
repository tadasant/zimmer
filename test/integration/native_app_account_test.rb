# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The auth boundary over REST, for the iOS app: who the caller is (`/me`), the
# OAuth connections and API keys the Settings → API keys page lists, and signing
# out everywhere. Reads answer any grant; every write takes a grant that acts as
# you, and refuses an API key and a relay-only grant with a 403.
class NativeAppAccountTest < ActionDispatch::IntegrationTest
  include WebAuthTestHelpers

  ISSUER = "http://www.example.com"
  RESOURCE = "#{ISSUER}/mcp".freeze
  CLIENT_ID = OauthServer::NativeApp::CLIENT_ID
  REDIRECT = OauthServer::NativeApp::REDIRECT_URI
  API_KEY = "test_api_key_native_account"
  EMAIL = "tadas@tadasant.com"
  ENV_KEYS = %w[API_KEYS OAUTH_SERVER_ISSUER OAUTH_SERVER_ALLOWED_DOMAINS ZIMMER_DEV_WEB_USER_EMAIL].freeze

  setup do
    @saved_env = ENV_KEYS.index_with { |k| ENV[k] }
    ENV["API_KEYS"] = API_KEY
    ENV["OAUTH_SERVER_ISSUER"] = ISSUER
    ENV["OAUTH_SERVER_ALLOWED_DOMAINS"] = "tadasant.com"
    WebAuth::Configuration.stubs(:current).returns(web_auth_configuration_with(client_id: nil, allowed_domains: nil))
    ENV["ZIMMER_DEV_WEB_USER_EMAIL"] = EMAIL
  end

  teardown do
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # --- /me ---------------------------------------------------------------

  test "me names the person, how the app signed in, its own grant, and the deployment" do
    access = token
    get "/api/v1/me", headers: bearer(access)

    assert_response :success
    body = JSON.parse(response.body)
    me = body["me"]
    assert_equal "native_app", me["authenticated_as"]
    assert_equal EMAIL, me["email"]
    assert_equal OauthServer::RELAY_ONLY, me["privilege"]
    assert_equal false, me["acts_as_you"]
    assert_equal grant_for(access).id, me["grant_id"]
    assert_nil me["api_key"]
    assert_nil body["web_sign_in"], "web sign-in is not configured, so the card has nothing to show"
    assert_equal %w[commit_sha commit_short branch commit_date], body.dig("deployment", "git").keys
    assert_equal "test", body.dig("deployment", "environment", "rails_env")
  end

  test "me shows the Sign-in card's authenticator age and recovery codes once web sign-in is on" do
    access = token(privilege: OauthServer::ACT_AS_HUMAN)
    WebIdentity.create!(google_sub: "sub-1", email: EMAIL, hosted_domain: "tadasant.com", name: "Tadas",
      totp_secret: "JBSWY3DPEHPK3PXP", totp_enrolled_at: 3.days.ago, last_signed_in_at: 1.hour.ago,
      recovery_code_digests: %w[a b c])
    WebAuth::Configuration.stubs(:current).returns(web_auth_configuration_with)

    get "/api/v1/me", headers: bearer(access)

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body.dig("me", "acts_as_you")
    assert_equal OauthServer::ACT_AS_HUMAN, body.dig("me", "privilege")
    card = body["web_sign_in"]
    assert_equal EMAIL, card["email"]
    assert_equal "Tadas", card["name"]
    assert_equal true, card["totp_required"]
    assert_in_delta 3.days.ago, Time.zone.parse(card["totp_enrolled_at"]), 5
    assert_equal 3, card["recovery_codes_remaining"]
  end

  test "me over an API key names the key and no person" do
    get "/api/v1/me", headers: { "X-API-Key" => API_KEY }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "api_key", body.dig("me", "authenticated_as")
    assert_nil body.dig("me", "email")
    assert_nil body.dig("me", "grant_id")
    assert_equal ApiKey::API_GRANT, body.dig("me", "api_key", "grant")
    assert_nil body["web_sign_in"]
  end

  # --- OAuth connections -------------------------------------------------

  test "the connections list flags the caller's own grant as current, on a relay grant too" do
    mine = token
    other = grant_for(token(privilege: OauthServer::ACT_AS_HUMAN))

    get "/api/v1/oauth_grants", headers: bearer(mine)

    assert_response :success
    rows = JSON.parse(response.body)["oauth_grants"]
    current = rows.select { |r| r["current"] }
    assert_equal [ grant_for(mine).id ], current.map { |r| r["id"] }
    theirs = rows.find { |r| r["id"] == other.id }
    assert_equal OauthServer::ACT_AS_HUMAN, theirs["privilege"]
    assert_equal "active", theirs["status"]
    assert_equal true, theirs["first_party"]
    assert_equal EMAIL, theirs["user_email"]
    assert_equal false, theirs["current"]

    get "/api/v1/oauth_grants", headers: { "X-API-Key" => API_KEY }
    assert_response :success
    assert JSON.parse(response.body)["oauth_grants"].none? { |r| r["current"] }, "an API key is nobody's connection"
  end

  test "revoking or re-levelling a connection is refused on a relay grant and over an API key" do
    relay = token
    other = grant_for(token(privilege: OauthServer::ACT_AS_HUMAN))

    delete "/api/v1/oauth_grants/#{other.id}", headers: bearer(relay)
    assert_response :forbidden
    assert_match(/may not act as you/, JSON.parse(response.body)["message"])
    delete "/api/v1/oauth_grants/#{grant_for(relay).id}", headers: bearer(relay)
    assert_response :forbidden, "not even its own"
    patch "/api/v1/oauth_grants/#{grant_for(relay).id}", params: { privilege: OauthServer::ACT_AS_HUMAN }, headers: bearer(relay)
    assert_response :forbidden, "a relay grant cannot raise itself"
    assert_equal OauthServer::RELAY_ONLY, grant_for(relay).reload.privilege
    patch "/api/v1/oauth_grants/#{other.id}", params: { privilege: OauthServer::RELAY_ONLY }, headers: bearer(relay)
    assert_response :forbidden

    delete "/api/v1/oauth_grants/#{other.id}", headers: { "X-API-Key" => API_KEY }
    assert_response :forbidden
    assert_match(/Only a person/, JSON.parse(response.body)["message"])
    patch "/api/v1/oauth_grants/#{other.id}", params: { privilege: OauthServer::RELAY_ONLY }, headers: { "X-API-Key" => API_KEY }
    assert_response :forbidden
    delete "/api/v1/oauth_grants/0", headers: { "X-API-Key" => API_KEY }
    assert_response :forbidden, "refused before the lookup"

    assert_not other.reload.revoked?
    assert_equal OauthServer::ACT_AS_HUMAN, other.privilege
  end

  test "acting as you, the app revokes another connection and moves one between levels" do
    headers = bearer(token(privilege: OauthServer::ACT_AS_HUMAN))
    other = grant_for(token(privilege: OauthServer::ACT_AS_HUMAN))

    patch "/api/v1/oauth_grants/#{other.id}", params: { privilege: OauthServer::RELAY_ONLY }, headers: headers
    assert_response :success
    assert_equal OauthServer::RELAY_ONLY, other.reload.privilege
    assert_equal OauthServer::Grant::APP_DOWNGRADE, other.scope_change_reason
    assert_equal OauthServer::RELAY_ONLY, JSON.parse(response.body).dig("oauth_grant", "privilege")

    patch "/api/v1/oauth_grants/#{other.id}", params: { privilege: OauthServer::ACT_AS_HUMAN }, headers: headers
    assert_response :success
    assert_equal OauthServer::Grant::APP_UPGRADE, other.reload.scope_change_reason

    patch "/api/v1/oauth_grants/#{other.id}", params: { privilege: "root" }, headers: headers
    assert_response :unprocessable_entity

    delete "/api/v1/oauth_grants/#{other.id}", headers: headers
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal false, body["signed_out"]
    assert_equal "revoked", body.dig("oauth_grant", "status")
    assert other.reload.revoked?
    assert_match(/#{Regexp.escape(EMAIL)} via the iOS app/, other.revocation_reason)

    patch "/api/v1/oauth_grants/#{other.id}", params: { privilege: OauthServer::RELAY_ONLY }, headers: headers
    assert_response :unprocessable_entity, "a revoked connection has to be approved again"
    delete "/api/v1/oauth_grants/#{other.id}", headers: headers
    assert_response :success, "revoking twice changes nothing and is not an error"
  end

  test "revoking its own connection signs the app out: the next request is a 401" do
    access = token(privilege: OauthServer::ACT_AS_HUMAN)

    delete "/api/v1/oauth_grants/#{grant_for(access).id}", headers: bearer(access)
    assert_response :success
    assert_equal true, JSON.parse(response.body)["signed_out"]

    get "/api/v1/me", headers: bearer(access)
    assert_response :unauthorized
  end

  # --- API keys ----------------------------------------------------------

  test "the keys list shows fingerprints and never a key, on a relay grant and over an API key" do
    get "/api/v1/api_keys", headers: bearer(token)

    assert_response :success
    rows = JSON.parse(response.body)["api_keys"]
    env_row = rows.find { |r| r["fingerprint"] == ApiKey.digest(API_KEY)[0, ApiKey::FINGERPRINT_LENGTH] }
    assert env_row, "the API_KEYS entry is registered and listed before it is ever used"
    assert_equal "env", env_row["source"]
    assert_equal "active", env_row["status"]
    assert_not_includes response.body, API_KEY
    assert_nil env_row["token"]

    get "/api/v1/api_keys", headers: { "X-API-Key" => API_KEY }
    assert_response :success
  end

  test "minting, revoking and restoring a key are refused on a relay grant and over an API key" do
    relay = token
    existing, _secret = ApiKey.mint!(name: "laptop")

    post "/api/v1/api_keys", params: { name: "phone" }, headers: bearer(relay)
    assert_response :forbidden
    delete "/api/v1/api_keys/#{existing.id}", headers: bearer(relay)
    assert_response :forbidden
    post "/api/v1/api_keys/#{existing.id}/restore", headers: { "X-API-Key" => API_KEY }
    assert_response :forbidden
    post "/api/v1/api_keys/#{existing.id}/restore", headers: bearer(relay)
    assert_response :forbidden

    post "/api/v1/api_keys", params: { name: "phone" }, headers: { "X-API-Key" => API_KEY }
    assert_response :forbidden
    assert_match(/Only a person/, JSON.parse(response.body)["message"])
    delete "/api/v1/api_keys/#{existing.id}", headers: { "X-API-Key" => API_KEY }
    assert_response :forbidden

    assert_not existing.reload.revoked?
    assert_nil ApiKey.find_by(name: "phone")
  end

  test "acting as you, the app mints a key whose secret is returned once, then revokes and restores it" do
    headers = bearer(token(privilege: OauthServer::ACT_AS_HUMAN))

    post "/api/v1/api_keys", params: { name: "phone scripts" }, headers: headers
    assert_response :created
    assert_equal "no-store", response.headers["Cache-Control"]
    body = JSON.parse(response.body)
    secret = body["token"]
    assert secret.start_with?(ApiKey::MINTED_PREFIX)
    assert_equal "phone scripts", body.dig("api_key", "name")
    assert_equal ApiKey::API_GRANT, body.dig("api_key", "grant")
    assert_equal "minted", body.dig("api_key", "source")
    id = body.dig("api_key", "id")

    get "/api/v1/api_keys", headers: headers
    assert_not_includes response.body, secret, "the list never shows the key again"
    get "/api/v1/sessions", headers: { "X-API-Key" => secret }
    assert_response :success, "the minted key opens the API"

    delete "/api/v1/api_keys/#{id}", headers: headers
    assert_response :success
    assert_equal "revoked", JSON.parse(response.body).dig("api_key", "status")
    get "/api/v1/sessions", headers: { "X-API-Key" => secret }
    assert_response :unauthorized

    post "/api/v1/api_keys/#{id}/restore", headers: headers
    assert_response :success
    assert_equal "active", JSON.parse(response.body).dig("api_key", "status")
    get "/api/v1/sessions", headers: { "X-API-Key" => secret }
    assert_response :success
  end

  test "minting validates as the page does: the form's nesting, a quick_router grant, and the page's refusals" do
    headers = bearer(token(privilege: OauthServer::ACT_AS_HUMAN))

    post "/api/v1/api_keys", params: { api_key: { name: "extension", grant: ApiKey::QUICK_ROUTER_GRANT } }, headers: headers
    assert_response :created
    assert_equal ApiKey::QUICK_ROUTER_GRANT, JSON.parse(response.body).dig("api_key", "grant")

    post "/api/v1/api_keys", params: { name: "Extension" }, headers: headers
    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["messages"], "Name has already been taken"

    post "/api/v1/api_keys", params: { name: "" }, headers: headers
    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["messages"], "Name can't be blank"

    post "/api/v1/api_keys", params: { name: "x" * 101 }, headers: headers
    assert_response :unprocessable_entity

    post "/api/v1/api_keys", params: { name: "plugin", grant: ApiKey::EXTERNAL_APP_GRANT }, headers: headers
    assert_response :unprocessable_entity, "a plugin key is minted on the plugin's page, not here"

    post "/api/v1/api_keys", params: { name: "everything", grant: "all" }, headers: headers
    assert_response :unprocessable_entity, "an unknown grant is refused, not widened to the whole API"
    assert_nil ApiKey.find_by(name: "everything")
  end

  # --- Sign out everywhere -------------------------------------------------

  test "sign out everywhere is refused on a relay grant and over an API key" do
    relay = token

    post "/api/v1/sign_out_everywhere", headers: bearer(relay)
    assert_response :forbidden
    post "/api/v1/sign_out_everywhere", headers: { "X-API-Key" => API_KEY }
    assert_response :forbidden

    assert_not grant_for(relay).revoked?
  end

  test "acting as you, sign out everywhere ends the web sessions and revokes the caller's own connection" do
    identity = WebIdentity.create!(google_sub: "sub-2", email: EMAIL, hosted_domain: "tadasant.com", session_generation: 4)
    someone_else = WebIdentity.create!(google_sub: "sub-3", email: "other@tadasant.com", hosted_domain: "tadasant.com")
    access = token(privilege: OauthServer::ACT_AS_HUMAN)
    bystander = grant_for(token(privilege: OauthServer::ACT_AS_HUMAN))

    post "/api/v1/sign_out_everywhere", headers: bearer(access)

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body["signed_out_everywhere"]
    assert_equal 1, body["web_sign_ins_ended"]
    assert_equal true, body["this_connection_revoked"]
    assert_equal 5, identity.reload.session_generation
    assert_equal 0, someone_else.reload.session_generation
    assert grant_for(access).revoked?
    assert_not bystander.reload.revoked?, "other phones keep their connections, as other OAuth clients do"

    get "/api/v1/me", headers: bearer(access)
    assert_response :unauthorized
  end

  private

  def pkce
    verifier = SecureRandom.urlsafe_base64(48)
    [ verifier, Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false) ]
  end

  def token(privilege: OauthServer::RELAY_ONLY)
    verifier, challenge = pkce
    post "/oauth/authorize", params: { response_type: "code", client_id: CLIENT_ID, redirect_uri: REDIRECT,
      code_challenge: challenge, code_challenge_method: "S256", state: "s1", resource: RESOURCE, scope: "mcp",
      decision: "approve", privilege: privilege }
    assert_response :found
    code = URI.decode_www_form(URI.parse(response.location).query).to_h.fetch("code")
    post "/oauth/token", params: { grant_type: "authorization_code", client_id: CLIENT_ID, code: code,
      code_verifier: verifier, redirect_uri: REDIRECT, resource: RESOURCE }
    assert_response :success
    JSON.parse(response.body).fetch("access_token")
  end

  def bearer(access_token) = { "Authorization" => "Bearer #{access_token}" }

  def grant_for(access_token)
    OauthServer::Token.find_by!(token_digest: OauthServer.digest(access_token)).grant
  end
end
