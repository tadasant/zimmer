# frozen_string_literal: true

require "test_helper"

class PreregisteredOauthConfigTest < ActiveSupport::TestCase
  def setup
    PreregisteredOauthConfig.reload!
  end

  def teardown
    PreregisteredOauthConfig.reload!
  end

  # Unit tests for OAuthClient class
  test "OAuthClient#to_h returns hash representation" do
    client = PreregisteredOauthConfig::OAuthClient.new(
      key: "bigquery",
      client_id: "test-client-id",
      client_secret: "test-client-secret",
      authorization_endpoint: "https://accounts.google.com/o/oauth2/v2/auth",
      token_endpoint: "https://oauth2.googleapis.com/token",
      scopes: "https://www.googleapis.com/auth/bigquery"
    )

    hash = client.to_h

    assert_equal "bigquery", hash[:key]
    assert_equal "test-client-id", hash[:client_id]
    assert_equal "test-client-secret", hash[:client_secret]
    assert_equal "https://accounts.google.com/o/oauth2/v2/auth", hash[:authorization_endpoint]
    assert_equal "https://oauth2.googleapis.com/token", hash[:token_endpoint]
    assert_equal "https://www.googleapis.com/auth/bigquery", hash[:scopes]
  end

  test "OAuthClient#to_h handles nil scopes" do
    client = PreregisteredOauthConfig::OAuthClient.new(
      key: "test",
      client_id: "test-client-id",
      client_secret: "test-client-secret",
      authorization_endpoint: "https://example.com/auth",
      token_endpoint: "https://example.com/token"
    )

    hash = client.to_h

    assert_nil hash[:scopes]
  end

  test "OAuthClient#to_public_h returns hash without client_secret" do
    client = PreregisteredOauthConfig::OAuthClient.new(
      key: "bigquery",
      client_id: "test-client-id",
      client_secret: "test-client-secret",
      authorization_endpoint: "https://accounts.google.com/o/oauth2/v2/auth",
      token_endpoint: "https://oauth2.googleapis.com/token",
      scopes: "https://www.googleapis.com/auth/bigquery"
    )

    hash = client.to_public_h

    assert_equal "bigquery", hash[:key]
    assert_equal "test-client-id", hash[:client_id]
    assert_nil hash[:client_secret]
    refute hash.key?(:client_secret)
    assert_equal "https://accounts.google.com/o/oauth2/v2/auth", hash[:authorization_endpoint]
    assert_equal "https://oauth2.googleapis.com/token", hash[:token_endpoint]
    assert_equal "https://www.googleapis.com/auth/bigquery", hash[:scopes]
  end

  # Tests that require actual credentials (skipped in CI where test.key is unavailable)
  test "find_for_server returns client for exact match" do
    skip_unless_oauth_credentials_available

    # This test uses actual credentials, expecting 'bigquery-pulsemcp' key to exist
    client = PreregisteredOauthConfig.find_for_server("bigquery-pulsemcp")

    assert_not_nil client
    assert_equal "bigquery-pulsemcp", client.key
    assert_not_nil client.client_id
    assert_not_nil client.client_secret
    assert_not_nil client.authorization_endpoint
    assert_not_nil client.token_endpoint
  end

  test "find_for_server returns nil for non-matching server" do
    skip_unless_oauth_credentials_available

    # bigquery-foo should NOT match 'bigquery-pulsemcp' - only exact matches are supported
    client = PreregisteredOauthConfig.find_for_server("bigquery-foo")

    assert_nil client
  end

  test "find_for_server uses endpoints from credentials" do
    skip_unless_oauth_credentials_available

    client = PreregisteredOauthConfig.find_for_server("bigquery-pulsemcp")

    assert_not_nil client
    assert_equal "https://accounts.google.com/o/oauth2/v2/auth", client.authorization_endpoint
    assert_equal "https://oauth2.googleapis.com/token", client.token_endpoint
    assert_equal "https://www.googleapis.com/auth/bigquery", client.scopes
  end

  test "exists_for_server? returns true for matching server" do
    skip_unless_oauth_credentials_available

    assert PreregisteredOauthConfig.exists_for_server?("bigquery-pulsemcp")
  end

  test "exists_for_server? returns false for non-matching server" do
    skip_unless_oauth_credentials_available

    refute PreregisteredOauthConfig.exists_for_server?("unknown-server")
    refute PreregisteredOauthConfig.exists_for_server?("github")
  end

  test "all returns list of configured OAuth clients" do
    skip_unless_oauth_credentials_available

    clients = PreregisteredOauthConfig.all

    assert_kind_of Array, clients
    assert clients.any?
    assert clients.all? { |c| c.is_a?(PreregisteredOauthConfig::OAuthClient) }
  end

  # Tests that work without credentials
  test "find_for_server returns nil for nil server name" do
    assert_nil PreregisteredOauthConfig.find_for_server(nil)
  end

  test "find_for_server returns nil for empty server name" do
    assert_nil PreregisteredOauthConfig.find_for_server("")
  end

  test "exists_for_server? returns false for nil server name" do
    refute PreregisteredOauthConfig.exists_for_server?(nil)
  end

  test "exists_for_server? returns false for empty server name" do
    refute PreregisteredOauthConfig.exists_for_server?("")
  end

  test "all returns empty array when credentials unavailable" do
    with_no_oauth_credentials do
      assert_equal [], PreregisteredOauthConfig.all
    end
  end

  test "find_for_server returns nil when credentials unavailable" do
    with_no_oauth_credentials do
      assert_nil PreregisteredOauthConfig.find_for_server("bigquery-pulsemcp")
    end
  end

  test "find_for_server returns nil for unknown provider without endpoints" do
    # Test that a provider with credentials but no known endpoints returns nil
    with_custom_oauth_credentials(unknown_provider: { client_id: "test-id", client_secret: "test-secret" }) do
      # unknown_provider has no explicit endpoints in credentials
      # so it should return nil due to missing required endpoints
      client = PreregisteredOauthConfig.find_for_server("unknown_provider")
      assert_nil client
    end
  end

  test "find_for_server returns client for unknown provider with explicit endpoints" do
    # Test that a provider with credentials AND explicit endpoints works
    config = {
      unknown_provider: {
        client_id: "test-id",
        client_secret: "test-secret",
        authorization_endpoint: "https://example.com/auth",
        token_endpoint: "https://example.com/token"
      }
    }
    with_custom_oauth_credentials(config) do
      client = PreregisteredOauthConfig.find_for_server("unknown_provider")
      assert_not_nil client
      assert_equal "unknown_provider", client.key
      assert_equal "https://example.com/auth", client.authorization_endpoint
      assert_equal "https://example.com/token", client.token_endpoint
    end
  end

  private

  def skip_unless_oauth_credentials_available
    skip "OAuth credentials not available (CI environment)" unless oauth_credentials_available?
  end

  def oauth_credentials_available?
    oauth_clients = Rails.application.credentials.mcp_oauth_clients
    # Check for bigquery-pulsemcp with full config (including endpoints)
    bq_config = oauth_clients&.dig(:"bigquery-pulsemcp")
    bq_config.present? && bq_config[:authorization_endpoint].present?
  rescue ActiveSupport::MessageEncryptor::InvalidMessage, NoMethodError
    false
  end

  def with_no_oauth_credentials(&block)
    # Clear cached values and stub the credentials to return nil
    PreregisteredOauthConfig.reload!

    # Use instance_variable_set to simulate no credentials
    PreregisteredOauthConfig.instance_variable_set(:@oauth_clients_config, nil)
    PreregisteredOauthConfig.instance_variable_set(:@all, [])

    yield
  ensure
    PreregisteredOauthConfig.reload!
  end

  def with_custom_oauth_credentials(config)
    # Clear cached values and set custom credentials
    PreregisteredOauthConfig.reload!

    PreregisteredOauthConfig.instance_variable_set(:@oauth_clients_config, config)
    PreregisteredOauthConfig.instance_variable_set(:@all, nil)

    yield
  ensure
    PreregisteredOauthConfig.reload!
  end
end
