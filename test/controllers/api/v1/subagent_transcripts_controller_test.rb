require "test_helper"

class Api::V1::SubagentTranscriptsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @valid_api_key = "test_api_key_12345"
    @headers = { "X-API-Key" => @valid_api_key }
    ENV["API_KEYS"] = @valid_api_key
    @session = sessions(:running)
    # Create a test transcript
    @transcript = @session.subagent_transcripts.create!(
      agent_id: "test-agent-001",
      tool_use_id: "tool-use-001",
      transcript: '{"type": "user", "message": "test"}',
      filename: "test_transcript.jsonl",
      message_count: 5,
      subagent_type: "explore",
      description: "Exploring codebase",
      status: "completed",
      duration_ms: 5000,
      total_tokens: 1500,
      tool_use_count: 3
    )
  end

  teardown do
    ENV.delete("API_KEYS")
  end

  # Authentication tests
  test "should return 401 without API key" do
    get api_v1_session_subagent_transcripts_path(@session)
    assert_response :unauthorized
  end

  test "should return 401 with invalid API key" do
    get api_v1_session_subagent_transcripts_path(@session), headers: { "X-API-Key" => "invalid" }
    assert_response :unauthorized
  end

  # Index tests
  test "should return list of transcripts for session" do
    get api_v1_session_subagent_transcripts_path(@session), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json.key?("subagent_transcripts")
    assert json.key?("pagination")
    assert json["subagent_transcripts"].is_a?(Array)
  end

  test "should return transcripts scoped to session" do
    get api_v1_session_subagent_transcripts_path(@session), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    json["subagent_transcripts"].each do |transcript|
      assert_equal @session.id, transcript["session_id"]
    end
  end

  test "should filter by status" do
    @session.subagent_transcripts.create!(
      agent_id: "running-agent",
      status: "running"
    )

    get api_v1_session_subagent_transcripts_path(@session), params: { status: "running" }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    json["subagent_transcripts"].each do |transcript|
      assert_equal "running", transcript["status"]
    end
  end

  test "should filter by subagent_type" do
    @session.subagent_transcripts.create!(
      agent_id: "plan-agent",
      subagent_type: "plan"
    )

    get api_v1_session_subagent_transcripts_path(@session), params: { subagent_type: "plan" }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    json["subagent_transcripts"].each do |transcript|
      assert_equal "plan", transcript["subagent_type"]
    end
  end

  test "should paginate transcripts" do
    get api_v1_session_subagent_transcripts_path(@session), params: { page: 1, per_page: 2 }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal 1, json["pagination"]["page"]
    assert_equal 2, json["pagination"]["per_page"]
  end

  test "should return 404 for nonexistent session" do
    get api_v1_session_subagent_transcripts_path(999999), headers: @headers
    assert_response :not_found
  end

  test "should find session by slug" do
    @session.update!(slug: "test-session-slug")
    get api_v1_session_subagent_transcripts_path("test-session-slug"), headers: @headers
    assert_response :success
  end

  # Show tests
  test "should return single transcript" do
    get api_v1_session_subagent_transcript_path(@session, @transcript), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal @transcript.id, json["subagent_transcript"]["id"]
    assert_equal @transcript.agent_id, json["subagent_transcript"]["agent_id"]
  end

  test "should exclude transcript content by default" do
    get api_v1_session_subagent_transcript_path(@session, @transcript), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_not json["subagent_transcript"].key?("transcript")
  end

  test "should include transcript content when requested" do
    get api_v1_session_subagent_transcript_path(@session, @transcript), params: { include_transcript: "true" }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json["subagent_transcript"].key?("transcript")
    assert_equal @transcript.transcript, json["subagent_transcript"]["transcript"]
  end

  test "should return 404 for transcript in different session" do
    other_session = sessions(:waiting)
    get api_v1_session_subagent_transcript_path(other_session, @transcript), headers: @headers
    assert_response :not_found
  end

  test "should return 404 for nonexistent transcript" do
    get api_v1_session_subagent_transcript_path(@session, 999999), headers: @headers
    assert_response :not_found
  end

  # Create tests
  test "should create transcript with valid params" do
    assert_difference("@session.subagent_transcripts.count", 1) do
      post api_v1_session_subagent_transcripts_path(@session), params: {
        agent_id: "new-agent-001",
        tool_use_id: "tool-001",
        subagent_type: "explore",
        description: "Test subagent",
        status: "running"
      }, headers: @headers
    end

    assert_response :created
    json = JSON.parse(response.body)
    assert_equal "new-agent-001", json["subagent_transcript"]["agent_id"]
    assert_equal @session.id, json["subagent_transcript"]["session_id"]
  end

  test "should create transcript with all fields" do
    post api_v1_session_subagent_transcripts_path(@session), params: {
      agent_id: "full-agent-001",
      tool_use_id: "tool-002",
      transcript: '{"type": "test"}',
      filename: "test.jsonl",
      message_count: 10,
      subagent_type: "plan",
      description: "Planning task",
      status: "completed",
      duration_ms: 3000,
      total_tokens: 2000,
      tool_use_count: 5
    }, headers: @headers

    assert_response :created
    json = JSON.parse(response.body)["subagent_transcript"]
    assert_equal "full-agent-001", json["agent_id"]
    assert_equal "tool-002", json["tool_use_id"]
    assert_equal "test.jsonl", json["filename"]
    assert_equal 10, json["message_count"]
    assert_equal "plan", json["subagent_type"]
    assert_equal "Planning task", json["description"]
    assert_equal "completed", json["status"]
    assert_equal 3000, json["duration_ms"]
    assert_equal 2000, json["total_tokens"]
    assert_equal 5, json["tool_use_count"]
  end

  test "should reject transcript without agent_id" do
    post api_v1_session_subagent_transcripts_path(@session), params: {
      status: "running"
    }, headers: @headers

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_includes json["messages"].join, "Agent"
  end

  test "should reject transcript with duplicate agent_id in same session" do
    post api_v1_session_subagent_transcripts_path(@session), params: {
      agent_id: @transcript.agent_id # Already exists
    }, headers: @headers

    assert_response :unprocessable_entity
  end

  test "should allow same agent_id in different sessions" do
    other_session = sessions(:waiting)
    post api_v1_session_subagent_transcripts_path(other_session), params: {
      agent_id: @transcript.agent_id
    }, headers: @headers

    assert_response :created
  end

  test "should reject transcript with invalid status" do
    post api_v1_session_subagent_transcripts_path(@session), params: {
      agent_id: "invalid-status-agent",
      status: "invalid_status"
    }, headers: @headers

    assert_response :unprocessable_entity
  end

  test "should accept all valid statuses" do
    %w[running completed failed].each_with_index do |status, index|
      post api_v1_session_subagent_transcripts_path(@session), params: {
        agent_id: "status-test-#{index}",
        status: status
      }, headers: @headers

      assert_response :created
      json = JSON.parse(response.body)
      assert_equal status, json["subagent_transcript"]["status"]
    end
  end

  # Update tests
  test "should update transcript status" do
    patch api_v1_session_subagent_transcript_path(@session, @transcript), params: {
      status: "failed"
    }, headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "failed", json["subagent_transcript"]["status"]
  end

  test "should update transcript metrics" do
    patch api_v1_session_subagent_transcript_path(@session, @transcript), params: {
      duration_ms: 10000,
      total_tokens: 5000,
      tool_use_count: 10
    }, headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal 10000, json["subagent_transcript"]["duration_ms"]
    assert_equal 5000, json["subagent_transcript"]["total_tokens"]
    assert_equal 10, json["subagent_transcript"]["tool_use_count"]
  end

  test "should update transcript content" do
    patch api_v1_session_subagent_transcript_path(@session, @transcript), params: {
      transcript: '{"type": "updated", "data": "new content"}'
    }, headers: @headers

    assert_response :success
    @transcript.reload
    assert_includes @transcript.transcript, "updated"
  end

  test "should not update transcript from different session" do
    other_session = sessions(:waiting)
    patch api_v1_session_subagent_transcript_path(other_session, @transcript), params: {
      status: "failed"
    }, headers: @headers

    assert_response :not_found
  end

  # Destroy tests
  test "should delete transcript" do
    assert_difference("SubagentTranscript.count", -1) do
      delete api_v1_session_subagent_transcript_path(@session, @transcript), headers: @headers
    end

    assert_response :no_content
  end

  test "should not delete transcript from different session" do
    other_session = sessions(:waiting)
    assert_no_difference("SubagentTranscript.count") do
      delete api_v1_session_subagent_transcript_path(other_session, @transcript), headers: @headers
    end

    assert_response :not_found
  end

  test "should return 404 when deleting nonexistent transcript" do
    delete api_v1_session_subagent_transcript_path(@session, 999999), headers: @headers
    assert_response :not_found
  end

  # Response format tests
  test "should return JSON with correct content type" do
    get api_v1_session_subagent_transcripts_path(@session), headers: @headers
    assert_response :success
    assert_equal "application/json; charset=utf-8", response.content_type
  end

  test "should return transcript with all expected fields" do
    get api_v1_session_subagent_transcript_path(@session, @transcript), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)["subagent_transcript"]
    expected_fields = %w[
      id session_id agent_id tool_use_id filename message_count
      subagent_type description status duration_ms total_tokens
      tool_use_count formatted_duration formatted_tokens display_label
      created_at updated_at
    ]

    expected_fields.each do |field|
      assert json.key?(field), "Expected field '#{field}' to be present"
    end
  end

  test "should return formatted fields" do
    get api_v1_session_subagent_transcript_path(@session, @transcript), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)["subagent_transcript"]
    assert_equal "5s", json["formatted_duration"]
    assert_equal "1.5k", json["formatted_tokens"]
    assert_equal "Exploring codebase", json["display_label"]
  end

  test "should return timestamps in ISO8601 format" do
    get api_v1_session_subagent_transcript_path(@session, @transcript), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)["subagent_transcript"]
    assert_nothing_raised { Time.iso8601(json["created_at"]) }
    assert_nothing_raised { Time.iso8601(json["updated_at"]) }
  end
end
