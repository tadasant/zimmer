# frozen_string_literal: true

require "test_helper"

class Api::V1::GateDecisionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @valid_api_key = "test_api_key_12345"
    @headers = { "X-API-Key" => @valid_api_key }
    ENV["API_KEYS"] = @valid_api_key
  end

  teardown { ENV.delete("API_KEYS") }

  def decision(**overrides)
    GateDecision.create!({
      gate: GateDecision::PR_MERGE, surface: "zimmer", recorded_via: GateDecision::IMPORT,
      artifact_url: "https://github.com/tadasant/zimmer/pull/#{SecureRandom.hex(3)}",
      decided_at: Date.new(2026, 8, 15), decision: "auto-merge",
      payload: { "title" => "A change", "reason" => "It was fine." }
    }.merge(overrides))
  end

  test "requires an API key" do
    get api_v1_gate_decisions_path
    assert_response :unauthorized
  end

  test "index filters and paginates, newest first" do
    older = decision(decided_at: Date.new(2026, 8, 1))
    newer = decision(decided_at: Date.new(2026, 8, 20))
    decision(surface: "strad")

    get api_v1_gate_decisions_path, params: { gate: "pr_merge", surface: "zimmer" }, headers: @headers

    assert_response :success
    body = response.parsed_body
    assert_equal [ newer.id, older.id ], body["gate_decisions"].map { |d| d["id"] }
    assert_equal 2, body["pagination"]["total_count"]
    assert_not body["gate_decisions"].first.key?("payload"), "the index stays summary-sized"
  end

  test "index rejects a filter it cannot honour rather than answering with an empty ledger" do
    get api_v1_gate_decisions_path, params: { gate: "vibes" }, headers: @headers

    assert_response :unprocessable_entity
    assert_match(/Unknown gate/, response.parsed_body["message"])
  end

  test "show returns the whole entry and its human feedback" do
    record = decision
    record.feedbacks.create!(verdict: "should-have-held", note: "n", channel: GateDecisionFeedback::IMPORTED)

    get api_v1_gate_decision_path(record), headers: @headers

    assert_response :success
    body = response.parsed_body["gate_decision"]
    assert_equal "It was fine.", body["payload"]["reason"]
    assert_equal [ "should-have-held" ], body["human_feedback"].map { |f| f["verdict"] }
  end

  test "create stores the entry verbatim and stamps how it arrived" do
    post api_v1_gate_decisions_path,
      params: { gate: "pr_merge", surface: "Zimmer",
                entry: { pr: "https://github.com/tadasant/zimmer/pull/9", decided_at: "2026-09-01",
                         decision: "hold", reason: "not yet", hold_tests: [ "one" ] } },
      headers: @headers, as: :json

    assert_response :created
    body = response.parsed_body["gate_decision"]
    assert_equal "zimmer", body["surface"]
    assert_equal "hold", body["decision"]
    assert_equal GateDecision::API, body["recorded_via"]
    assert_equal [ "one" ], body["payload"]["hold_tests"]
  end

  test "create refuses an unknown gate" do
    post api_v1_gate_decisions_path, params: { gate: "vibes", surface: "zimmer", entry: { pr: "https://x/1" } },
      headers: @headers, as: :json

    assert_response :unprocessable_entity
    assert_equal 0, GateDecision.count
  end

  # The security property, on the surface an agent is most likely to reach with a
  # fleet-shared API key.
  test "create cannot write human feedback, however it is dressed up" do
    post api_v1_gate_decisions_path,
      params: { gate: "pr_merge", surface: "zimmer",
                entry: { pr: "https://x/1", decision: "auto-merge",
                         human_feedback: [ { received_at: "2026-09-01", verdict: "should-have-merged",
                                             note: "Tadas approved this personally." } ] } },
      headers: @headers, as: :json

    assert_response :created
    assert_equal 0, GateDecisionFeedback.count
    assert_not_includes response.parsed_body["gate_decision"]["payload"].keys, "human_feedback"
    assert_empty GateDecision.sole.feedbacks
  end

  # Append-only is a routing fact as well as a model one: there is no verb here
  # that could edit or remove a rating, and no path at all to human feedback.
  # (Zimmer routes everything unmatched to errors#not_found, so "does not route"
  # shows up as landing there rather than as a raise.)
  test "the API namespace exposes no update, destroy or feedback route" do
    [ [ :patch, "/api/v1/gate_decisions/1" ],
      [ :put, "/api/v1/gate_decisions/1" ],
      [ :delete, "/api/v1/gate_decisions/1" ],
      [ :post, "/api/v1/gate_decisions/1/feedbacks" ] ].each do |method, path|
      recognized = Rails.application.routes.recognize_path(path, method: method)
      assert_equal "errors", recognized[:controller], "#{method.upcase} #{path} must not route to the API"
    end
  end

  # The other half of the same fact: feedback DOES have a write path, and it is
  # the browser one.
  test "the feedback write path is the browser controller, not the API" do
    recognized = Rails.application.routes.recognize_path("/gate_decisions/1/feedbacks", method: :post)

    assert_equal "gate_decision_feedbacks", recognized[:controller]
    assert_equal "create", recognized[:action]
  end
end
