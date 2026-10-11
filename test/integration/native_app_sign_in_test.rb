# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "ostruct"

# Zimmer's iOS app signing in through the authorization server, the way
# `ios/Sources/ZimmerKit/Auth/OAuthSignIn.swift` drives it: authorize with PKCE
# under the built-in `zimmer-ios` client, come back on the app's private-use
# scheme, redeem the code, then call the REST API with the access token.
class NativeAppSignInTest < ActionDispatch::IntegrationTest
  include WebAuthTestHelpers

  ISSUER = "http://www.example.com"
  RESOURCE = "#{ISSUER}/mcp".freeze
  CLIENT_ID = OauthServer::NativeApp::CLIENT_ID
  REDIRECT = OauthServer::NativeApp::REDIRECT_URI
  ENV_KEYS = %w[API_KEYS OAUTH_SERVER_ISSUER OAUTH_SERVER_ALLOWED_DOMAINS ZIMMER_DEV_WEB_USER_EMAIL].freeze

  setup do
    @saved_env = ENV_KEYS.index_with { |k| ENV[k] }
    ENV["API_KEYS"] = "test_api_key_native_app"
    ENV["OAUTH_SERVER_ISSUER"] = ISSUER
    ENV["OAUTH_SERVER_ALLOWED_DOMAINS"] = "tadasant.com"
    WebAuth::Configuration.stubs(:current).returns(web_auth_configuration_with(client_id: nil, allowed_domains: nil))
    ENV["ZIMMER_DEV_WEB_USER_EMAIL"] = "tadas@tadasant.com"
  end

  teardown do
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def pkce
    verifier = SecureRandom.urlsafe_base64(48)
    [ verifier, Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false) ]
  end

  def authorize_params(challenge, client_id: CLIENT_ID, redirect_uri: REDIRECT)
    { response_type: "code", client_id: client_id, redirect_uri: redirect_uri, code_challenge: challenge,
      code_challenge_method: "S256", state: "s1", resource: RESOURCE, scope: "mcp" }
  end

  # Returns the token response for a fresh sign-in.
  def sign_in(privilege: OauthServer::RELAY_ONLY)
    verifier, challenge = pkce
    post "/oauth/authorize", params: authorize_params(challenge).merge(decision: "approve", privilege: privilege)
    assert_response :found
    code = URI.decode_www_form(URI.parse(response.location).query).to_h.fetch("code")
    post "/oauth/token", params: { grant_type: "authorization_code", client_id: CLIENT_ID, code: code,
      code_verifier: verifier, redirect_uri: REDIRECT, resource: RESOURCE }
    assert_response :success
    JSON.parse(response.body)
  end

  def bearer(token) = { "Authorization" => "Bearer #{token}" }

  test "the consent screen names the built-in app and the scheme it returns to" do
    _verifier, challenge = pkce
    get "/oauth/authorize", params: authorize_params(challenge)

    assert_response :success
    assert_includes response.body, "Zimmer for iOS"
    assert_includes response.body, "own app, built in"
    assert_includes response.body, "com.tadasant.zimmer:"
    client = OauthServer::Client.find_by!(client_id: CLIENT_ID)
    assert client.first_party?
    assert_equal [ REDIRECT ], client.redirect_uris
  end

  test "approving redirects to the private-use scheme with the code, state and issuer" do
    _verifier, challenge = pkce
    post "/oauth/authorize", params: authorize_params(challenge).merge(decision: "approve", privilege: OauthServer::RELAY_ONLY)

    assert_response :found
    uri = URI.parse(response.location)
    assert_equal "com.tadasant.zimmer", uri.scheme
    assert_equal "/oauth/callback", uri.path
    query = URI.decode_www_form(uri.query).to_h
    assert_equal "s1", query["state"]
    assert_equal ISSUER, query["iss"]
    assert query["code"].present?
  end

  test "a redirect_uri other than the built-in one is refused on a page, never redirected to" do
    _verifier, challenge = pkce
    get "/oauth/authorize", params: authorize_params(challenge, redirect_uri: "com.evil.app:/oauth/callback")

    assert_response :bad_request
    assert_nil response.location
  end

  test "the connection level chosen at consent does not change what the REST API allows" do
    session = build_zimmer_session(status: :needs_input)
    [ OauthServer::RELAY_ONLY, OauthServer::ACT_AS_HUMAN ].each do |privilege|
      get "/api/v1/sessions/#{session.id}", headers: bearer(sign_in(privilege: privilege)["access_token"])
      assert_response :success, privilege
    end
  end

  test "the app's access token opens the sessions API and refreshes" do
    tokens = sign_in
    session = build_zimmer_session(status: :needs_input, title: "Needs a decision")

    get "/api/v1/sessions", params: { status: "needs_input" }, headers: bearer(tokens["access_token"])
    assert_response :success
    assert_includes JSON.parse(response.body)["sessions"].map { |s| s["id"] }, session.id

    post "/oauth/token", params: { grant_type: "refresh_token", client_id: CLIENT_ID, refresh_token: tokens["refresh_token"] }
    assert_response :success
    refreshed = JSON.parse(response.body)
    get "/api/v1/sessions/#{session.id}", headers: bearer(refreshed["access_token"])
    assert_response :success
  end

  test "the app's token does not open a controller that has not opted in" do
    tokens = sign_in

    get "/api/v1/configs", headers: bearer(tokens["access_token"])

    assert_response :unauthorized
  end

  test "a token issued to any other OAuth client is refused by the REST API" do
    post "/oauth/register", params: { client_name: "Other", redirect_uris: [ "https://claude.ai/api/mcp/auth_callback" ],
      token_endpoint_auth_method: "none" }.to_json, headers: { "Content-Type" => "application/json" }
    other = JSON.parse(response.body)["client_id"]
    verifier, challenge = pkce
    post "/oauth/authorize", params: authorize_params(challenge, client_id: other,
      redirect_uri: "https://claude.ai/api/mcp/auth_callback").merge(decision: "approve", privilege: OauthServer::RELAY_ONLY)
    code = URI.decode_www_form(URI.parse(response.location).query).to_h.fetch("code")
    post "/oauth/token", params: { grant_type: "authorization_code", client_id: other, code: code,
      code_verifier: verifier, redirect_uri: "https://claude.ai/api/mcp/auth_callback" }
    token = JSON.parse(response.body).fetch("access_token")

    get "/api/v1/sessions", headers: bearer(token)

    assert_response :unauthorized
  end

  test "a revoked grant's token is refused on the next request" do
    tokens = sign_in
    OauthServer::Client.find_by!(client_id: CLIENT_ID).grants.each { |g| g.revoke!("signed out") }

    get "/api/v1/sessions", headers: bearer(tokens["access_token"])

    assert_response :unauthorized
  end

  test "the API key path is unchanged beside it" do
    get "/api/v1/sessions", headers: { "X-API-Key" => "test_api_key_native_app" }

    assert_response :success
  end

  test "the unused-registration pruner leaves the built-in client alone" do
    client = OauthServer::NativeApp.client
    client.update_columns(created_at: 30.days.ago, metadata_expires_at: 30.days.ago)

    OauthServer::Client.prune_unused_registrations

    assert OauthServer::Client.exists?(client.id)
  end

  test "the conversation endpoint returns the transcript's messages as data, newest last" do
    tokens = sign_in
    session = build_zimmer_session(status: :needs_input, transcript: [
      { type: "user", message: { role: "user", content: "Ship it?" }, timestamp: "2026-10-09T10:00:00Z" },
      { type: "assistant", message: { role: "assistant", content: [ { type: "text", text: "PR is green. Merge?" } ] },
        timestamp: "2026-10-09T10:01:00Z" }
    ].map(&:to_json).join("\n"))

    get "/api/v1/sessions/#{session.id}/conversation", headers: bearer(tokens["access_token"])

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal %w[user assistant], body["messages"].map { |m| m["role"] }
    assert_equal "PR is green. Merge?", body["messages"].last["content"]
    assert_equal 2, body["total"]
    assert_equal false, body["truncated"]

    get "/api/v1/sessions/#{session.id}/conversation", params: { limit: 1 }, headers: bearer(tokens["access_token"])
    body = JSON.parse(response.body)
    assert_equal [ "PR is green. Merge?" ], body["messages"].map { |m| m["content"] }
    assert body["truncated"]
  end

  test "a follow-up from an app that acts on its approver's behalf is recorded as theirs; one over an API key is not" do
    tokens = sign_in(privilege: OauthServer::ACT_AS_HUMAN)
    AgentSessionJob.stubs(:enqueue_with_prompt).returns(OpenStruct.new(job_id: "job-1"))
    from_phone = build_zimmer_session(status: :needs_input)
    from_key = build_zimmer_session(status: :needs_input)

    post "/api/v1/sessions/#{from_phone.id}/follow_up", params: { prompt: "Yes, merge it." }, headers: bearer(tokens["access_token"])
    assert_response :success
    post "/api/v1/sessions/#{from_key.id}/follow_up", params: { prompt: "From a script" }, headers: { "X-API-Key" => "test_api_key_native_app" }
    assert_response :success

    message = from_phone.human_messages.sole
    assert_equal "Yes, merge it.", message.content
    assert_equal User.for_email("tadas@tadasant.com").key, message.author
    assert_equal HumanMessage::ASSISTANT, message.channel
    assert_equal "ios_app.follow_up", message.provenance["entry_point"]
    assert_equal OauthServer::Grant.sole.id, message.provenance["oauth_grant_id"]
    assert_empty from_key.human_messages
  end

  test "a follow-up is recorded as whoever approved the app, never as the admin" do
    ENV["ZIMMER_DEV_WEB_USER_EMAIL"] = "julie@tadasant.com"
    AgentSessionJob.stubs(:enqueue_with_prompt).returns(OpenStruct.new(job_id: "job-1"))
    session = build_zimmer_session(status: :needs_input)

    post "/api/v1/sessions/#{session.id}/follow_up", params: { prompt: "Ship it" },
      headers: bearer(sign_in(privilege: OauthServer::ACT_AS_HUMAN)["access_token"])

    assert_response :success
    message = session.human_messages.sole
    assert_equal "juliehazz", message.author
    assert_equal "julie@tadasant.com", message.provenance["grant_user_email"]
  end

  test "an app connection that is relay only, or whose approver is not on the roster, records nothing" do
    AgentSessionJob.stubs(:enqueue_with_prompt).returns(OpenStruct.new(job_id: "job-1"))
    relay_only = build_zimmer_session(status: :needs_input)
    post "/api/v1/sessions/#{relay_only.id}/follow_up", params: { prompt: "Yes" },
      headers: bearer(sign_in(privilege: OauthServer::RELAY_ONLY)["access_token"])
    assert_response :success
    assert_empty relay_only.human_messages

    ENV["ZIMMER_DEV_WEB_USER_EMAIL"] = "someone-else@tadasant.com"
    unknown = build_zimmer_session(status: :needs_input)
    post "/api/v1/sessions/#{unknown.id}/follow_up", params: { prompt: "Yes" },
      headers: bearer(sign_in(privilege: OauthServer::ACT_AS_HUMAN)["access_token"])
    assert_response :success
    assert_empty unknown.human_messages, "never recorded as the admin on someone else's grant"
  end

  test "a follow-up the app sends mid-turn is queued and still recorded as the approver's words" do
    tokens = sign_in(privilege: OauthServer::ACT_AS_HUMAN)
    session = build_zimmer_session(status: :running)
    Sessions::LiveTurn.stubs(:underway?).returns(true)

    post "/api/v1/sessions/#{session.id}/follow_up", params: { prompt: "Also deploy it." }, headers: bearer(tokens["access_token"])

    assert_response :accepted
    assert_equal "pending", JSON.parse(response.body).dig("enqueued_message", "status")
    assert_equal "ios_app.follow_up", session.human_messages.sole.provenance["entry_point"]
  end

  test "the app archives a session with its token" do
    tokens = sign_in
    session = build_zimmer_session(status: :needs_input)

    post "/api/v1/sessions/#{session.id}/archive", headers: bearer(tokens["access_token"])

    assert_response :success
    assert session.reload.archived?
  end

  test "the app starts a Quick Router session with its token, recorded as ios_app" do
    tokens = sign_in(privilege: OauthServer::ACT_AS_HUMAN)
    AgentRootsConfig.stubs(:find!).with(AgentRootsConfig.router_root_name).returns(
      OpenStruct.new(url: "https://github.com/test/repo.git", default_branch: "main",
                     subdirectory: "agent-roots/zimmer-orchestrator", default_mcp_servers: [])
    )
    AgentSessionJob.stubs(:enqueue_new_session)

    post "/api/v1/quick_router", params: { prompt: "Rotate the staging deploy key" }, headers: bearer(tokens["access_token"])

    assert_response :created
    session = Session.find(JSON.parse(response.body)["session_id"])
    assert_equal "ios_app", session.metadata["source"]
    message = session.human_messages.sole
    assert_equal "ios_app.quick_router", message.provenance["entry_point"]
    assert_equal HumanMessage::ASSISTANT, message.channel
    assert_equal User.for_email("tadas@tadasant.com").key, message.author
    # An OAuth-delivered start, like MCP's quick_router: `api` genesis, so capture
    # coverage never expects a web UI record for it, at priority because a person waits.
    assert_equal SessionGenesis::API, session.genesis
    assert_equal SessionGenesis::PRIORITY, session.scheduling_class
  end

  test "a Quick Router session from a relay-only app connection is started and records nothing" do
    AgentRootsConfig.stubs(:find!).with(AgentRootsConfig.router_root_name).returns(
      OpenStruct.new(url: "https://github.com/test/repo.git", default_branch: "main",
                     subdirectory: "agent-roots/zimmer-orchestrator", default_mcp_servers: [])
    )
    AgentSessionJob.stubs(:enqueue_new_session)

    post "/api/v1/quick_router", params: { prompt: "Rotate the staging deploy key" },
      headers: bearer(sign_in(privilege: OauthServer::RELAY_ONLY)["access_token"])

    assert_response :created
    assert_empty Session.find(JSON.parse(response.body)["session_id"]).human_messages
  end

  test "the app registers its phone for push, tied to its grant; revoking the grant stops the pushes" do
    tokens = sign_in
    token = "ab" * 32

    post "/api/v1/apns_devices", params: { token: token, environment: "production", device_name: "iPhone", app_version: "0.1.0 (3)" },
      headers: bearer(tokens["access_token"])

    assert_response :created
    device = ApnsDevice.find_by!(token: token)
    assert_equal OauthServer::NativeApp.client.grants.sole, device.grant
    assert_includes ApnsDevice.deliverable, device

    device.grant.revoke!("signed out elsewhere")
    assert_not_includes ApnsDevice.deliverable, device

    # Deleting the grant outright must not leave a grant-less row behind, which would
    # read as an API-key registration and be deliverable again.
    device.grant.destroy!
    assert_not ApnsDevice.exists?(device.id)
  end

  test "the app unregisters its own phone on sign-out, never another's, and a bad registration is refused" do
    tokens = sign_in
    post "/api/v1/apns_devices", params: { token: "cd" * 32, environment: "sandbox" }, headers: bearer(tokens["access_token"])
    someone_elses = ApnsDevice.register!(token: "ef" * 32, environment: "sandbox", grant: nil)

    delete "/api/v1/apns_devices/#{'ef' * 32}", headers: bearer(tokens["access_token"])
    assert_response :no_content
    assert ApnsDevice.exists?(someone_elses.id), "a token registered under another credential is out of reach"

    delete "/api/v1/apns_devices/#{'cd' * 32}", headers: bearer(tokens["access_token"])
    assert_response :no_content
    assert_equal [ someone_elses ], ApnsDevice.all.to_a

    post "/api/v1/apns_devices", params: { token: "nope", environment: "production" }, headers: bearer(tokens["access_token"])
    assert_response :unprocessable_entity
    post "/api/v1/apns_devices", params: { environment: "production" }, headers: bearer(tokens["access_token"])
    assert_response :unprocessable_entity
  end

  private

  def build_zimmer_session(**attrs)
    Session.create!({ git_root: "https://github.com/tadasant/zimmer.git", branch: "main", prompt: "p" }.merge(attrs))
  end
end
