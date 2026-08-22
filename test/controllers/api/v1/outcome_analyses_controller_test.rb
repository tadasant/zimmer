# frozen_string_literal: true

require "test_helper"

class Api::V1::OutcomeAnalysesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @valid_api_key = "test_api_key_12345"
    @headers = { "X-API-Key" => @valid_api_key }
    ENV["API_KEYS"] = @valid_api_key
    @session = sessions(:archived)
  end

  teardown { ENV.delete("API_KEYS") }

  def tree(outcome: "Success", children: [])
    {
      id: "S0",
      trigger: { kind: "New", source: "user" },
      goal: { text: "Ship it", kind: "Action" },
      outcome: { kind: outcome, explanation: "It shipped." },
      meta: { event_range: nil, wall_clock_s: 120, tokens_in: 10, tokens_out: 5, model: "opus" },
      children: children
    }
  end

  def failed_child(id)
    { id: id, trigger: { kind: "New", source: "agent" }, goal: { text: "Try", kind: "Plan" },
      outcome: { kind: "Failure", explanation: "Nope." }, meta: {}, children: [] }
  end

  test "requires an API key" do
    post api_v1_outcome_analyses_path, params: { session_id: @session.id, root: tree }, as: :json
    assert_response :unauthorized
  end

  test "creates an analysis from the same payload the MCP tool takes" do
    post api_v1_outcome_analyses_path,
      params: { session_id: @session.id, schema_version: "1", root: tree(children: [ failed_child("S0.0") ]), notes: "n" },
      headers: @headers, as: :json

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "Success", body.dig("outcome_analysis", "root_outcome")
    assert_equal 2, body.dig("outcome_analysis", "segment_count")
    assert_equal 1, body.dig("outcome_analysis", "failure_segment_count")
    assert_equal "S0.0", body.dig("outcome_analysis", "root", "children", 0, "id")
    assert_equal false, body["superseded_previous"]
  end

  test "a second create supersedes the first" do
    post api_v1_outcome_analyses_path, params: { session_id: @session.id, root: tree }, headers: @headers, as: :json
    post api_v1_outcome_analyses_path, params: { session_id: @session.id, root: tree(outcome: "Failure") }, headers: @headers, as: :json

    assert_response :created
    assert_equal true, JSON.parse(response.body)["superseded_previous"]
    assert_equal 1, OutcomeAnalysis.current.where(session: @session).count
  end

  test "rejects a malformed tree with 422 and every reason" do
    post api_v1_outcome_analyses_path,
      params: { session_id: @session.id, root: tree.merge(id: "S1") }, headers: @headers, as: :json

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "Invalid Segment tree", body["error"]
    assert body["messages"].any? { |m| m.include?("S0") }
    assert_equal 0, OutcomeAnalysis.count
  end

  test "rejects a session that is not archived" do
    post api_v1_outcome_analyses_path, params: { session_id: sessions(:running).id, root: tree }, headers: @headers, as: :json

    assert_response :unprocessable_entity
    assert_equal "Unanalyzable session", JSON.parse(response.body)["error"]
  end

  test "404s an unknown session" do
    post api_v1_outcome_analyses_path, params: { session_id: 999_999_999, root: tree }, headers: @headers, as: :json

    assert_response :not_found
  end

  test "index lists current analyses without their trees" do
    post api_v1_outcome_analyses_path, params: { session_id: @session.id, root: tree }, headers: @headers, as: :json

    get api_v1_outcome_analyses_path, headers: @headers

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 1, body["pagination"]["total_count"]
    refute body["outcome_analyses"].first.key?("root")
  end

  test "index filters the same way the ledger does" do
    post api_v1_outcome_analyses_path, params: { session_id: @session.id, root: tree }, headers: @headers, as: :json

    get api_v1_outcome_analyses_path, params: { agent_runtime: "codex" }, headers: @headers
    assert_equal 0, JSON.parse(response.body)["pagination"]["total_count"]

    get api_v1_outcome_analyses_path, params: { agent_runtime: @session.agent_runtime }, headers: @headers
    assert_equal 1, JSON.parse(response.body)["pagination"]["total_count"]
  end

  test "show returns one analysis with its tree, keyed by the analyzed session" do
    post api_v1_outcome_analyses_path, params: { session_id: @session.id, root: tree(children: [ failed_child("S0.0") ]) }, headers: @headers, as: :json

    get api_v1_outcome_analysis_path(@session.id), headers: @headers

    assert_response :success
    body = JSON.parse(response.body)["outcome_analysis"]
    assert_equal "S0", body.dig("root", "id")
    assert_equal 1, body["failure_segment_count"]
  end

  test "show 404s when the session has never been analyzed" do
    get api_v1_outcome_analysis_path(@session.id), headers: @headers

    assert_response :not_found
  end
end
