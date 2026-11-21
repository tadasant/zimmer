# frozen_string_literal: true

require "test_helper"

module Supervisor
  # The panel says whether each secret is set and never renders it — not on the
  # index, not on the show page, and not pre-filled into the edit form. A blank
  # field on the form keeps the stored value.
  class McpOauthCredentialsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @credential = mcp_oauth_credentials(:notion)
      @credential.update!(access_token: "at-visible-canary", refresh_token: "rt-visible-canary", client_secret: "cs-visible-canary")
    end

    test "no page renders a stored secret" do
      [ supervisor_mcp_oauth_credentials_path, supervisor_mcp_oauth_credential_path(@credential),
        edit_supervisor_mcp_oauth_credential_path(@credential) ].each do |path|
        get path
        assert_response :success
        assert_no_match "visible-canary", response.body, "#{path} rendered a secret"
      end

      get supervisor_mcp_oauth_credential_path(@credential)
      assert_match "set (hidden)", response.body
    end

    test "a blank secret field keeps the stored value; a filled one replaces it" do
      patch supervisor_mcp_oauth_credential_path(@credential), params: {
        mcp_oauth_credential: { access_token: "", refresh_token: "rt-new", client_secret: "", scopes: "read" }
      }

      @credential.reload
      assert_equal "at-visible-canary", @credential.access_token
      assert_equal "rt-new", @credential.refresh_token
      assert_equal "rt-new", @credential.refresh_token_ciphertext
      assert_equal "cs-visible-canary", @credential.client_secret
      assert_equal "read", @credential.scopes
    end
  end
end
