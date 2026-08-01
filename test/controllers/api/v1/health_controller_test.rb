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

    # The cooldown key is scoped per action *and* per caller now, so clear the
    # whole store rather than reconstructing the key here.
    Rails.cache.clear

    post archive_old_api_v1_health_path, params: { days: 999 }, headers: @headers
    assert_response :success
  end

  test "should rate limit archive old" do
    post archive_old_api_v1_health_path, headers: @headers
    assert_response :success

    post archive_old_api_v1_health_path, headers: @headers
    assert_response :too_many_requests
  end

  # === Per-caller scoping ===
  #
  # The cooldown used to be keyed on the action alone, so one client's cleanup
  # locked every other key holder out of maintenance for 30 seconds.

  test "the cooldown is scoped per API key, not global" do
    ENV["API_KEYS"] = "key_one,key_two"
    first = { "X-API-Key" => "key_one" }
    second = { "X-API-Key" => "key_two" }

    post cleanup_processes_api_v1_health_path, headers: first
    assert_response :success

    # The other key holder is unaffected by the first one's cooldown.
    post cleanup_processes_api_v1_health_path, headers: second
    assert_response :success

    # ...and each is still limited on its own behalf.
    post cleanup_processes_api_v1_health_path, headers: first
    assert_response :too_many_requests

    post cleanup_processes_api_v1_health_path, headers: second
    assert_response :too_many_requests
  end

  test "the cooldown is scoped per action as well as per caller" do
    post cleanup_processes_api_v1_health_path, headers: @headers
    assert_response :success

    post retry_sessions_api_v1_health_path, headers: @headers
    assert_response :success
  end

  test "the cache key carries a digest of the API key, never the key itself" do
    post cleanup_processes_api_v1_health_path, headers: @headers
    assert_response :success

    digest = Digest::SHA256.hexdigest(@valid_api_key)[0, 32]

    assert Rails.cache.read("health_api_rate_limit:cleanup_processes:#{digest}"),
      "expected the cooldown to be recorded under the digested key"
    assert_nil Rails.cache.read("health_api_rate_limit:cleanup_processes:#{@valid_api_key}"),
      "the raw API key must never appear in a cache key"
    assert_nil Rails.cache.read("health_api_rate_limit:cleanup_processes"),
      "the unscoped global key must no longer be written"
  end

  # === Fail closed under a null cache ===

  test "refuses mutating actions when the cache cannot enforce the cooldown" do
    Rails.cache = ActiveSupport::Cache::NullStore.new

    post cleanup_processes_api_v1_health_path, headers: @headers

    assert_response :service_unavailable
    json = JSON.parse(response.body)
    assert_equal "Rate limiting unavailable", json["error"]
    assert_match(/cooldown cannot be enforced/, json["message"])
  end

  test "a null cache does not block the read-only health report" do
    Rails.cache = ActiveSupport::Cache::NullStore.new

    get api_v1_health_path, headers: @headers

    assert_response :success
  end
end
