require "test_helper"

# Routing misses (404s) must NOT be logged at ERROR. Rails' default behavior raises
# ActionController::RoutingError for an unmatched path, which DebugExceptions logs at
# ERROR — and a single ERROR line trips the critical "Zimmer ERROR logs
# present" Grafana alert. The bottom catch-all route converts these into quiet,
# non-ERROR responses. See GitHub issue #4307.
class Routing404Test < ActionDispatch::IntegrationTest
  # Browsers request /favicon.ico at the root regardless of what <link rel="icon">
  # advertises. The app ships a real one in public/, so the static file server
  # answers before the router is ever consulted — no RoutingError, no ERROR line,
  # and the tab actually gets an icon.
  test "GET /favicon.ico serves the icon and does not log at ERROR" do
    log = capture_log_output do
      get "/favicon.ico"
    end

    assert_response :success
    assert_equal "\x00\x00\x01\x00".b, response.body.byteslice(0, 4).b, "should be an ICO container"
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

  # Attaches a sink to Rails.logger rather than replacing it. Replacing it captures
  # strictly less: DebugExceptions — the middleware that would log a RoutingError at
  # ERROR, which is the whole thing these assertions rule out — writes to
  # env_config["action_dispatch.logger"], a value memoized once per process (see
  # test_helper.rb) and merged over every request env. A swapped-in logger is not that
  # object, so the assertions below would pass without ever being able to see the record
  # they forbid. Replacing it also used to leave that memo pointing at this throwaway
  # logger for the rest of the worker, which is what made the ERROR-record control in
  # csrf_failure_logging_test.rb fail at random (#337).
  def capture_log_output
    log_output = StringIO.new
    sink = Logger.new(log_output)
    Rails.logger.broadcast_to(sink)

    yield

    log_output.string
  ensure
    Rails.logger.stop_broadcasting_to(sink)
  end
end
