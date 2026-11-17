# frozen_string_literal: true

require "test_helper"

class Api::V1::OperatingCostsControllerTest < ActionDispatch::IntegrationTest
  include OperatingCostFixtures

  setup do
    @saved = ENV[ApiKey::ENV_VAR]
    ENV[ApiKey::ENV_VAR] = "operating-costs-test-key"
    @headers = { "X-API-Key" => "operating-costs-test-key" }
  end

  teardown { @saved.nil? ? ENV.delete(ApiKey::ENV_VAR) : ENV[ApiKey::ENV_VAR] = @saved }

  test "writes a batch, then reads it back as a report and as rows" do
    post "/api/v1/operating_costs/actions", params: { action: "record", payload: operating_cost_payload, collector: "agent:rest" },
                                            headers: @headers, as: :json
    assert_response :success
    assert_equal 6, response.parsed_body.dig("counts", "accounts", "created")

    get "/api/v1/operating_costs", params: { group_by: "vendor" }, headers: @headers
    assert_response :success
    assert_includes response.parsed_body["rows"].map { |r| r["label"] }, "ExampleCloud"

    get "/api/v1/operating_costs/records", params: { kind: "subscriptions" }, headers: @headers
    assert_response :success
    assert_equal 2, response.parsed_body["total"]
  end

  test "a bad read is a 400 and a bad write a 422" do
    get "/api/v1/operating_costs", params: { view: "nope" }, headers: @headers
    assert_response :bad_request

    post "/api/v1/operating_costs/actions", params: { action: "nope" }, headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert_match "Unknown action", response.parsed_body["message"]
  end

  test "refuses a request with no credentials" do
    get "/api/v1/operating_costs"
    assert_response :unauthorized
  end

  test "the token-spend REST path is unchanged" do
    get "/api/v1/costs", headers: @headers
    assert_response :success
    assert response.parsed_body.key?("ledger_coverage")
  end
end
