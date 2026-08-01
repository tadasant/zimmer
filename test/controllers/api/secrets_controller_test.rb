require "test_helper"

class Api::SecretsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @valid_api_key = "test_api_key_12345"
    @headers = { "X-API-Key" => @valid_api_key }
    ENV["API_KEYS"] = @valid_api_key
  end

  teardown do
    ENV.delete("API_KEYS")
  end

  test "should return 401 without an API key" do
    get api_secrets_keys_path

    assert_response :unauthorized
    json_response = JSON.parse(response.body)
    assert_equal "Unauthorized", json_response["error"]
    refute json_response.key?("secrets"), "Unauthenticated response must not leak secret names"
  end

  test "should return 401 with an invalid API key" do
    get api_secrets_keys_path, headers: { "X-API-Key" => "wrong_key" }

    assert_response :unauthorized
    refute JSON.parse(response.body).key?("secrets")
  end

  test "should get keys" do
    get api_secrets_keys_path, headers: @headers
    assert_response :success
  end

  test "should return JSON with secrets array" do
    get api_secrets_keys_path, headers: @headers
    assert_response :success

    json_response = JSON.parse(response.body)
    assert json_response.key?("secrets"), "Response should contain 'secrets' field"
    assert json_response["secrets"].is_a?(Array), "Secrets should be an array"
  end

  test "should return correct Content-Type" do
    get api_secrets_keys_path, headers: @headers
    assert_response :success
    assert_equal "application/json; charset=utf-8", response.content_type
  end

  test "should return secrets with metadata from credentials" do
    get api_secrets_keys_path, headers: @headers
    assert_response :success

    json_response = JSON.parse(response.body)
    secrets = json_response["secrets"]

    # SecretsLoader reads from Rails credentials (config/credentials/{env}.yml.enc)
    # In test environment, we have credentials with TEST_API_KEY and TEST_SECRET
    if SecretsLoader.available?
      assert secrets.size > 0, "Should return secrets from credentials"
      # Verify structure of first secret
      first_secret = secrets.first
      assert first_secret.key?("name"), "Secret should have name field"
      assert first_secret.key?("description"), "Secret should have description field"
    else
      assert_equal [], secrets, "Should return empty array when no credentials available"
    end
  end
end
