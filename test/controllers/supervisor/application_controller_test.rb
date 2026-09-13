# frozen_string_literal: true

require "test_helper"

# The panel's auth posture, which is the rest of the web UI's: no credential at
# all, with the network perimeter as the boundary. Every Administrate controller
# inherits from this one, so the dashboards here stand in for all of them.
module Supervisor
  class ApplicationControllerTest < ActionDispatch::IntegrationTest
    test "serves the panel without a credential and without a challenge" do
      get supervisor_logs_url

      assert_response :success
      assert_nil response.headers["WWW-Authenticate"]
    end

    # The token-bearing dashboards are the most sensitive ones. They are open
    # like the rest.
    test "the credential dashboards answer without a credential" do
      [ supervisor_claude_accounts_url, supervisor_mcp_oauth_credentials_url, supervisor_x_oauth_credentials_url ].each do |url|
        get url

        assert_response :success, "#{url} should answer without a credential"
        assert_nil response.headers["WWW-Authenticate"], "#{url} should not challenge"
      end
    end

    # With no credential, CSRF is what keeps a page on another origin from
    # submitting the panel's forms from a human's browser.
    test "a write without a CSRF token is refused and changes nothing" do
      user = users(:tadasant)
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true

      patch supervisor_user_url(user), params: { user: { display_name: "Forged" } }

      assert_response :unprocessable_entity
      assert_not_equal "Forged", user.reload.display_name
    ensure
      ActionController::Base.allow_forgery_protection = original
    end

    test "a hover-prefetch is served like any other request" do
      get supervisor_logs_url, headers: { "HTTP_X_SEC_PURPOSE" => "prefetch" }

      assert_response :success
    end
  end
end
