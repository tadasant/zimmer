# frozen_string_literal: true

require "test_helper"

class Api::V1::CostsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @valid_api_key = "test_api_key_12345"
    @headers = { "X-API-Key" => @valid_api_key }
    ENV["API_KEYS"] = @valid_api_key
    @session = sessions(:running)
  end

  teardown do
    ENV.delete("API_KEYS")
  end

  def usage(**overrides)
    SessionTokenUsage.create!({
      request_id: "req_#{SecureRandom.hex(6)}",
      model: "claude-opus-5",
      agent_root: "zimmer",
      session_id: @session.id,
      called_at: 2.hours.ago,
      input_tokens: 100,
      output_tokens: 200,
      cache_read_tokens: 10_000,
      cache_creation_tokens: 5_000,
      cache_creation_1h_tokens: 5_000
    }.merge(overrides))
  end

  test "requires an api key" do
    get "/api/v1/costs"

    assert_response :unauthorized
  end

  test "returns rollups with the rate table that produced them" do
    usage
    usage(agent_root: "zimmer-router", model: "claude-sonnet-5")

    get "/api/v1/costs", headers: @headers

    assert_response :success
    body = JSON.parse(response.body)

    assert_equal 2, body.dig("totals", "api_calls")
    assert_operator body.dig("totals", "cost_usd"), :>, 0
    assert_includes body.keys, "cost_breakdown"
    assert_equal %w[zimmer zimmer-router].sort, body["by_agent_root"].map { |r| r["agent_root"] }.sort

    # A dollar figure without its rate table is not reproducible, so the rates
    # travel with the response.
    assert_equal 2.0, body.dig("pricing", "cache_multipliers", "write_1h")
    assert_equal 5.0, body.dig("pricing", "per_mtok", "opus", "input")
  end

  test "honours an explicit window" do
    usage(called_at: 40.days.ago)

    get "/api/v1/costs", params: { days: 7 }, headers: @headers
    assert_equal 0, JSON.parse(response.body).dig("totals", "api_calls")

    get "/api/v1/costs", params: { days: 90 }, headers: @headers
    assert_equal 1, JSON.parse(response.body).dig("totals", "api_calls")
  end

  test "records returns rows with a per-row priced cost" do
    usage

    get "/api/v1/costs/records", headers: @headers

    assert_response :success
    body = JSON.parse(response.body)
    row = body["records"].first

    assert_equal "session", body["kind"]
    assert_equal @session.id, row["session_id"]
    assert_equal 15_300, row["total_tokens"]
    assert_operator row["cost_usd"], :>, 0
    assert row["priced"]
    assert_equal 5_000, row["cache_creation_1h_tokens"]
  end

  test "records can filter by session, root and thread kind" do
    usage
    usage(agent_root: "other", session_id: nil)
    usage(subagent: true)

    get "/api/v1/costs/records", params: { agent_root: "zimmer" }, headers: @headers
    assert_equal 2, JSON.parse(response.body)["records"].size

    get "/api/v1/costs/records", params: { session_id: @session.id }, headers: @headers
    assert_equal 2, JSON.parse(response.body)["records"].size

    get "/api/v1/costs/records", params: { subagent: "true" }, headers: @headers
    assert_equal 1, JSON.parse(response.body)["records"].size
  end

  test "records serves the ad hoc table on request" do
    AdhocTokenUsage.create!(
      request_id: "req_adhoc", source: "cli_status_probe", model: "claude-opus-5",
      called_at: 1.hour.ago, input_tokens: 5, output_tokens: 10, cache_read_tokens: 100
    )

    get "/api/v1/costs/records", params: { kind: "adhoc" }, headers: @headers

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "adhoc", body["kind"]
    assert_equal "cli_status_probe", body["records"].first["source"]
  end

  test "reports models it cannot price instead of counting them as free" do
    usage(model: "claude-not-a-real-model")

    get "/api/v1/costs", headers: @headers

    assert_equal [ "claude-not-a-real-model" ], JSON.parse(response.body)["unpriced_models"]
  end
end
