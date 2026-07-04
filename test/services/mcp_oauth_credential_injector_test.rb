# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "mocha/minitest"

class McpOauthCredentialInjectorTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:active_session)
    @working_directory = Dir.mktmpdir("mcp-oauth-test")
  end

  teardown do
    FileUtils.rm_rf(@working_directory) if @working_directory && File.exist?(@working_directory)
  end

  # Test that check_credentials_status attempts refresh for expired tokens with refresh_token
  test "check_credentials_status attempts refresh for expired token with refresh_token" do
    credential = mcp_oauth_credentials(:expired_with_refresh)

    # Use a mock session that returns our test server without validation
    mock_session = Object.new
    mock_session.define_singleton_method(:mcp_servers) { [ "refreshable-server" ] }

    server_config = mock_server_config(
      name: "refreshable-server",
      type: "streamable-http",
      url: "https://refreshable.example.com/mcp"
    )

    ServersConfig.stub(:find, ->(name) { name == "refreshable-server" ? server_config : nil }) do
      # Update the credential's key to match what compute_credential_key would generate
      expected_key = McpOauthCredential.compute_credential_key("refreshable-server", {
        type: "streamable-http",
        url: "https://refreshable.example.com/mcp",
        headers: {}
      })
      credential.update_column(:credential_key, expected_key)

      # Stub the HTTP refresh call to return a successful response
      successful_refresh_response = Net::HTTPSuccess.new("1.1", "200", "OK")
      successful_refresh_response.stubs(:code).returns("200")
      successful_refresh_response.stubs(:body).returns({
        access_token: "new-access-token",
        refresh_token: "new-refresh-token",
        expires_in: 3600
      }.to_json)

      Net::HTTP.stub(:post_form, successful_refresh_response) do
        injector = McpOauthCredentialInjector.new(mock_session, working_directory: @working_directory)

        # Before check_credentials_status, the credential is expired
        assert_not credential.active?, "Credential should be expired before refresh"

        status = injector.check_credentials_status

        # After check_credentials_status, token should be refreshed
        credential.reload
        assert credential.active?, "Credential should be active after refresh"
        assert_equal "new-access-token", credential.access_token
        assert_equal "new-refresh-token", credential.refresh_token

        # Status should reflect the refreshed credential as valid
        server_status = status["refreshable-server"]
        assert server_status[:has_credential], "Should have credential after refresh"
        assert server_status[:credential_valid], "Credential should be valid after refresh"
      end
    end
  end

  test "check_credentials_status marks credential as invalid when refresh fails" do
    credential = mcp_oauth_credentials(:expired_with_refresh)

    mock_session = Object.new
    mock_session.define_singleton_method(:mcp_servers) { [ "refreshable-server" ] }

    server_config = mock_server_config(
      name: "refreshable-server",
      type: "streamable-http",
      url: "https://refreshable.example.com/mcp"
    )

    ServersConfig.stub(:find, ->(name) { name == "refreshable-server" ? server_config : nil }) do
      expected_key = McpOauthCredential.compute_credential_key("refreshable-server", {
        type: "streamable-http",
        url: "https://refreshable.example.com/mcp",
        headers: {}
      })
      credential.update_column(:credential_key, expected_key)

      # Stub the HTTP refresh call to return a failure
      failed_refresh_response = Net::HTTPUnauthorized.new("1.1", "401", "Unauthorized")
      failed_refresh_response.stubs(:code).returns("401")
      failed_refresh_response.stubs(:body).returns({ error: "invalid_grant" }.to_json)

      Net::HTTP.stub(:post_form, failed_refresh_response) do
        injector = McpOauthCredentialInjector.new(mock_session, working_directory: @working_directory)
        status = injector.check_credentials_status

        # Credential should still exist but be invalid (refresh failed)
        server_status = status["refreshable-server"]
        assert server_status[:has_credential], "Should still have credential"
        assert_not server_status[:credential_valid], "Credential should be invalid after failed refresh"
      end
    end
  end

  test "check_credentials_status does not attempt refresh for expired token without refresh_token" do
    credential = mcp_oauth_credentials(:expired)

    mock_session = Object.new
    mock_session.define_singleton_method(:mcp_servers) { [ "expired-server" ] }

    server_config = mock_server_config(
      name: "expired-server",
      type: "streamable-http",
      url: "https://expired.example.com/mcp"
    )

    ServersConfig.stub(:find, ->(name) { name == "expired-server" ? server_config : nil }) do
      expected_key = McpOauthCredential.compute_credential_key("expired-server", {
        type: "streamable-http",
        url: "https://expired.example.com/mcp",
        headers: {}
      })
      credential.update_column(:credential_key, expected_key)

      # Net::HTTP.post_form should NOT be called since there's no refresh token
      Net::HTTP.stub(:post_form, ->(*) { raise "Should not attempt refresh without refresh_token" }) do
        injector = McpOauthCredentialInjector.new(mock_session, working_directory: @working_directory)
        status = injector.check_credentials_status

        # Credential should exist but be invalid (can't refresh)
        server_status = status["expired-server"]
        assert server_status[:has_credential], "Should have credential record"
        assert_not server_status[:credential_valid], "Credential should be invalid (expired, no refresh)"
      end
    end
  end

  test "check_credentials_status skips refresh for active (non-expired) tokens" do
    credential = mcp_oauth_credentials(:notion)

    mock_session = Object.new
    mock_session.define_singleton_method(:mcp_servers) { [ "notion" ] }

    server_config = mock_server_config(
      name: "notion",
      type: "streamable-http",
      url: "https://mcp.notion.com/v1/mcp"
    )

    ServersConfig.stub(:find, ->(name) { name == "notion" ? server_config : nil }) do
      expected_key = McpOauthCredential.compute_credential_key("notion", {
        type: "streamable-http",
        url: "https://mcp.notion.com/v1/mcp",
        headers: {}
      })
      credential.update_column(:credential_key, expected_key)

      # Net::HTTP.post_form should NOT be called for active tokens
      Net::HTTP.stub(:post_form, ->(*) { raise "Should not refresh active token" }) do
        injector = McpOauthCredentialInjector.new(mock_session, working_directory: @working_directory)
        status = injector.check_credentials_status

        # Credential should be valid without refresh
        server_status = status["notion"]
        assert server_status[:has_credential], "Should have credential"
        assert server_status[:credential_valid], "Credential should be valid (not expired)"
      end
    end
  end

  test "check_credentials_status returns empty hash when no mcp_servers configured" do
    mock_session = Object.new
    mock_session.define_singleton_method(:mcp_servers) { nil }

    injector = McpOauthCredentialInjector.new(mock_session, working_directory: @working_directory)
    status = injector.check_credentials_status

    assert_equal({}, status)
  end

  test "check_credentials_status only checks remote server types" do
    mock_session = Object.new
    mock_session.define_singleton_method(:mcp_servers) { [ "local-server" ] }

    server_config = mock_server_config(
      name: "local-server",
      type: "stdio",  # stdio is local, not remote
      url: nil
    )

    ServersConfig.stub(:find, ->(name) { name == "local-server" ? server_config : nil }) do
      injector = McpOauthCredentialInjector.new(mock_session, working_directory: @working_directory)
      status = injector.check_credentials_status

      # Local server types should be skipped entirely
      assert_not status.key?("local-server"), "Should skip local server types"
    end
  end

  test "check_credentials_status preserves existing refresh_token when server does not return new one" do
    credential = mcp_oauth_credentials(:expired_with_refresh)
    original_refresh_token = credential.refresh_token

    mock_session = Object.new
    mock_session.define_singleton_method(:mcp_servers) { [ "refreshable-server" ] }

    server_config = mock_server_config(
      name: "refreshable-server",
      type: "streamable-http",
      url: "https://refreshable.example.com/mcp"
    )

    ServersConfig.stub(:find, ->(name) { name == "refreshable-server" ? server_config : nil }) do
      expected_key = McpOauthCredential.compute_credential_key("refreshable-server", {
        type: "streamable-http",
        url: "https://refreshable.example.com/mcp",
        headers: {}
      })
      credential.update_column(:credential_key, expected_key)

      # Stub response WITHOUT a new refresh token
      successful_refresh_response = Net::HTTPSuccess.new("1.1", "200", "OK")
      successful_refresh_response.stubs(:code).returns("200")
      successful_refresh_response.stubs(:body).returns({
        access_token: "new-access-token",
        # No refresh_token in response - server keeps the same one
        expires_in: 3600
      }.to_json)

      Net::HTTP.stub(:post_form, successful_refresh_response) do
        injector = McpOauthCredentialInjector.new(mock_session, working_directory: @working_directory)
        injector.check_credentials_status

        credential.reload
        # Original refresh token should be preserved
        assert_equal original_refresh_token, credential.refresh_token
        assert_equal "new-access-token", credential.access_token
      end
    end
  end

  test "check_credentials_status handles network timeout gracefully" do
    credential = mcp_oauth_credentials(:expired_with_refresh)

    mock_session = Object.new
    mock_session.define_singleton_method(:mcp_servers) { [ "refreshable-server" ] }

    server_config = mock_server_config(
      name: "refreshable-server",
      type: "streamable-http",
      url: "https://refreshable.example.com/mcp"
    )

    ServersConfig.stub(:find, ->(name) { name == "refreshable-server" ? server_config : nil }) do
      expected_key = McpOauthCredential.compute_credential_key("refreshable-server", {
        type: "streamable-http",
        url: "https://refreshable.example.com/mcp",
        headers: {}
      })
      credential.update_column(:credential_key, expected_key)

      # Stub the HTTP call to raise a timeout error
      Net::HTTP.stub(:post_form, ->(*) { raise Timeout::Error, "Connection timed out" }) do
        injector = McpOauthCredentialInjector.new(mock_session, working_directory: @working_directory)

        # Should not raise, should handle gracefully
        status = injector.check_credentials_status

        # Credential should still exist but be invalid
        server_status = status["refreshable-server"]
        assert server_status[:has_credential], "Should still have credential"
        assert_not server_status[:credential_valid], "Credential should be invalid after timeout"
      end
    end
  end

  test "check_credentials_status sets requires_reauth when refresh is permanently invalid" do
    credential = mcp_oauth_credentials(:expired_with_refresh)

    mock_session = Object.new
    mock_session.define_singleton_method(:mcp_servers) { [ "refreshable-server" ] }

    server_config = mock_server_config(
      name: "refreshable-server",
      type: "streamable-http",
      url: "https://refreshable.example.com/mcp"
    )

    ServersConfig.stub(:find, ->(name) { name == "refreshable-server" ? server_config : nil }) do
      expected_key = McpOauthCredential.compute_credential_key("refreshable-server", {
        type: "streamable-http",
        url: "https://refreshable.example.com/mcp",
        headers: {}
      })
      credential.update_column(:credential_key, expected_key)

      # Stub the HTTP refresh call to return a failure
      failed_refresh_response = Net::HTTPUnauthorized.new("1.1", "401", "Unauthorized")
      failed_refresh_response.stubs(:code).returns("401")
      failed_refresh_response.stubs(:body).returns({ error: "invalid_grant" }.to_json)

      PreregisteredOauthConfig.stub(:find_for_server, nil) do
        Net::HTTP.stub(:post_form, failed_refresh_response) do
          injector = McpOauthCredentialInjector.new(mock_session, working_directory: @working_directory)
          status = injector.check_credentials_status

          server_status = status["refreshable-server"]
          assert server_status[:has_credential], "Should have credential"
          assert_not server_status[:credential_valid], "Should be invalid"
          assert_not server_status[:refresh_failed], "Permanent invalidation clears refresh capability"
          assert server_status[:requires_reauth], "Should require re-auth when refresh token is invalid"
        end
      end
    end
  end

  test "check_credentials_status does not set refresh_failed for active tokens" do
    credential = mcp_oauth_credentials(:notion)

    mock_session = Object.new
    mock_session.define_singleton_method(:mcp_servers) { [ "notion" ] }

    server_config = mock_server_config(
      name: "notion",
      type: "streamable-http",
      url: "https://mcp.notion.com/v1/mcp"
    )

    ServersConfig.stub(:find, ->(name) { name == "notion" ? server_config : nil }) do
      expected_key = McpOauthCredential.compute_credential_key("notion", {
        type: "streamable-http",
        url: "https://mcp.notion.com/v1/mcp",
        headers: {}
      })
      credential.update_column(:credential_key, expected_key)

      PreregisteredOauthConfig.stub(:find_for_server, nil) do
        Net::HTTP.stub(:post_form, ->(*) { raise "Should not refresh active token" }) do
          injector = McpOauthCredentialInjector.new(mock_session, working_directory: @working_directory)
          status = injector.check_credentials_status

          server_status = status["notion"]
          assert server_status[:credential_valid], "Should be valid"
          assert_not server_status[:refresh_failed], "Should not flag refresh_failed for active token"
          assert_not server_status[:requires_reauth], "Should not require re-auth for active token"
        end
      end
    end
  end

  test "check_credentials_status does not set refresh_failed for expired token without refresh capability" do
    credential = mcp_oauth_credentials(:expired)

    mock_session = Object.new
    mock_session.define_singleton_method(:mcp_servers) { [ "expired-server" ] }

    server_config = mock_server_config(
      name: "expired-server",
      type: "streamable-http",
      url: "https://expired.example.com/mcp"
    )

    ServersConfig.stub(:find, ->(name) { name == "expired-server" ? server_config : nil }) do
      expected_key = McpOauthCredential.compute_credential_key("expired-server", {
        type: "streamable-http",
        url: "https://expired.example.com/mcp",
        headers: {}
      })
      credential.update_column(:credential_key, expected_key)

      PreregisteredOauthConfig.stub(:find_for_server, nil) do
        Net::HTTP.stub(:post_form, ->(*) { raise "Should not attempt refresh" }) do
          injector = McpOauthCredentialInjector.new(mock_session, working_directory: @working_directory)
          status = injector.check_credentials_status

          server_status = status["expired-server"]
          assert_not server_status[:credential_valid], "Should be invalid"
          assert_not server_status[:refresh_failed], "Should not flag refresh_failed without refresh capability"
          assert server_status[:requires_reauth], "Should require re-auth without refresh capability"
        end
      end
    end
  end

  test "check_credentials_status requires reauth for expired token missing token_endpoint" do
    credential = mcp_oauth_credentials(:expired_with_refresh)
    credential.update!(token_endpoint: nil)

    mock_session = Object.new
    mock_session.define_singleton_method(:mcp_servers) { [ "refreshable-server" ] }

    server_config = mock_server_config(
      name: "refreshable-server",
      type: "streamable-http",
      url: "https://refreshable.example.com/mcp"
    )

    ServersConfig.stub(:find, ->(name) { name == "refreshable-server" ? server_config : nil }) do
      expected_key = McpOauthCredential.compute_credential_key("refreshable-server", {
        type: "streamable-http",
        url: "https://refreshable.example.com/mcp",
        headers: {}
      })
      credential.update_column(:credential_key, expected_key)

      PreregisteredOauthConfig.stub(:find_for_server, nil) do
        Net::HTTP.stub(:post_form, ->(*) { raise "Should not attempt refresh without token_endpoint" }) do
          injector = McpOauthCredentialInjector.new(mock_session, working_directory: @working_directory)
          status = injector.check_credentials_status

          server_status = status["refreshable-server"]
          assert_not server_status[:credential_valid], "Should be invalid"
          assert_not server_status[:refresh_failed], "Should not flag refresh_failed without refresh capability"
          assert server_status[:requires_reauth], "Should require re-auth without token_endpoint"
        end
      end
    end
  end

  test "check_credentials_status skips servers with a static Authorization header" do
    mock_session = Object.new
    mock_session.define_singleton_method(:mcp_servers) { [ "static-bearer-server" ] }

    server_config = mock_server_config(
      name: "static-bearer-server",
      type: "streamable-http",
      url: "https://mcp.example.com/mcp",
      headers: { "Authorization" => "Bearer some-static-token" }
    )

    ServersConfig.stub(:find, ->(name) { name == "static-bearer-server" ? server_config : nil }) do
      # OAuth probing must NOT happen when a static Authorization header is configured.
      # Stubbing Net::HTTP to raise ensures any probe attempt fails the test.
      Net::HTTP.stub(:new, ->(*) { raise "Should not probe a server with static Authorization header" }) do
        injector = McpOauthCredentialInjector.new(mock_session, working_directory: @working_directory)
        status = injector.check_credentials_status

        assert_not status.key?("static-bearer-server"),
          "Server with static Authorization header should be omitted from OAuth status (gate skipped)"
      end
    end
  end

  test "check_credentials_status matches Authorization header case-insensitively" do
    mock_session = Object.new
    mock_session.define_singleton_method(:mcp_servers) { [ "lowercase-auth-server" ] }

    server_config = mock_server_config(
      name: "lowercase-auth-server",
      type: "streamable-http",
      url: "https://mcp.example.com/mcp",
      headers: { "authorization" => "Bearer some-token" }
    )

    ServersConfig.stub(:find, ->(name) { name == "lowercase-auth-server" ? server_config : nil }) do
      injector = McpOauthCredentialInjector.new(mock_session, working_directory: @working_directory)
      status = injector.check_credentials_status

      assert_not status.key?("lowercase-auth-server"),
        "Server with lowercase 'authorization' header should be skipped (HTTP headers are case-insensitive)"
    end
  end

  test "check_credentials_status does not skip servers with empty Authorization header value" do
    mock_session = Object.new
    mock_session.define_singleton_method(:mcp_servers) { [ "empty-auth-server" ] }

    server_config = mock_server_config(
      name: "empty-auth-server",
      type: "streamable-http",
      url: "https://mcp.example.com/mcp",
      headers: { "Authorization" => "" }
    )

    ServersConfig.stub(:find, ->(name) { name == "empty-auth-server" ? server_config : nil }) do
      PreregisteredOauthConfig.stub(:find_for_server, nil) do
        injector = McpOauthCredentialInjector.new(mock_session, working_directory: @working_directory)
        status = injector.check_credentials_status

        # Empty value is a misconfiguration, not intent — keep the OAuth gate active
        assert status.key?("empty-auth-server"),
          "Server with empty Authorization header value must NOT be skipped"
      end
    end
  end

  test "check_credentials_status skips servers whose Authorization header still contains ${VAR} placeholders" do
    # Locks in the documented contract: presence of an Authorization entry signals
    # operator intent to use a static header credential, regardless of whether
    # ${VAR} placeholders have been resolved. AirPrepareService runs before the
    # OAuth gate and would raise on missing env vars, so an unresolved placeholder
    # reaching this code means the operator configured one and we should respect
    # their intent, not fall through to OAuth discovery.
    mock_session = Object.new
    mock_session.define_singleton_method(:mcp_servers) { [ "placeholder-server" ] }

    server_config = mock_server_config(
      name: "placeholder-server",
      type: "streamable-http",
      url: "https://mcp.example.com/mcp",
      headers: { "Authorization" => "Bearer ${SOME_TOKEN}" }
    )

    ServersConfig.stub(:find, ->(name) { name == "placeholder-server" ? server_config : nil }) do
      Net::HTTP.stub(:new, ->(*) { raise "Should not probe a server with static Authorization header" }) do
        injector = McpOauthCredentialInjector.new(mock_session, working_directory: @working_directory)
        status = injector.check_credentials_status

        assert_not status.key?("placeholder-server"),
          "Server with ${VAR} placeholder Authorization header should still be skipped (operator intent)"
      end
    end
  end

  test "check_credentials_status still gates servers without an Authorization header" do
    mock_session = Object.new
    mock_session.define_singleton_method(:mcp_servers) { [ "no-auth-server" ] }

    server_config = mock_server_config(
      name: "no-auth-server",
      type: "streamable-http",
      url: "https://mcp.example.com/mcp",
      headers: { "X-Other-Header" => "value" }
    )

    ServersConfig.stub(:find, ->(name) { name == "no-auth-server" ? server_config : nil }) do
      PreregisteredOauthConfig.stub(:find_for_server, nil) do
        injector = McpOauthCredentialInjector.new(mock_session, working_directory: @working_directory)
        status = injector.check_credentials_status

        # Server has no static auth credential, so it must remain in the status hash
        # so the gate sites can probe and (if needed) require OAuth.
        assert status.key?("no-auth-server"),
          "Server without Authorization header must continue to be checked by the OAuth gate"
        assert_not status["no-auth-server"][:has_credential],
          "Server without OAuth credential should report has_credential: false"
      end
    end
  end

  test "inject_credentials! resolves active credentials and routes them through the runtime writer" do
    credential = mcp_oauth_credentials(:notion)

    mock_session = Object.new
    mock_session.define_singleton_method(:mcp_servers) { [ "notion" ] }

    server_config = mock_server_config(
      name: "notion",
      type: "streamable-http",
      url: "https://mcp.notion.com/v1/mcp"
    )

    ServersConfig.stub(:find, ->(name) { name == "notion" ? server_config : nil }) do
      expected_key = McpOauthCredential.compute_credential_key("notion", {
        type: "streamable-http",
        url: "https://mcp.notion.com/v1/mcp",
        headers: {}
      })
      credential.update_column(:credential_key, expected_key)

      # Capture what the injector hands to the writer instead of touching disk.
      captured = nil
      fake_writer = Object.new
      fake_writer.define_singleton_method(:credential_key_for) { |name, config| McpOauthCredential.compute_credential_key(name, config) }
      fake_writer.define_singleton_method(:write!) do |working_directory:, credentials:|
        captured = credentials
        "/tmp/fake-credentials.json"
      end

      injector = McpOauthCredentialInjector.new(mock_session, working_directory: @working_directory)
      injector.stubs(:credential_writer).returns(fake_writer)

      result = injector.inject_credentials!

      assert_equal "/tmp/fake-credentials.json", result
      assert_equal 1, captured.size
      resolved = captured.first
      assert_instance_of ResolvedMcpCredential, resolved
      assert_equal "notion", resolved.server_name
      assert_equal credential.access_token, resolved.access_token
      assert_equal expected_key, resolved.credential_key
    end
  end

  test "inject_credentials! returns nil when no active credentials resolve" do
    mock_session = Object.new
    mock_session.define_singleton_method(:mcp_servers) { [ "no-credential-server" ] }

    server_config = mock_server_config(
      name: "no-credential-server",
      type: "streamable-http",
      url: "https://no-credential.example.com/mcp"
    )

    ServersConfig.stub(:find, ->(name) { name == "no-credential-server" ? server_config : nil }) do
      injector = McpOauthCredentialInjector.new(mock_session, working_directory: @working_directory)
      assert_nil injector.inject_credentials!
    end
  end

  private

  # Helper to create a mock server config object
  def mock_server_config(name:, type:, url:, headers: {})
    config = Object.new
    config.define_singleton_method(:name) { name }
    config.define_singleton_method(:type) { type }
    config.define_singleton_method(:url) { url }
    config.define_singleton_method(:headers) { headers }
    config
  end
end
