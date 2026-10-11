# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class ApnsServiceTest < ActiveSupport::TestCase
  # A transport that records requests and answers from a script.
  class FakeTransport
    attr_reader :requests

    def initialize(*responses)
      @responses = responses
      @requests = []
    end

    def post(url, headers:, body:)
      @requests << { url: url, headers: headers, body: JSON.parse(body) }
      response = @responses.shift || [ 200, "" ]
      raise response if response.is_a?(Exception)

      ApnsService::Transport::Response.new(status: response[0], body: response[1])
    end
  end

  # Config without the secret chain: the values a deployment would place.
  ConfigDouble = Struct.new(:key_id, :team_id, :topic, :signing_key, keyword_init: true) do
    def configured? = key_id.present? && team_id.present? && signing_key.present?
    def missing = configured? ? [] : %w[APNS_AUTH_KEY_P8 APNS_KEY_ID APNS_TEAM_ID]
  end

  setup do
    ApnsService.reset_provider_tokens!
    @key = OpenSSL::PKey::EC.generate("prime256v1")
    @config = ConfigDouble.new(key_id: "ABC123DEFG", team_id: "TEAM123456", topic: "com.tadasant.zimmer", signing_key: @key)
    @phone = ApnsDevice.register!(token: "a" * 64, environment: ApnsDevice::PRODUCTION, grant: nil, device_name: "iPhone")
    @dev_build = ApnsDevice.register!(token: "b" * 64, environment: ApnsDevice::SANDBOX, grant: nil)
    @payload = { title: "PR #1261 is green", body: "Needs your go-ahead", url: "/notifications",
                 data: { session_id: 1038, notification_type: "needs_input" } }
  end

  test "unconfigured, it sends nothing and says so" do
    transport = FakeTransport.new
    result = ApnsService.new(config: ConfigDouble.new, transport: transport).send_to_all(**@payload)

    assert_equal({ sent: 0, failed: 0, disabled: 0, skipped: true }, result)
    assert_empty transport.requests
  end

  test "with no key anywhere, the real config is unconfigured" do
    refute Apns::Config.new.configured?
    assert_equal %w[APNS_AUTH_KEY_P8 APNS_KEY_ID APNS_TEAM_ID], Apns::Config.new.missing
    assert_equal "com.tadasant.zimmer", Apns::Config.new.topic
  end

  test "configured, it posts an alert to each device's own environment with a provider token" do
    transport = FakeTransport.new([ 200, "" ], [ 200, "" ])
    result = ApnsService.new(config: @config, transport: transport).send_to_all(**@payload)

    assert_equal({ sent: 2, failed: 0, disabled: 0 }, result)
    urls = transport.requests.map { |r| r[:url] }.sort
    assert_equal [ "https://api.push.apple.com/3/device/#{'a' * 64}", "https://api.sandbox.push.apple.com/3/device/#{'b' * 64}" ], urls

    request = transport.requests.first
    assert_equal "com.tadasant.zimmer", request[:headers]["apns-topic"]
    assert_equal "alert", request[:headers]["apns-push-type"]
    assert_equal "session-1038-needs_input", request[:headers]["apns-collapse-id"]
    jwt = request[:headers]["authorization"].delete_prefix("bearer ")
    claims, header = JWT.decode(jwt, @key, true, algorithms: [ "ES256" ])
    assert_equal "TEAM123456", claims["iss"]
    assert_equal "ABC123DEFG", header["kid"]

    body = request[:body]
    # Generic: Apple can read an alert, so no session text goes in it.
    assert_equal({ "title" => "Zimmer", "body" => "A session needs you." }, body["aps"]["alert"])
    assert_not_includes request[:body].to_json, "PR #1261"
    assert_not_includes request[:body].to_json, "go-ahead"
    assert_equal "session-1038", body["aps"]["thread-id"]
    assert_equal 1038, body["session_id"]
    assert_not_nil @phone.reload.last_delivered_at
  end

  test "a token Apple says is dead is disabled and not tried again" do
    transport = FakeTransport.new([ 410, { reason: "Unregistered" }.to_json ], [ 400, { reason: "BadDeviceToken" }.to_json ])
    result = ApnsService.new(config: @config, transport: transport).send_to_all(**@payload)

    assert_equal 2, result[:disabled]
    assert_equal %w[BadDeviceToken Unregistered], [ @phone.reload.disabled_reason, @dev_build.reload.disabled_reason ].sort
    assert_empty ApnsDevice.deliverable

    second = FakeTransport.new
    ApnsService.new(config: @config, transport: second).send_to_all(**@payload)
    assert_empty second.requests
  end

  test "a rejected provider token is minted afresh next time; a network error is counted, never raised" do
    transport = FakeTransport.new([ 403, { reason: "ExpiredProviderToken" }.to_json ], Errno::ECONNRESET.new)
    first_token = ApnsService.provider_token(@config)

    result = ApnsService.new(config: @config, transport: transport).send_to_all(**@payload)

    assert_equal({ sent: 0, failed: 2, disabled: 0 }, result)
    travel 1.second do
      refute_equal first_token, ApnsService.provider_token(@config), "the cached token was dropped"
    end
    assert_empty ApnsDevice.where.not(disabled_at: nil)
  end

  test "a wrong key refuses every phone, but the provider token is reset only once per batch" do
    transport = FakeTransport.new([ 403, { reason: "InvalidProviderToken" }.to_json ], [ 403, { reason: "InvalidProviderToken" }.to_json ])
    ApnsService.expects(:reset_provider_tokens!).once

    result = ApnsService.new(config: @config, transport: transport).send_to_all(**@payload)

    assert_equal 2, result[:failed]
  end

  test "custom messages are never collapsed into one another" do
    transport = FakeTransport.new
    ApnsService.new(config: @config, transport: transport)
      .send_to_all(title: "t", body: "b", data: { session_id: 1, notification_type: "custom_message" })

    assert transport.requests.none? { |r| r[:headers].key?("apns-collapse-id") }
  end

  test "the provider token is reused inside its lifetime and replaced after" do
    first = ApnsService.provider_token(@config)
    assert_equal first, ApnsService.provider_token(@config)
    travel 51.minutes do
      refute_equal first, ApnsService.provider_token(@config)
    end
  end
end
