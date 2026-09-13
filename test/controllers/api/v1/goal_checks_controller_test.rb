# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class Api::V1::GoalChecksControllerTest < ActionDispatch::IntegrationTest
  PR = "https://github.com/owner/repo/pull/3".freeze

  setup do
    @valid_api_key = "test_api_key_12345"
    @headers = { "X-API-Key" => @valid_api_key }
    ENV["API_KEYS"] = @valid_api_key
    Session.delete_all
    Session.create!(
      title: "Holding a PR", agent_runtime: "claude_code", status: :needs_input, prompt: "p",
      goal: "open-reviewed-green-pr", git_root: "https://github.com/owner/repo.git", branch: "main",
      metadata: { "agent_root_key" => "zimmer" },
      custom_metadata: {
        "github_pull_request_urls" => [ PR ],
        "github_pull_request_statuses" => { PR => "open" },
        "github_pull_request_ci_statuses" => { PR => "pass" },
        "github_pull_request_goal_facts" => {
          PR => { "verification_section" => true, "verification_checked_boxes" => 2, "unchecked_boxes" => 0, "labels" => [] }
        }
      }
    )
  end

  teardown { ENV.delete("API_KEYS") }

  test "returns the tally for sessions at rest, echoing the filters it applied" do
    get api_v1_goal_checks_path, params: { agent_root: "zimmer" }, headers: @headers

    assert_response :success
    body = response.parsed_body
    assert_equal "zimmer", body.dig("filters", "agent_root")
    assert_equal 1, body["checked_sessions"]
    assert_equal({ "met" => 0, "unmet" => 1, "pending" => 0 }, body["verdicts"])
    assert_equal [ "ready_to_merge_label" ], body.dig("unmet_on_own_pull_request", "listed", 0, "unmet_criteria")
  end

  test "a window that excludes the session counts nothing" do
    get api_v1_goal_checks_path, params: { from: "2020-01-01", to: "2020-01-31" }, headers: @headers

    assert_response :success
    assert_equal 0, response.parsed_body["checked_sessions"]
  end

  test "requires an API key" do
    get api_v1_goal_checks_path

    assert_response :unauthorized
  end
end
