# frozen_string_literal: true

require "test_helper"

class McpOauthCredentialsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @credential = McpOauthCredential.create!(
      server_name: "test-server",
      server_url: "https://test.example.com/mcp",
      credential_key: "test-server|abc123",
      client_id: "test-client-id",
      access_token: "test-access-token",
      refresh_token: "test-refresh-token",
      expires_at: 1.hour.from_now,
      token_endpoint: "https://test.example.com/oauth/token"
    )
  end

  test "should destroy credential with html format and return to Connectors" do
    assert_difference("McpOauthCredential.count", -1) do
      delete mcp_oauth_credential_path(@credential)
    end
    assert_redirected_to connectors_path
  end

  test "should destroy credential with turbo_stream format" do
    assert_difference("McpOauthCredential.count", -1) do
      delete mcp_oauth_credential_path(@credential), as: :turbo_stream
    end
    assert_response :success
  end
end
