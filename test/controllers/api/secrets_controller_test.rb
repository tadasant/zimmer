require "test_helper"

class Api::SecretsControllerTest < ActionDispatch::IntegrationTest
  test "should get keys" do
    get api_secrets_keys_path
    assert_response :success
  end

  test "should return JSON with secrets array" do
    get api_secrets_keys_path
    assert_response :success

    json_response = JSON.parse(response.body)
    assert json_response.key?("secrets"), "Response should contain 'secrets' field"
    assert json_response["secrets"].is_a?(Array), "Secrets should be an array"
  end

  test "should return correct Content-Type" do
    get api_secrets_keys_path
    assert_response :success
    assert_equal "application/json; charset=utf-8", response.content_type
  end

  test "should return secrets with metadata from credentials" do
    get api_secrets_keys_path
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
