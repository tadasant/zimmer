require "test_helper"

class Api::V1::LogsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @valid_api_key = "test_api_key_12345"
    @headers = { "X-API-Key" => @valid_api_key }
    ENV["API_KEYS"] = @valid_api_key
    @session = sessions(:running)
  end

  teardown do
    ENV.delete("API_KEYS")
  end

  # Authentication tests
  test "should return 401 without API key" do
    get api_v1_session_logs_path(@session)
    assert_response :unauthorized
  end

  test "should return 401 with invalid API key" do
    get api_v1_session_logs_path(@session), headers: { "X-API-Key" => "invalid" }
    assert_response :unauthorized
  end

  # Index tests
  test "should return list of logs for session" do
    get api_v1_session_logs_path(@session), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json.key?("logs")
    assert json.key?("pagination")
    assert json["logs"].is_a?(Array)
  end

  test "should return logs scoped to session" do
    other_session = sessions(:waiting)
    get api_v1_session_logs_path(other_session), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    json["logs"].each do |log|
      assert_equal other_session.id, log["session_id"]
    end
  end

  test "should filter logs by level" do
    get api_v1_session_logs_path(@session), params: { level: "error" }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    json["logs"].each do |log|
      assert_equal "error", log["level"]
    end
  end

  test "should paginate logs" do
    get api_v1_session_logs_path(@session), params: { page: 1, per_page: 2 }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal 1, json["pagination"]["page"]
    assert_equal 2, json["pagination"]["per_page"]
    assert json["logs"].length <= 2
  end

  test "should return 404 for nonexistent session" do
    get api_v1_session_logs_path(999999), headers: @headers
    assert_response :not_found
  end

  test "should find session by slug" do
    @session.update!(slug: "test-session-slug")
    get api_v1_session_logs_path("test-session-slug"), headers: @headers
    assert_response :success
  end

  # Show tests
  test "should return single log entry" do
    log = logs(:info_log)
    get api_v1_session_log_path(@session, log), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal log.id, json["log"]["id"]
    assert_equal log.content, json["log"]["content"]
    assert_equal log.level, json["log"]["level"]
  end

  test "should return 404 for log in different session" do
    other_session = sessions(:waiting)
    log = logs(:info_log) # belongs to :running session
    get api_v1_session_log_path(other_session, log), headers: @headers
    assert_response :not_found
  end

  test "should return 404 for nonexistent log" do
    get api_v1_session_log_path(@session, 999999), headers: @headers
    assert_response :not_found
  end

  # Create tests
  test "should create log with valid params" do
    assert_difference("@session.logs.count", 1) do
      post api_v1_session_logs_path(@session), params: {
        content: "Test log message",
        level: "info"
      }, headers: @headers
    end

    assert_response :created
    json = JSON.parse(response.body)
    assert_equal "Test log message", json["log"]["content"]
    assert_equal "info", json["log"]["level"]
    assert_equal @session.id, json["log"]["session_id"]
  end

  test "should reject log without level" do
    post api_v1_session_logs_path(@session), params: {
      content: "Test log message"
    }, headers: @headers

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_includes json["messages"].join, "valid log level"
  end

  test "should reject log without content" do
    post api_v1_session_logs_path(@session), params: {
      level: "info"
    }, headers: @headers

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_includes json["messages"].join, "Content"
  end

  test "should reject log with invalid level" do
    post api_v1_session_logs_path(@session), params: {
      content: "Test log message",
      level: "invalid_level"
    }, headers: @headers

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_includes json["messages"].join, "not a valid log level"
  end

  test "should create log with all valid levels" do
    %w[info error debug warning verbose].each do |level|
      post api_v1_session_logs_path(@session), params: {
        content: "Test #{level} message",
        level: level
      }, headers: @headers

      assert_response :created
      json = JSON.parse(response.body)
      assert_equal level, json["log"]["level"]
    end
  end

  # Update tests
  test "should update log content" do
    log = logs(:info_log)
    patch api_v1_session_log_path(@session, log), params: {
      content: "Updated content"
    }, headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "Updated content", json["log"]["content"]
  end

  test "should update log level" do
    log = logs(:info_log)
    patch api_v1_session_log_path(@session, log), params: {
      level: "warning"
    }, headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "warning", json["log"]["level"]
  end

  test "should reject invalid level on update" do
    log = logs(:info_log)
    patch api_v1_session_log_path(@session, log), params: {
      level: "invalid"
    }, headers: @headers

    assert_response :unprocessable_entity
  end

  test "should not update log from different session" do
    other_session = sessions(:waiting)
    log = logs(:info_log)
    patch api_v1_session_log_path(other_session, log), params: {
      content: "Hacked content"
    }, headers: @headers

    assert_response :not_found
  end

  # Destroy tests
  test "should delete log" do
    log = logs(:info_log)
    assert_difference("Log.count", -1) do
      delete api_v1_session_log_path(@session, log), headers: @headers
    end

    assert_response :no_content
  end

  test "should not delete log from different session" do
    other_session = sessions(:waiting)
    log = logs(:info_log)
    assert_no_difference("Log.count") do
      delete api_v1_session_log_path(other_session, log), headers: @headers
    end

    assert_response :not_found
  end

  test "should return 404 when deleting nonexistent log" do
    delete api_v1_session_log_path(@session, 999999), headers: @headers
    assert_response :not_found
  end

  # Response format tests
  test "should return JSON with correct content type" do
    get api_v1_session_logs_path(@session), headers: @headers
    assert_response :success
    assert_equal "application/json; charset=utf-8", response.content_type
  end

  test "should return log with all expected fields" do
    log = logs(:info_log)
    get api_v1_session_log_path(@session, log), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)["log"]
    expected_fields = %w[id session_id content level created_at updated_at]

    expected_fields.each do |field|
      assert json.key?(field), "Expected field '#{field}' to be present"
    end
  end

  test "should return timestamps in ISO8601 format" do
    log = logs(:info_log)
    get api_v1_session_log_path(@session, log), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)["log"]
    # Verify timestamps are valid ISO8601
    assert_nothing_raised { Time.iso8601(json["created_at"]) }
    assert_nothing_raised { Time.iso8601(json["updated_at"]) }
  end
end
