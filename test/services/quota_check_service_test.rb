# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class QuotaCheckServiceTest < ActiveSupport::TestCase
  setup do
    @service = QuotaCheckService.new
    @credentials = {
      "claudeAiOauth" => {
        "accessToken" => "sk-ant-oat01-test-token",
        "subscriptionType" => "max",
        "rateLimitTier" => "default_claude_max_20x"
      }
    }
    @profile_response_body = {
      "account" => { "email" => "test@example.com" },
      "organization" => {
        "organization_type" => "claude_max",
        "rate_limit_tier" => "default_claude_max_20x"
      }
    }.to_json
  end

  test "returns error when credentials file does not exist" do
    File.stubs(:exist?).with(QuotaCheckService::CREDENTIALS_PATH).returns(false)

    result = @service.check

    assert_not result.success?
    assert_match(/No credentials file found/, result.error_message)
  end

  test "returns error when credentials file has no claudeAiOauth key" do
    File.stubs(:exist?).with(QuotaCheckService::CREDENTIALS_PATH).returns(true)
    File.stubs(:read).with(QuotaCheckService::CREDENTIALS_PATH).returns('{"other": "data"}')

    result = @service.check

    assert_not result.success?
    assert_match(/No Claude AI OAuth credentials/, result.error_message)
  end

  test "returns error when credentials file is invalid JSON" do
    File.stubs(:exist?).with(QuotaCheckService::CREDENTIALS_PATH).returns(true)
    File.stubs(:read).with(QuotaCheckService::CREDENTIALS_PATH).returns("not json")

    result = @service.check

    assert_not result.success?
    assert_match(/Failed to parse credentials/, result.error_message)
  end

  test "returns error when access token is missing" do
    creds = { "claudeAiOauth" => { "subscriptionType" => "max" } }
    File.stubs(:exist?).with(QuotaCheckService::CREDENTIALS_PATH).returns(true)
    File.stubs(:read).with(QuotaCheckService::CREDENTIALS_PATH).returns(creds.to_json)

    result = @service.check

    assert_not result.success?
    assert_match(/No access token found/, result.error_message)
  end

  test "returns error on network timeout" do
    stub_credentials

    Net::HTTP.any_instance.stubs(:request).raises(Net::ReadTimeout.new("read timeout"))

    result = @service.check

    assert_not result.success?
    assert_match(/timed out/, result.error_message)
  end

  test "returns error on connection refused" do
    stub_credentials

    Net::HTTP.any_instance.stubs(:request).raises(Errno::ECONNREFUSED.new("connection refused"))

    result = @service.check

    assert_not result.success?
    assert_match(/Cannot reach Anthropic API/, result.error_message)
  end

  test "returns error when response has no rate limit headers" do
    stub_credentials

    profile_resp = stub_http_response(200, body: @profile_response_body)
    quota_resp = stub_http_response(200, headers: {})

    Net::HTTP.any_instance.stubs(:request)
      .with { |req| req.path.include?("oauth/profile") }.returns(profile_resp)
    Net::HTTP.any_instance.stubs(:request)
      .with { |req| req.path.include?("messages") }.returns(quota_resp)

    result = @service.check

    assert_not result.success?
    assert_match(/No rate-limit headers/, result.error_message)
  end

  test "parses rate limit headers on successful response" do
    stub_credentials

    profile_resp = stub_http_response(200, body: @profile_response_body)

    headers = {
      "anthropic-ratelimit-unified-5h-utilization" => "0.42",
      "anthropic-ratelimit-unified-7d-utilization" => "0.15",
      "anthropic-ratelimit-unified-5h-status" => "allowed",
      "anthropic-ratelimit-unified-7d-status" => "allowed",
      "anthropic-ratelimit-unified-5h-reset" => "1712200000",
      "anthropic-ratelimit-unified-7d-reset" => "1712700000",
      "anthropic-ratelimit-unified-overage-status" => "enabled",
      "anthropic-ratelimit-unified-overage-disabled-reason" => nil
    }
    quota_resp = stub_http_response(200, headers: headers)

    Net::HTTP.any_instance.stubs(:request)
      .with { |req| req.path.include?("oauth/profile") }.returns(profile_resp)
    Net::HTTP.any_instance.stubs(:request)
      .with { |req| req.path.include?("messages") }.returns(quota_resp)

    result = @service.check

    assert result.success?
    assert_in_delta 0.42, result.utilization_5h
    assert_in_delta 0.15, result.utilization_7d
    assert_equal "allowed", result.status_5h
    assert_equal "allowed", result.status_7d
    assert_equal Time.at(1712200000), result.reset_5h
    assert_equal Time.at(1712700000), result.reset_7d
    assert_equal "enabled", result.overage_status
    assert_equal "claude_max", result.subscription_type
    assert_equal "default_claude_max_20x", result.rate_limit_tier
    assert_equal "test@example.com", result.email
  end

  test "handles profile API failure gracefully" do
    stub_credentials

    profile_resp = stub_http_response(401, body: '{"error":"unauthorized"}')

    headers = {
      "anthropic-ratelimit-unified-5h-utilization" => "0.1",
      "anthropic-ratelimit-unified-7d-utilization" => "0.05"
    }
    quota_resp = stub_http_response(200, headers: headers)

    Net::HTTP.any_instance.stubs(:request)
      .with { |req| req.path.include?("oauth/profile") }.returns(profile_resp)
    Net::HTTP.any_instance.stubs(:request)
      .with { |req| req.path.include?("messages") }.returns(quota_resp)

    result = @service.check

    assert result.success?
    assert_nil result.email
    assert_nil result.subscription_type
  end

  # check_with_token tests

  test "check_with_token returns error for blank token" do
    result = QuotaCheckService.check_with_token("")
    assert_not result.success?
    assert_match(/blank/, result.error_message)
  end

  test "check_with_token returns error for nil token" do
    result = QuotaCheckService.check_with_token(nil)
    assert_not result.success?
    assert_match(/blank/, result.error_message)
  end

  test "check_with_token succeeds with valid token" do
    profile_resp = stub_http_response(200, body: @profile_response_body)

    headers = {
      "anthropic-ratelimit-unified-5h-utilization" => "0.30",
      "anthropic-ratelimit-unified-7d-utilization" => "0.10",
      "anthropic-ratelimit-unified-5h-status" => "allowed",
      "anthropic-ratelimit-unified-7d-status" => "allowed",
      "anthropic-ratelimit-unified-5h-reset" => "1712200000",
      "anthropic-ratelimit-unified-7d-reset" => "1712700000"
    }
    quota_resp = stub_http_response(200, headers: headers)

    Net::HTTP.any_instance.stubs(:request)
      .with { |req| req.path.include?("oauth/profile") }.returns(profile_resp)
    Net::HTTP.any_instance.stubs(:request)
      .with { |req| req.path.include?("messages") }.returns(quota_resp)

    result = QuotaCheckService.check_with_token("sk-ant-oat01-test-token")

    assert result.success?
    assert_in_delta 0.30, result.utilization_5h
    assert_in_delta 0.10, result.utilization_7d
    assert_equal "test@example.com", result.email
  end

  test "check_with_token handles API failure gracefully" do
    profile_resp = stub_http_response(200, body: @profile_response_body)

    Net::HTTP.any_instance.stubs(:request)
      .with { |req| req.path.include?("oauth/profile") }.returns(profile_resp)
    Net::HTTP.any_instance.stubs(:request)
      .with { |req| req.path.include?("messages") }.raises(Net::ReadTimeout.new("timeout"))

    result = QuotaCheckService.check_with_token("sk-ant-oat01-test-token")

    assert_not result.success?
    assert_match(/timed out/, result.error_message)
  end

  test "quota request authenticates OAuth token via Bearer + oauth beta header, not x-api-key" do
    profile_resp = stub_http_response(200, body: @profile_response_body)
    headers = {
      "anthropic-ratelimit-unified-5h-utilization" => "0.30",
      "anthropic-ratelimit-unified-7d-utilization" => "0.10"
    }
    quota_resp = stub_http_response(200, headers: headers)

    profile_req = nil
    Net::HTTP.any_instance.stubs(:request)
      .with { |req| req.path.include?("oauth/profile") ? (profile_req = req; true) : false }
      .returns(profile_resp)

    quota_req = nil
    Net::HTTP.any_instance.stubs(:request)
      .with { |req| req.path.include?("messages") ? (quota_req = req; true) : false }
      .returns(quota_resp)

    result = QuotaCheckService.check_with_token("sk-ant-oat01-test-token")

    assert result.success?

    # Both OAuth requests must use Bearer + the beta opt-in header, never x-api-key.
    assert_equal "Bearer sk-ant-oat01-test-token", quota_req["authorization"]
    assert_equal QuotaCheckService::OAUTH_BETA, quota_req["anthropic-beta"]
    assert_nil quota_req["x-api-key"]

    assert_equal "Bearer sk-ant-oat01-test-token", profile_req["authorization"]
    assert_equal QuotaCheckService::OAUTH_BETA, profile_req["anthropic-beta"]
    assert_nil profile_req["x-api-key"]
  end

  # base_url tests

  test "base_url returns ANTHROPIC_BASE_URL when set" do
    original = ENV["ANTHROPIC_BASE_URL"]
    ENV["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:9999"

    result = @service.send(:base_url)
    assert_equal "http://127.0.0.1:9999", result
  ensure
    if original
      ENV["ANTHROPIC_BASE_URL"] = original
    else
      ENV.delete("ANTHROPIC_BASE_URL")
    end
  end

  test "base_url returns default when ANTHROPIC_BASE_URL is not set" do
    original = ENV["ANTHROPIC_BASE_URL"]
    ENV.delete("ANTHROPIC_BASE_URL")

    result = @service.send(:base_url)
    assert_equal "https://api.anthropic.com", result
  ensure
    ENV["ANTHROPIC_BASE_URL"] = original if original
  end

  test "check_with_token uses custom base_url for API requests" do
    original = ENV["ANTHROPIC_BASE_URL"]
    ENV["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:4567"

    profile_resp = stub_http_response(200, body: @profile_response_body)
    headers = {
      "anthropic-ratelimit-unified-5h-utilization" => "0.50",
      "anthropic-ratelimit-unified-7d-utilization" => "0.20"
    }
    quota_resp = stub_http_response(200, headers: headers)

    Net::HTTP.any_instance.stubs(:request).returns(profile_resp).then.returns(quota_resp)

    result = QuotaCheckService.check_with_token("test-token")
    assert result.success?
    assert_in_delta 0.50, result.utilization_5h
  ensure
    if original
      ENV["ANTHROPIC_BASE_URL"] = original
    else
      ENV.delete("ANTHROPIC_BASE_URL")
    end
  end

  private

  def stub_credentials
    File.stubs(:exist?).with(QuotaCheckService::CREDENTIALS_PATH).returns(true)
    File.stubs(:read).with(QuotaCheckService::CREDENTIALS_PATH).returns(@credentials.to_json)
  end

  def stub_http_response(code, body: nil, headers: nil)
    response = stub("response-#{code}")
    response.stubs(:code).returns(code.to_s)
    response.stubs(:body).returns(body || "")
    if headers
      response.stubs(:[]).with(anything).returns(nil)
      headers.each do |key, value|
        response.stubs(:[]).with(key).returns(value)
      end
    end
    response
  end
end
