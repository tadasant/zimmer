# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The two REST actions that stand for a person's decision — the User view's Merge
# and Reprioritize buttons — reach only the iOS app's token on a grant that acts
# as its approver. An API key is the fleet's, and a relay-only grant was approved
# to carry messages, not to decide.
class NativeAppPersonActionsTest < ActionDispatch::IntegrationTest
  include WebAuthTestHelpers

  ISSUER = "http://www.example.com"
  RESOURCE = "#{ISSUER}/mcp".freeze
  CLIENT_ID = OauthServer::NativeApp::CLIENT_ID
  REDIRECT = OauthServer::NativeApp::REDIRECT_URI
  API_KEY = "test_api_key_person_actions"
  GREEN_PR = "https://github.com/test/repo/pull/7"
  ENV_KEYS = %w[API_KEYS OAUTH_SERVER_ISSUER OAUTH_SERVER_ALLOWED_DOMAINS ZIMMER_DEV_WEB_USER_EMAIL].freeze

  setup do
    @saved_env = ENV_KEYS.index_with { |k| ENV[k] }
    ENV["API_KEYS"] = API_KEY
    ENV["OAUTH_SERVER_ISSUER"] = ISSUER
    ENV["OAUTH_SERVER_ALLOWED_DOMAINS"] = "tadasant.com"
    WebAuth::Configuration.stubs(:current).returns(web_auth_configuration_with(client_id: nil, allowed_domains: nil))
    ENV["ZIMMER_DEV_WEB_USER_EMAIL"] = "tadas@tadasant.com"
  end

  teardown do
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  test "Merge from an app that acts as you sends the authorization and records it as yours" do
    session = green_session

    post "/api/v1/sessions/#{session.id}/authorize_merge", headers: bearer(token(privilege: OauthServer::ACT_AS_HUMAN))

    assert_response :success, response.body
    assert_equal "sent", JSON.parse(response.body)["outcome"]
    queued = session.enqueued_messages.pending.last
    assert AutomatedPrompts.merge_authorization?(queued.content)
    message = session.human_messages.sole
    assert_equal "Merge #{GREEN_PR}", message.content
    assert_equal "ios_app.authorize_merge", message.provenance["entry_point"]
    assert_equal User.for_email("tadas@tadasant.com").key, message.author

    post "/api/v1/sessions/#{session.id}/authorize_merge", headers: bearer(token(privilege: OauthServer::ACT_AS_HUMAN))
    assert_response :success
    assert_equal "already_sent", JSON.parse(response.body)["outcome"]
    assert_equal 1, session.human_messages.count, "a second tap records nothing"
  end

  test "Merge on a PR that is not green says why" do
    session = green_session
    session.update!(custom_metadata: session.custom_metadata.merge("github_pull_request_ci_statuses" => { GREEN_PR => "pending" }))

    post "/api/v1/sessions/#{session.id}/authorize_merge", headers: bearer(token(privilege: OauthServer::ACT_AS_HUMAN))

    assert_response :unprocessable_entity
    assert_match(/CI is pending/, JSON.parse(response.body)["message"])
    assert_empty session.enqueued_messages
  end

  test "Merge refuses an API key and a relay-only app, and sends nothing" do
    session = green_session

    post "/api/v1/sessions/#{session.id}/authorize_merge", headers: { "X-API-Key" => API_KEY }
    assert_response :forbidden
    assert_match(/Only a person/, JSON.parse(response.body)["message"])

    post "/api/v1/sessions/#{session.id}/authorize_merge", headers: bearer(token)
    assert_response :forbidden
    assert_match(/may not act as you/, JSON.parse(response.body)["message"])

    assert_empty session.enqueued_messages
    assert_empty session.human_messages
  end

  test "Reprioritize from an app that acts as you hands the board over and names the session" do
    reprioritizer = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "rank", status: :running)
    Sessions::DashboardReprioritizer.expects(:call).once.returns(
      Sessions::DashboardReprioritizer::Result.new(session: reprioritizer, outcome: :fired, message: "Reprioritizing in session ##{reprioritizer.id}")
    )

    post "/api/v1/sessions/reprioritize", headers: bearer(token(privilege: OauthServer::ACT_AS_HUMAN))

    assert_response :success, response.body
    body = JSON.parse(response.body)
    assert_equal "fired", body["outcome"]
    assert_equal reprioritizer.id, body.dig("session", "id")
  end

  test "Reprioritize that did not hand the board over is a 422 with no session" do
    Sessions::DashboardReprioritizer.expects(:call).returns(
      Sessions::DashboardReprioritizer::Result.new(session: nil, outcome: :burst_suppressed, message: "Pressed a moment ago")
    )

    post "/api/v1/sessions/reprioritize", headers: bearer(token(privilege: OauthServer::ACT_AS_HUMAN))

    assert_response :unprocessable_entity
    assert_nil JSON.parse(response.body)["session"]
  end

  test "Reprioritize refuses an API key and a relay-only app before doing anything" do
    Sessions::DashboardReprioritizer.expects(:call).never

    post "/api/v1/sessions/reprioritize", headers: { "X-API-Key" => API_KEY }
    assert_response :forbidden
    post "/api/v1/sessions/reprioritize", headers: bearer(token)
    assert_response :forbidden
  end

  private

  def green_session
    Session.create!(git_root: "https://github.com/test/repo.git", prompt: "p", status: :running, custom_metadata: {
      "github_pull_request_urls" => [ GREEN_PR ],
      "github_pull_request_statuses" => { GREEN_PR => "open" },
      "github_pull_request_ci_statuses" => { GREEN_PR => "pass" }
    })
  end

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
end
