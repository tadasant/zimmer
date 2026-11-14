# frozen_string_literal: true

require "test_helper"

class Api::V1::LiveCostsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @saved = ENV[ApiKey::ENV_VAR]
    ENV[ApiKey::ENV_VAR] = "live-costs-test-key"
    @headers = { "X-API-Key" => "live-costs-test-key" }
  end

  teardown { @saved.nil? ? ENV.delete(ApiKey::ENV_VAR) : ENV[ApiKey::ENV_VAR] = @saved }

  test "reads the rollup and the rows on an API key" do
    LiveUsageEvent.record!(engine: "gpt_live_claude", operation: "voice_session", vendor: "openai_live", model: "gpt-live-1", seconds: 60)

    get "/api/v1/live/costs", params: { days: 3 }, headers: @headers
    assert_response :success
    assert_in_delta 0.05, response.parsed_body.dig("totals", "cost_usd"), 0.000001
    assert_equal "gpt_live_claude", response.parsed_body["by_engine"].sole["engine"]

    get "/api/v1/live/usage_events", params: { engine: "gpt_live_claude" }, headers: @headers
    assert_response :success
    assert_equal "gpt-live-1", response.parsed_body["events"].sole["model"]

    get "/api/v1/live/costs", params: { engine: "nope" }, headers: @headers
    assert_response :bad_request
  end

  test "refuses a request with no credentials" do
    get "/api/v1/live/costs"
    assert_response :unauthorized
  end
end
