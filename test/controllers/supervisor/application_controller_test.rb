# frozen_string_literal: true

require "test_helper"

# The gate itself. Every Administrate controller inherits it, so
# supervisor_logs_url stands in for all nineteen dashboards.
module Supervisor
  class ApplicationControllerTest < ActionDispatch::IntegrationTest
    PASSWORD_ENV = Supervisor::ApplicationController::PASSWORD_ENV
    USERNAME_ENV = Supervisor::ApplicationController::USERNAME_ENV

    setup do
      @original_password = ENV[PASSWORD_ENV]
      @original_username = ENV[USERNAME_ENV]
    end

    teardown do
      restore_env(PASSWORD_ENV, @original_password)
      restore_env(USERNAME_ENV, @original_username)
    end

    # === Fail closed ===

    test "returns 401 when SUPERVISOR_PASSWORD is unset" do
      ENV.delete(PASSWORD_ENV)

      get supervisor_logs_url

      assert_response :unauthorized
    end

    test "returns 401 when SUPERVISOR_PASSWORD is blank" do
      ENV[PASSWORD_ENV] = ""

      get supervisor_logs_url

      assert_response :unauthorized
    end

    test "an unset password rejects even a correctly-formed credential" do
      ENV.delete(PASSWORD_ENV)

      # No password is configured, so there is no credential that opens the
      # panel — an empty one least of all.
      get supervisor_logs_url, headers: basic_auth_headers("supervisor", "")

      assert_response :unauthorized
    end

    # === 401 paths with a password configured ===

    test "returns 401 without any credential" do
      ENV[PASSWORD_ENV] = "s3cret"

      get supervisor_logs_url

      assert_response :unauthorized
      assert_match(/Basic realm=/, response.headers["WWW-Authenticate"].to_s)
    end

    test "returns 401 with the wrong password" do
      ENV[PASSWORD_ENV] = "s3cret"

      get supervisor_logs_url, headers: basic_auth_headers("supervisor", "wrong")

      assert_response :unauthorized
    end

    test "returns 401 with the wrong username" do
      ENV[PASSWORD_ENV] = "s3cret"

      get supervisor_logs_url, headers: basic_auth_headers("someone-else", "s3cret")

      assert_response :unauthorized
    end

    # === Success path ===

    test "serves the panel with the right credential" do
      ENV[PASSWORD_ENV] = "s3cret"

      get supervisor_logs_url, headers: basic_auth_headers("supervisor", "s3cret")

      assert_response :success
    end

    test "SUPERVISOR_USERNAME overrides the default username" do
      ENV[PASSWORD_ENV] = "s3cret"
      ENV[USERNAME_ENV] = "jon"

      get supervisor_logs_url, headers: basic_auth_headers("jon", "s3cret")
      assert_response :success

      get supervisor_logs_url, headers: basic_auth_headers("supervisor", "s3cret")
      assert_response :unauthorized
    end

    # The gate is on the shared parent, so it covers the token-bearing
    # dashboards — the reason it exists — and not just the one above.
    test "the credential dashboards are gated too" do
      ENV[PASSWORD_ENV] = "s3cret"

      get supervisor_x_oauth_credentials_url
      assert_response :unauthorized

      get supervisor_x_oauth_credentials_url, headers: basic_auth_headers("supervisor", "s3cret")
      assert_response :success
    end

    private

    def basic_auth_headers(username, password)
      { "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials(username, password) }
    end

    def restore_env(key, value)
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end
end
