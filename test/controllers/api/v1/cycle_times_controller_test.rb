# frozen_string_literal: true

require "test_helper"

class Api::V1::CycleTimesControllerTest < ActionDispatch::IntegrationTest
  include CycleTimeFixtures

  setup do
    @api_key = "test_api_key_12345"
    @headers = { "X-API-Key" => @api_key }
    ENV["API_KEYS"] = @api_key
  end

  teardown { ENV.delete("API_KEYS") }

  test "index returns the window's aggregate and rows" do
    create_cycle_time_row(finished_at: 1.day.ago, totals: { "inference" => 100, "wait_ci" => 300 }, title: "A")

    get api_v1_cycle_times_path(days: 7), headers: @headers

    assert_response :success
    body = response.parsed_body
    assert_equal 1, body["eligible_hierarchies"]
    assert_equal "wait_ci", body["top_wait_categories"].first["category"]
    assert_equal "A", body["hierarchies"].first["title"]
  end

  test "show returns one hierarchy, and 404s for one with no row" do
    row = create_cycle_time_row(finished_at: 1.day.ago, totals: { "inference" => 100 })

    get api_v1_cycle_time_path(row.root_session_id, include_segments: true), headers: @headers
    assert_response :success
    assert_equal 1, response.parsed_body["sessions"].first["segments"].size

    get api_v1_cycle_time_path(0), headers: @headers
    assert_response :not_found
  end

  test "requires an API key" do
    get api_v1_cycle_times_path

    assert_response :unauthorized
  end
end
