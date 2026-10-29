# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The iOS app's call telemetry, end to end on the server: the app's sign-in
# posts a batch, and each event reaches the shipped-log exporter as a record.
class Api::V1::LiveTelemetryControllerTest < ActionDispatch::IntegrationTest
  include WebAuthTestHelpers

  ISSUER = "http://www.example.com"
  ENV_KEYS = [ ApiKey::ENV_VAR, "OAUTH_SERVER_ISSUER", "OAUTH_SERVER_ALLOWED_DOMAINS", "ZIMMER_DEV_WEB_USER_EMAIL" ].freeze

  class FakeExporter
    attr_reader :records

    def initialize = @records = []
    def enqueue(record) = @records << record
    def pending = 0
  end

  setup do
    @saved_env = ENV_KEYS.index_with { |k| ENV[k] }
    ENV[ApiKey::ENV_VAR] = "live-api-test-key"
    ENV["OAUTH_SERVER_ISSUER"] = ISSUER
    ENV["OAUTH_SERVER_ALLOWED_DOMAINS"] = "tadasant.com"
    ENV["ZIMMER_DEV_WEB_USER_EMAIL"] = "tadas@tadasant.com"
    WebAuth::Configuration.stubs(:current).returns(web_auth_configuration_with(client_id: nil, allowed_domains: nil))
    @exporter = FakeExporter.new
    OtelLogsExporter.stubs(:instance).returns(@exporter)
  end

  teardown do
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  BATCH = {
    client: { surface: "carplay", app_version: "1.5.0", app_build: "212", os: "iOS 26.4", device: "iPhone17,1" },
    events: [
      { seq: 7, name: "call.connected", level: "info", at: "2026-10-29T14:00:01.000Z", mono_ms: 5_000, call_id: "C-1", conversation_id: 42,
        fields: { connect_ms: 812, listening: "always" } },
      { seq: 8, name: "vad.speech_started", level: "debug", at: "2026-10-29T14:00:03.000Z", mono_ms: 7_000, call_id: "C-1", conversation_id: 42,
        fields: { audio_start_ms: 1_920 } }
    ]
  }.freeze

  test "the app's sign-in reports a batch, and every event reaches the exporter in order" do
    post "/api/v1/live/telemetry", params: BATCH, headers: bearer(app_token(privilege: OauthServer::RELAY_ONLY)), as: :json

    assert_response :accepted
    assert_equal({ "accepted" => 2, "filtered" => 0, "telemetry" => "debug" }, response.parsed_body)
    assert_equal [ "call.connected", "vad.speech_started" ], @exporter.records.map { |r| r[:attributes]["event"] }
    assert_equal [ 7, 8 ], @exporter.records.map { |r| r[:attributes]["seq"] }
    assert_equal 812, @exporter.records.first[:attributes]["connect_ms"]
    assert_equal "carplay", @exporter.records.first[:attributes]["surface"]
  end

  test "turned down on the Live settings page, the next batch is filtered and the app is told the new level" do
    LiveConversations::SettingsUpdate.call({ "voice_telemetry" => "info" }, actor: LiveConversations::SettingsUpdate::Actor.agent("test"))

    post "/api/v1/live/telemetry", params: BATCH, headers: bearer(app_token(privilege: OauthServer::ACT_AS_HUMAN)), as: :json

    assert_response :accepted
    assert_equal({ "accepted" => 1, "filtered" => 1, "telemetry" => "info" }, response.parsed_body)
    assert_equal [ "call.connected" ], @exporter.records.map { |r| r[:attributes]["event"] }
  end

  test "a malformed batch is answered, never a 500, and keeps what it can" do
    headers = bearer(app_token(privilege: OauthServer::ACT_AS_HUMAN))
    [ { client: "x", events: [ "x", 1 ], dropped: {} },
      { events: { "0" => { name: "call.connected" } } },
      { events: [ { name: "call.connected", level: "info", seq: 2**70, mono_ms: "x", at: "0001-01-01T00:00:00Z", fields: [ 1, 2 ] } ] } ].each do |batch|
      post "/api/v1/live/telemetry", params: batch, headers: headers, as: :json
      assert_response :accepted, batch.inspect
    end
    record = @exporter.records.sole
    assert_equal 0, record[:attributes]["seq"], "out of int64: not shipped as a number OTLP would refuse"
    assert_in_delta Time.now.to_f, record[:timestamp], 60, "a clock a millennium off is not believed"
  end

  test "without a sign-in nothing is accepted" do
    post "/api/v1/live/telemetry", params: BATCH, as: :json

    assert_response :unauthorized
    assert_empty @exporter.records
  end

  test "an API key cannot put lines on the stream" do
    post "/api/v1/live/telemetry", params: BATCH, headers: { "X-API-Key" => "live-api-test-key" }, as: :json

    assert_response :forbidden
    assert_empty @exporter.records
  end

  private

  def pkce
    verifier = SecureRandom.urlsafe_base64(48)
    [ verifier, Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false) ]
  end

  def app_token(privilege:)
    verifier, challenge = pkce
    post "/oauth/authorize", params: { response_type: "code", client_id: OauthServer::NativeApp::CLIENT_ID, redirect_uri: OauthServer::NativeApp::REDIRECT_URI,
      code_challenge: challenge, code_challenge_method: "S256", state: "s1", resource: "#{ISSUER}/mcp", scope: "mcp",
      decision: "approve", privilege: privilege }
    assert_response :found
    code = URI.decode_www_form(URI.parse(response.location).query).to_h.fetch("code")
    post "/oauth/token", params: { grant_type: "authorization_code", client_id: OauthServer::NativeApp::CLIENT_ID, code: code,
      code_verifier: verifier, redirect_uri: OauthServer::NativeApp::REDIRECT_URI, resource: "#{ISSUER}/mcp" }
    assert_response :success
    JSON.parse(response.body).fetch("access_token")
  end

  def bearer(access_token) = { "Authorization" => "Bearer #{access_token}" }
end
