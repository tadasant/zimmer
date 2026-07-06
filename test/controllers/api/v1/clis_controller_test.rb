require "test_helper"

class Api::V1::ClisControllerTest < ActionDispatch::IntegrationTest
  setup do
    @valid_api_key = "test_api_key_12345"
    @headers = { "X-API-Key" => @valid_api_key }
    ENV["API_KEYS"] = @valid_api_key
  end

  teardown do
    ENV.delete("API_KEYS")
  end

  # Authentication tests
  test "should return 401 without API key" do
    get api_v1_api_clis_status_path
    assert_response :unauthorized
  end

  test "should return 401 with invalid API key" do
    get api_v1_api_clis_status_path, headers: { "X-API-Key" => "invalid" }
    assert_response :unauthorized
  end

  # Status tests
  test "should return CLI status" do
    get api_v1_api_clis_status_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json.key?("cli_status")
    assert json.key?("unauthenticated_count")
  end

  test "should return JSON with correct content type" do
    get api_v1_api_clis_status_path, headers: @headers
    assert_equal "application/json; charset=utf-8", response.content_type
  end

  # Refresh tests
  test "should trigger CLI status refresh" do
    assert_enqueued_with(job: CliStatusRefreshJob) do
      post api_v1_api_clis_refresh_path, headers: @headers
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal true, json["queued"]
    assert json.key?("message")
  end

  # Clear cache tests
  test "should trigger cache clear" do
    assert_enqueued_with(job: CacheClearJob) do
      post api_v1_api_clis_clear_cache_path, headers: @headers
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal true, json["queued"]
    assert json.key?("message")
  end
end
