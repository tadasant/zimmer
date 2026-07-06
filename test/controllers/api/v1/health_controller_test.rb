require "test_helper"

class Api::V1::HealthControllerTest < ActionDispatch::IntegrationTest
  setup do
    @valid_api_key = "test_api_key_12345"
    @headers = { "X-API-Key" => @valid_api_key }
    ENV["API_KEYS"] = @valid_api_key
    # Use memory store for rate limiting tests (test env uses null_store by default)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    ENV.delete("API_KEYS")
    Rails.cache = @original_cache
  end

  # Authentication tests
  test "should return 401 without API key" do
    get api_v1_health_path
    assert_response :unauthorized
  end

  test "should return 401 with invalid API key" do
    get api_v1_health_path, headers: { "X-API-Key" => "invalid" }
    assert_response :unauthorized
  end

  # Show tests
  test "should return health report" do
    get api_v1_health_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json.key?("health_report")
    assert json.key?("timestamp")
    assert json.key?("rails_env")
    assert json.key?("ruby_version")
  end

  test "should return JSON with correct content type" do
    get api_v1_health_path, headers: @headers
    assert_equal "application/json; charset=utf-8", response.content_type
  end

  # Cleanup processes tests
  test "should cleanup processes" do
    post cleanup_processes_api_v1_health_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json.key?("terminated") || json.key?("error")
  end

  test "should rate limit cleanup processes" do
    post cleanup_processes_api_v1_health_path, headers: @headers
    assert_response :success

    post cleanup_processes_api_v1_health_path, headers: @headers
    assert_response :too_many_requests

    json = JSON.parse(response.body)
    assert json.key?("retry_after")
  end

  # Retry sessions tests
  test "should retry sessions" do
    post retry_sessions_api_v1_health_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    # Response should have result data
    assert json.is_a?(Hash)
  end

  test "should retry specific sessions" do
    failed = sessions(:failed)
    post retry_sessions_api_v1_health_path, params: {
      session_ids: [ failed.id ]
    }, headers: @headers
    assert_response :success
  end

  test "should rate limit retry sessions" do
    post retry_sessions_api_v1_health_path, headers: @headers
    assert_response :success

    post retry_sessions_api_v1_health_path, headers: @headers
    assert_response :too_many_requests
  end

  # Archive old tests
  test "should archive old sessions" do
    post archive_old_api_v1_health_path, params: { days: 30 }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json.is_a?(Hash)
  end

  test "should use default days when not specified" do
    post archive_old_api_v1_health_path, headers: @headers
    assert_response :success
  end

  test "should clamp days to valid range" do
    # Should not error even with extreme values
    post archive_old_api_v1_health_path, params: { days: 0 }, headers: @headers
    assert_response :success

    Rails.cache.delete("health_api_rate_limit:archive_old")

    post archive_old_api_v1_health_path, params: { days: 999 }, headers: @headers
    assert_response :success
  end

  test "should rate limit archive old" do
    post archive_old_api_v1_health_path, headers: @headers
    assert_response :success

    post archive_old_api_v1_health_path, headers: @headers
    assert_response :too_many_requests
  end
end
