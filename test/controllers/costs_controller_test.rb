# frozen_string_literal: true

require "test_helper"

class CostsControllerTest < ActionDispatch::IntegrationTest
  def usage(**overrides)
    SessionTokenUsage.create!({
      request_id: "req_#{SecureRandom.hex(6)}",
      model: "claude-opus-5",
      agent_root: "zimmer",
      called_at: 2.hours.ago,
      input_tokens: 100,
      output_tokens: 200,
      cache_read_tokens: 10_000,
      cache_creation_tokens: 5_000,
      cache_creation_1h_tokens: 5_000
    }.merge(overrides))
  end

  test "renders the empty state before anything has been ingested" do
    get costs_path

    assert_response :success
    assert_match "No usage recorded", response.body
    assert_match "token_usage:backfill", response.body, "the empty state should say how to load history"
  end

  test "renders totals and breakdowns once usage exists" do
    usage
    usage(model: "claude-haiku-4-5", agent_root: "zimmer-router")
    AdhocTokenUsage.create!(
      request_id: "req_adhoc", source: "cli_status_probe", model: "claude-opus-5",
      called_at: 1.hour.ago, input_tokens: 5, output_tokens: 10, cache_read_tokens: 20_000
    )

    get costs_path

    assert_response :success
    assert_match "Where the money goes", response.body
    assert_match "By agent root", response.body
    assert_match "zimmer-router", response.body
    assert_match "cli_status_probe", response.body
  end

  test "the window is selectable and bounded" do
    usage(called_at: 40.days.ago)

    get costs_path(days: 7)
    assert_response :success
    assert_match "No usage recorded", response.body, "a 40-day-old call is outside a 7-day window"

    get costs_path(days: 90)
    assert_response :success
    assert_no_match "No usage recorded", response.body
  end

  test "an absurd window is clamped rather than handed to the database" do
    get costs_path(days: 100_000)

    assert_response :success
    assert_equal CostsController::MAX_DAYS, @controller.instance_variable_get(:@days)
  end

  test "a non-numeric window falls back to the default" do
    get costs_path(days: "banana")

    assert_response :success
    assert_equal CostsController::DEFAULT_DAYS, @controller.instance_variable_get(:@days)
  end

  test "warns about models it has no price for rather than counting them as free" do
    usage(model: "claude-something-unreleased")

    get costs_path

    assert_response :success
    assert_match "Unpriced models", response.body
    assert_match "claude-something-unreleased", response.body
  end

  test "Costs is reachable from the sessions nav" do
    get root_path

    assert_response :success
    assert_select "a[href=?]", costs_path
  end
end
