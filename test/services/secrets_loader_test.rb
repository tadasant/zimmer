# frozen_string_literal: true

require "test_helper"

class SecretsLoaderTest < ActiveSupport::TestCase
  # Tests that require actual credentials (skipped in CI where test.key is unavailable)
  test "loads secrets from Rails credentials when available" do
    skip_unless_credentials_available

    secrets = SecretsLoader.all

    assert_equal "test_api_key_value", secrets["TEST_API_KEY"]
    assert_equal "test_secret_value", secrets["TEST_SECRET"]
  end

  test "loads secrets with metadata from Rails credentials" do
    skip_unless_credentials_available

    secrets = SecretsLoader.all_with_metadata

    assert_equal 2, secrets.size
    test_api_key = secrets.find { |s| s.name == "TEST_API_KEY" }
    assert_not_nil test_api_key
    assert_equal "test_api_key_value", test_api_key.value
    assert_equal "Test API key", test_api_key.description
  end

  test "get returns secret value" do
    skip_unless_credentials_available

    assert_equal "test_api_key_value", SecretsLoader.get("TEST_API_KEY")
  end

  test "get returns nil for non-existent secret" do
    skip_unless_credentials_available

    assert_nil SecretsLoader.get("NON_EXISTENT")
  end

  test "get! raises error for non-existent secret" do
    skip_unless_credentials_available

    error = assert_raises(SecretsLoader::SecretNotFoundError) do
      SecretsLoader.get!("NON_EXISTENT")
    end

    assert_match(/NON_EXISTENT/, error.message)
    assert_match(/credentials:edit/, error.message)
  end

  test "get_with_metadata returns secret object" do
    skip_unless_credentials_available

    secret = SecretsLoader.get_with_metadata("TEST_API_KEY")

    assert_not_nil secret
    assert_equal "TEST_API_KEY", secret.name
    assert_equal "test_api_key_value", secret.value
    assert_equal "Test API key", secret.description
  end

  test "get_with_metadata returns nil for non-existent secret" do
    skip_unless_credentials_available

    assert_nil SecretsLoader.get_with_metadata("NON_EXISTENT")
  end

  test "exists? returns true for existing secret" do
    skip_unless_credentials_available

    assert SecretsLoader.exists?("TEST_API_KEY")
  end

  test "exists? returns false for non-existent secret" do
    skip_unless_credentials_available

    refute SecretsLoader.exists?("NON_EXISTENT")
  end

  test "keys returns all secret keys" do
    skip_unless_credentials_available

    keys = SecretsLoader.keys

    assert_includes keys, "TEST_API_KEY"
    assert_includes keys, "TEST_SECRET"
    assert_equal 2, keys.size
  end

  test "available? returns true when credentials available" do
    skip_unless_credentials_available

    assert SecretsLoader.available?
  end

  test "template returns templated secret reference" do
    assert_equal "{{API_KEY}}", SecretsLoader.template("API_KEY")
  end

  test "all_templated returns all secrets as templates" do
    skip_unless_credentials_available

    templated = SecretsLoader.all_templated

    assert_equal "{{TEST_API_KEY}}", templated["TEST_API_KEY"]
    assert_equal "{{TEST_SECRET}}", templated["TEST_SECRET"]
  end

  # Tests that work without credentials (mocking credentials_available?)
  test "returns empty hash when credentials unavailable" do
    with_no_credentials do
      assert_equal({}, SecretsLoader.all)
    end
  end

  test "returns empty array when credentials unavailable for metadata" do
    with_no_credentials do
      assert_equal [], SecretsLoader.all_with_metadata
    end
  end

  test "available? returns false when credentials unavailable" do
    with_no_credentials do
      refute SecretsLoader.available?
    end
  end

  test "Secret#to_h returns hash representation" do
    secret = SecretsLoader::Secret.new(
      name: "TEST_KEY",
      value: "test_value",
      description: "A test secret"
    )

    hash = secret.to_h

    assert_equal "TEST_KEY", hash[:name]
    assert_equal "test_value", hash[:value]
    assert_equal "A test secret", hash[:description]
  end

  test "Secret#to_h handles nil description" do
    secret = SecretsLoader::Secret.new(
      name: "TEST_KEY",
      value: "test_value"
    )

    hash = secret.to_h

    assert_equal "TEST_KEY", hash[:name]
    assert_equal "test_value", hash[:value]
    assert_nil hash[:description]
  end

  private

  def skip_unless_credentials_available
    skip "Credentials key not available (CI environment)" unless credentials_available?
  end

  def credentials_available?
    Rails.application.credentials.mcp_secrets.present?
  rescue ActiveSupport::MessageEncryptor::InvalidMessage, NoMethodError
    false
  end

  def with_no_credentials(&block)
    # Stub the private credentials_available? method which gates load_secrets
    # and load_secrets_with_metadata. We must stub this (not just available?)
    # because the internal load methods call credentials_available? directly.
    original_method = SecretsLoader.singleton_class.instance_method(:credentials_available?)

    SecretsLoader.define_singleton_method(:credentials_available?) { false }

    yield
  ensure
    SecretsLoader.define_singleton_method(:credentials_available?, original_method)
  end
end
