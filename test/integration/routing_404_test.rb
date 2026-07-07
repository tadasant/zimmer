require "test_helper"

# Routing misses (404s) must NOT be logged at ERROR. Rails' default behavior raises
# ActionController::RoutingError for an unmatched path, which DebugExceptions logs at
# ERROR — and a single ERROR line trips the critical "Zimmer ERROR logs
# present" Grafana alert. The favicon route + bottom catch-all route convert these into
# quiet, non-ERROR responses. See GitHub issue #4307.
class Routing404Test < ActionDispatch::IntegrationTest
  test "GET /favicon.ico returns 204 and does not log at ERROR" do
    log = capture_log_output do
      get "/favicon.ico"
    end

    assert_response :no_content
    assert_no_error_logged(log)
  end

  test "unmatched HTML path returns 404 without raising or logging at ERROR" do
    log = capture_log_output do
      get "/this-route-does-not-exist-12345"
    end

    assert_response :not_found
    # Served from the static 404 page.
    assert_match(/Page Not Found|404/i, response.body)
    assert_no_error_logged(log)
  end

  test "unmatched API path returns JSON 404 without logging at ERROR" do
    log = capture_log_output do
      get "/api/v1/this-endpoint-does-not-exist"
    end

    assert_response :not_found
    body = JSON.parse(response.body)
    assert_equal "Not Found", body["error"]
    assert_no_error_logged(log)
  end

  test "unmatched route logs at INFO for observability" do
    log = capture_log_output do
      get "/some-missing-path"
    end

    assert_match(/Unmatched route 404: GET \/some-missing-path/, log)
  end

  test "non-GET unmatched path is also handled by the catch-all" do
    log = capture_log_output do
      post "/no-such-action-here"
    end

    assert_response :not_found
    assert_no_error_logged(log)
  end

  test "non-GET request to the bare root is handled, not a RoutingError" do
    # `root` only handles GET /. The catch-all glob is optional ("(*unmatched)") so it
    # also matches the bare root path; a non-optional glob would miss / and let a
    # non-GET root request raise ActionController::RoutingError (logged at ERROR).
    %i[post put patch delete].each do |verb|
      log = capture_log_output do
        process(verb, "/")
      end

      assert_response :not_found, "#{verb.upcase} / should be a clean 404"
      assert_equal "errors", @controller.controller_name, "#{verb.upcase} / should reach ErrorsController"
      assert_no_error_logged(log)
    end
  end

  test "non-GET unmatched path with forgery protection enabled does not raise CSRF error" do
    # The test env disables forgery protection by default, so a tokenless POST cannot
    # exercise the production CSRF path. Re-enable it here to prove ErrorsController's
    # skip_forgery_protection keeps non-GET misses a clean 404 instead of raising
    # ActionController::InvalidAuthenticityToken (which would log at ERROR).
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    log = capture_log_output do
      post "/no-such-action-here-with-csrf"
    end

    assert_response :not_found
    refute_match(/InvalidAuthenticityToken/, log, "non-GET 404 must not raise a CSRF error")
    assert_no_error_logged(log)
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  private

  def assert_no_error_logged(log)
    refute_match(/RoutingError/, log, "routing miss must not surface a RoutingError")
    refute_match(/\bERROR\b/, log, "routing miss must not be logged at ERROR")
    refute_match(/\bFATAL\b/, log, "routing miss must not be logged at FATAL")
  end

  def capture_log_output
    original_logger = Rails.logger
    log_output = StringIO.new
    Rails.logger = Logger.new(log_output)

    yield

    log_output.string
  ensure
    Rails.logger = original_logger
  end
end
