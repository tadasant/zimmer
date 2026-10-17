# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The turn-source note at the REST boundary, end to end: the credential decides the
# surface, the two headers can only refine it, anything off the allowlist degrades
# to `unknown` rather than an error — and none of it moves who Zimmer says is
# speaking, which stays keyed off the credential exactly as before.
class TurnSourceBoundariesTest < ActionDispatch::IntegrationTest
  include WebAuthTestHelpers

  ISSUER = "http://www.example.com"
  RESOURCE = "#{ISSUER}/mcp".freeze
  CLIENT_ID = OauthServer::NativeApp::CLIENT_ID
  REDIRECT = OauthServer::NativeApp::REDIRECT_URI
  API_KEY = "test_api_key_turn_source"
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

  test "an iOS build that sends nothing is tagged as the iOS app with an unknown modality, never refused" do
    session = idle_session

    post "/api/v1/sessions/#{session.id}/follow_up", params: { prompt: "Ship it" },
      headers: bearer(token(privilege: OauthServer::ACT_AS_HUMAN))

    assert_response :success, response.body
    session.reload
    assert_equal TurnSource.new(surface: "ios").annotate("Ship it"), session.metadata["pending_follow_up_prompt"]
    assert_equal({ "surface" => "ios", "modality" => "unknown" }, session.metadata["last_turn_source"])
    assert_equal({ "surface" => "ios", "modality" => "unknown", "label" => "Sent from the Zimmer iOS app" },
      JSON.parse(response.body).dig("session", "last_turn_source"))
  end

  test "CarPlay's dictated follow-up is tagged carplay and voice dictation, with the app's version kept" do
    session = idle_session

    post "/api/v1/sessions/#{session.id}/follow_up", params: { prompt: "Ship it" },
      headers: bearer(token(privilege: OauthServer::ACT_AS_HUMAN))
        .merge("X-Zimmer-Client" => "carplay/1.4.2", "X-Zimmer-Input-Modality" => "voice_dictation")

    assert_response :success, response.body
    session.reload
    source = session.last_turn_source
    assert_equal [ "carplay", "voice_dictation", "1.4.2" ], [ source.surface, source.modality, source.client_version ]
    assert_includes session.metadata["pending_follow_up_prompt"],
      ">Sent from Zimmer on CarPlay · voice dictation — spoken and transcribed"
  end

  test "who is speaking is untouched by the headers: the app's grant records the human, as it always did" do
    session = idle_session

    assert_difference -> { session.human_messages.count }, 1 do
      post "/api/v1/sessions/#{session.id}/follow_up", params: { prompt: "Ship it" },
        headers: bearer(token(privilege: OauthServer::ACT_AS_HUMAN)).merge("X-Zimmer-Input-Modality" => "voice_dictation")
    end

    message = session.human_messages.last
    assert_equal "Ship it", message.content, "the note goes to the agent, never into the human's record"
    assert_equal HumanMessage::ASSISTANT, message.channel
  end

  test "an API key cannot dress up as the iOS app or claim a Live modality, and records no human" do
    session = idle_session

    assert_no_difference -> { HumanMessage.count } do
      post "/api/v1/sessions/#{session.id}/follow_up", params: { prompt: "Ship it" },
        headers: api_key.merge("X-Zimmer-Client" => "ios/9.9", "X-Zimmer-Input-Modality" => "live_voice")
    end

    assert_response :success, response.body
    source = session.reload.last_turn_source
    assert_equal [ "api", "unknown", nil ], [ source.surface, source.modality, source.client_version ]
  end

  test "an off-list modality degrades to unknown instead of failing the request" do
    session = idle_session

    post "/api/v1/sessions/#{session.id}/follow_up", params: { prompt: "Ship it" },
      headers: api_key.merge("X-Zimmer-Input-Modality" => "<b>shouting</b>", "X-Zimmer-Client" => "fridge/../../etc")

    assert_response :success, response.body
    assert_equal({ "surface" => "api", "modality" => "unknown" }, session.reload.metadata["last_turn_source"])
  end

  test "a caller naming the session acting on it is tagged as another agent" do
    session = idle_session
    acting = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "router", status: :running)

    post "/api/v1/sessions/#{session.id}/follow_up", params: { prompt: "Carry on", acting_session_id: acting.id },
      headers: api_key.merge("X-Zimmer-Input-Modality" => "voice_dictation")

    assert_response :success, response.body
    source = session.reload.last_turn_source
    assert_equal [ "agent", "unknown" ], [ source.surface, source.modality ], "a machine surface claims no modality"
    assert_includes session.metadata["pending_follow_up_prompt"], ">Written by another agent session — machine-written"
  end

  test "a follow-up queued behind a running turn keeps its source for delivery, and the row keeps the words alone" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "p", status: :running)
    Sessions::LiveTurn.stubs(:underway?).returns(true)

    post "/api/v1/sessions/#{session.id}/follow_up", params: { prompt: "Then deploy" },
      headers: bearer(token(privilege: OauthServer::ACT_AS_HUMAN)).merge("X-Zimmer-Input-Modality" => "text")

    assert_response :accepted, response.body
    queued = session.enqueued_messages.last
    assert_equal "Then deploy", queued.content
    assert_equal({ "surface" => "ios", "modality" => "text" }, queued.source_context)
  end

  test "a session created over the API records where its first prompt came from" do
    post "/api/v1/sessions", params: { prompt: "Look into the flaky test", git_root: "https://github.com/test/repo.git" },
      headers: api_key

    assert_response :created, response.body
    session = Session.find(JSON.parse(response.body).dig("session", "id"))
    assert_equal({ "surface" => "api", "modality" => "unknown" }, session.source_context)
    assert_equal "Look into the flaky test", session.prompt, "the stored prompt is the caller's words"
    assert session.initial_prompt_for_delivery.start_with?("Look into the flaky test\n\n<zimmer-turn-source surface=\"api\"")
  end

  private

  def idle_session
    Session.create!(git_root: "https://github.com/test/repo.git", prompt: "p", status: :needs_input, session_id: "runtime-1")
  end

  def api_key = { "X-API-Key" => API_KEY }

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
