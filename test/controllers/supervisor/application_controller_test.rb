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

    # === The challenge is for humans, not for the browser's guesses ===
    #
    # A 401 is the gate refusing. `WWW-Authenticate: Basic` on it is a separate
    # instruction to the browser to go ask the human, and the browser obeys it
    # for any same-origin credentialed fetch — including Turbo's hover-prefetch,
    # which no one clicked. That is how a sign-in dialog appeared over the
    # sessions dashboard at random moments. The refusal stays; the summons does
    # not go out for a request nobody made.

    test "a prefetched request is refused without a Basic challenge" do
      ENV[PASSWORD_ENV] = "s3cret"

      get supervisor_logs_url, headers: { "HTTP_X_SEC_PURPOSE" => "prefetch" }

      assert_response :unauthorized
      assert_nil response.headers["WWW-Authenticate"],
        "a challenge on a background fetch is what pops the browser's native sign-in dialog"
    end

    test "a browser-initiated prefetch is refused without a Basic challenge" do
      ENV[PASSWORD_ENV] = "s3cret"

      # Speculation rules and <link rel=prefetch> send the standard header;
      # Chrome has sent the pre-standard `Purpose:` spelling for years.
      [ "HTTP_SEC_PURPOSE", "HTTP_PURPOSE" ].each do |header|
        get supervisor_logs_url, headers: { header => "prefetch" }

        assert_response :unauthorized, "#{header} should still be refused"
        assert_nil response.headers["WWW-Authenticate"], "#{header} should not be challenged"
      end
    end

    test "an unconfigured realm does not challenge a prefetch either" do
      ENV.delete(PASSWORD_ENV)

      get supervisor_logs_url, headers: { "HTTP_X_SEC_PURPOSE" => "prefetch" }

      assert_response :unauthorized
      assert_nil response.headers["WWW-Authenticate"]
    end

    # Turbo hands a prefetched response to a later click on the same link, so the
    # 401 body is what a link that forgot `data-turbo-prefetch="false"` would
    # render. It has to be HTML with a way forward — Turbo renders a non-HTML
    # error response as a blank page.
    test "the prefetch refusal renders a page that can reach the real challenge" do
      ENV[PASSWORD_ENV] = "s3cret"

      get supervisor_logs_url, headers: { "HTTP_X_SEC_PURPOSE" => "prefetch" }

      assert_equal "text/html", response.media_type
      assert_select "a[href=?][data-turbo=?]", supervisor_logs_path, "false" do |links|
        assert_equal 1, links.size, "one link back, forcing a real navigation that does get challenged"
      end
    end

    # The whole point of suppressing the challenge only for prefetches: a human
    # who clicks the link must still be able to sign in.
    test "a real navigation still gets the Basic challenge" do
      ENV[PASSWORD_ENV] = "s3cret"

      # What Turbo Drive sends for a click: no prefetch marker anywhere.
      get supervisor_logs_url, headers: { "HTTP_SEC_FETCH_MODE" => "cors", "HTTP_SEC_FETCH_DEST" => "empty" }

      assert_response :unauthorized
      assert_match(/Basic realm="#{Supervisor::ApplicationController::REALM}"/, response.headers["WWW-Authenticate"].to_s)
    end

    # A prefetch that *does* carry the credential is still a real request for a
    # real page — suppressing the challenge must not suppress the panel.
    test "a prefetch with the right credential still serves the panel" do
      ENV[PASSWORD_ENV] = "s3cret"

      get supervisor_logs_url, headers: basic_auth_headers("supervisor", "s3cret").merge("HTTP_X_SEC_PURPOSE" => "prefetch")

      assert_response :success
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
