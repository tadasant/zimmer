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

  test "should get index" do
    get oauth_status_index_path
    assert_response :success
    assert_select "h1", "OAuth Status"
    assert_select "span.text-gray-900", @credential.server_name
  end

  test "should show empty state when no credentials" do
    McpOauthCredential.destroy_all
    get oauth_status_index_path
    assert_response :success
    assert_select "h3", "No OAuth Credentials"
  end

  test "should show active status for non-expired credentials" do
    get oauth_status_index_path
    assert_response :success
    assert_select "span.bg-green-100", "Active"
  end

  test "should show expired status for expired credentials" do
    @credential.update!(expires_at: 1.hour.ago)
    get oauth_status_index_path
    assert_response :success
    assert_select "span.bg-red-100", "Expired"
  end

  test "should destroy credential with html format" do
    assert_difference("McpOauthCredential.count", -1) do
      delete oauth_status_path(@credential)
    end
    assert_redirected_to oauth_status_index_path
  end

  test "should destroy credential with turbo_stream format" do
    assert_difference("McpOauthCredential.count", -1) do
      delete oauth_status_path(@credential), as: :turbo_stream
    end
    assert_response :success
  end
end
