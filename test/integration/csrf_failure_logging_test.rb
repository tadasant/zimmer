require "test_helper"

# A tokenless non-GET request to a *matched* route must stay rejected, and must stop
# being logged at ERROR. Rails' default :exception CSRF strategy raises
# ActionController::InvalidAuthenticityToken, which DebugExceptions logs at ERROR —
# and one ERROR line trips the critical "Zimmer backend logging errors" Grafana
# alert with a body that is ~100% gem stack frames, naming no route, verb, IP or
# client. See GitHub issue #295.
#
# ApplicationController#invalid_authenticity_token handles the exception, renders the
# same 422, and re-logs the event at INFO with the fields triage needs. These tests
# pin both halves: CSRF is still enforced (the action never runs), and the record is
# INFO with attribution.
class CsrfFailureLoggingTest < ActionDispatch::IntegrationTest
  SESSION_COOKIE = "_zimmer_session".freeze

  # The test environment disables forgery protection globally
  # (config/environments/test.rb), so without this every example here would pass
  # vacuously — the action would simply run. Turn it on so these requests take the
  # real production code path.
  setup do
    @original_forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @original_forgery_protection
  end

  test "session key assumed by these tests matches the app's configured session cookie" do
    assert_equal SESSION_COOKIE, Rails.application.config.session_options[:key]
  end

  test "tokenless PATCH to a matched route is rejected with 422 and the action never runs" do
    notification = notifications(:default_notification)
    refute notification.read?, "fixture must start unread for this assertion to mean anything"

    capture_log_entries do
      patch mark_read_notification_path(notification)
    end

    assert_response :unprocessable_entity
    refute notification.reload.read?, "CSRF must still abort the action, not just relabel the log line"
  end

  test "tokenless POST to a matched route is rejected with 422 and the action never runs" do
    trigger = triggers(:enabled_slack_trigger)
    assert trigger.enabled?, "fixture must start enabled for this assertion to mean anything"

    capture_log_entries do
      post toggle_trigger_path(trigger)
    end

    assert_response :unprocessable_entity
    assert trigger.reload.enabled?, "CSRF must still abort the action, not just relabel the log line"
  end

  test "the CSRF failure is logged at INFO, never at ERROR or FATAL" do
    entries = capture_log_entries do
      patch mark_read_notification_path(notifications(:default_notification))
    end

    csrf_entries = entries.select { |_severity, message| message.include?("CSRF verification failed 422") }
    assert_equal 1, csrf_entries.size, "expected exactly one attributable CSRF record, got: #{entries.inspect}"
    assert_equal "INFO", csrf_entries.first.first

    # The whole point of the change: no ERROR record, so the alert does not fire.
    assert_empty entries.select { |severity, _message| %w[ERROR FATAL].include?(severity) },
      "a CSRF failure must not emit an ERROR/FATAL record: #{entries.inspect}"
    refute entries.any? { |_severity, message| message.include?("InvalidAuthenticityToken") },
      "the raw exception must not reach the log: #{entries.inspect}"
  end

  test "the logged line names the method, path, IP, user agent, and an absent session cookie" do
    entries = capture_log_entries do
      patch mark_read_notification_path(notifications(:default_notification)),
        headers: { "User-Agent" => "curl/8.7.1" },
        env: { "REMOTE_ADDR" => "203.0.113.9" }
    end

    line = csrf_line(entries)
    assert_includes line, "PATCH"
    assert_includes line, mark_read_notification_path(notifications(:default_notification))
    assert_includes line, "ip=203.0.113.9"
    assert_includes line, "session_cookie=absent"
    assert_includes line, 'user_agent="curl/8.7.1"'
    assert_includes line, 'reason="Can\'t verify CSRF token authenticity."'
  end

  test "an Origin mismatch is distinguishable from a missing token" do
    # Rails raises InvalidAuthenticityToken for two very different conditions. A bad
    # Origin means the proxy in front of the app is misreporting scheme or host,
    # which breaks every write for every real user (#19) — the opposite of a bot
    # probe. Carrying the exception message is what keeps them apart in the log.
    entries = capture_log_entries do
      patch mark_read_notification_path(notifications(:default_notification)),
        headers: { "Origin" => "https://not-this-app.example" }
    end

    assert_response :unprocessable_entity
    line = csrf_line(entries)
    assert_includes line, "reason=\"HTTP Origin header (https://not-this-app.example)"
    refute_includes line, "Can't verify CSRF token authenticity."
  end

  test "a request carrying a session cookie is logged as session_cookie=present" do
    # Session-present means a browser that has been here before — a stale form or an
    # expired session, i.e. a real user. Session-absent means an unauthenticated
    # probe. Telling those two apart is the entire triage this change exists for.
    cookies[SESSION_COOKIE] = "stale-but-present"

    entries = capture_log_entries do
      post toggle_trigger_path(triggers(:enabled_slack_trigger)),
        headers: { "User-Agent" => "Mozilla/5.0 (Macintosh) Safari/605.1.15" },
        env: { "REMOTE_ADDR" => "198.51.100.4" }
    end

    line = csrf_line(entries)
    assert_includes line, "POST"
    assert_includes line, toggle_trigger_path(triggers(:enabled_slack_trigger))
    assert_includes line, "ip=198.51.100.4"
    assert_includes line, "session_cookie=present"
    assert_includes line, 'user_agent="Mozilla/5.0 (Macintosh) Safari/605.1.15"'
  end

  test "the CSRF record is a single line even when the user agent is hostile" do
    # Log records are line-oriented; a UA with an embedded newline must not be able
    # to forge a second record.
    entries = capture_log_entries do
      patch mark_read_notification_path(notifications(:default_notification)),
        headers: { "User-Agent" => "evil\nERROR -- : forged record" }
    end

    line = csrf_line(entries)
    refute_includes line, "\n", "the user agent must be escaped, not interpolated raw"
    assert_includes line, 'user_agent="evil\nERROR -- : forged record"'
  end

  test "a JSON request gets the error envelope rather than a plain-text body" do
    entries = capture_log_entries do
      patch mark_read_notification_path(notifications(:default_notification)), as: :json
    end

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "Unprocessable Entity", body["error"]
    assert_match(/CSRF/, body["message"])
    assert_equal "INFO", csrf_entry(entries).first
  end

  test "a browser request gets a plain-text 422 body" do
    patch mark_read_notification_path(notifications(:default_notification))

    assert_response :unprocessable_entity
    assert_equal "text/plain", response.media_type
    assert_match(/rejected/i, response.body)
  end

  test "a GET to the same controller is unaffected by the handler" do
    entries = capture_log_entries do
      get notifications_path
    end

    assert_response :success
    refute entries.any? { |_severity, message| message.include?("CSRF verification failed") },
      "a GET is exempt from the check and must not produce a CSRF record"
  end

  # The control. Without ApplicationController's rescue_from, this exact request is
  # what production emitted in #295: an ERROR record whose body is the
  # InvalidAuthenticityToken stack trace and nothing else. Removing only that one
  # handler (the RecordNotFound one stays) reproduces the pre-fix behavior, which
  # proves two things at once — the assertions above are not vacuous, and the
  # capture harness really does observe the middleware's ERROR record.
  test "without the handler the same request emits an ERROR record and no INFO line" do
    entries = without_csrf_rescue_handler do
      capture_log_entries do
        patch mark_read_notification_path(notifications(:default_notification))
      end
    end

    assert_response :unprocessable_entity
    errors = entries.select { |severity, _message| %w[ERROR FATAL].include?(severity) }
    refute_empty errors, "expected the unhandled exception to be logged at ERROR: #{entries.inspect}"
    assert errors.any? { |_severity, message| message.include?("InvalidAuthenticityToken") },
      "expected the raw exception in the ERROR record: #{errors.inspect}"
    refute entries.any? { |_severity, message| message.include?("CSRF verification failed 422") },
      "the attributable INFO line must come from the handler, not from anywhere else"
  end

  private

  # rescue_handlers is a class_attribute, so assigning here defines the value on
  # ApplicationController and every descendant reading through it, and restoring it
  # afterwards fully reverts. Examples within a parallel worker run sequentially, so
  # this cannot leak into a concurrently-executing test.
  def without_csrf_rescue_handler
    original = ApplicationController.rescue_handlers
    ApplicationController.rescue_handlers =
      original.reject { |klass, _handler| klass == "ActionController::InvalidAuthenticityToken" }

    yield
  ensure
    ApplicationController.rescue_handlers = original
  end

  def csrf_entry(entries)
    entry = entries.find { |_severity, message| message.include?("CSRF verification failed 422") }
    assert entry, "expected a CSRF record, got: #{entries.inspect}"
    entry
  end

  def csrf_line(entries)
    csrf_entry(entries).last
  end

  # Captures (severity, message) pairs from every Rails.logger write during the
  # block, including writes from Rack middleware.
  #
  # Broadcasting is what makes the ERROR assertions non-vacuous. Reassigning
  # Rails.logger would not: Rails::Application#env_config memoizes
  # "action_dispatch.logger" at boot, so DebugExceptions — the middleware that logs
  # an unhandled InvalidAuthenticityToken at ERROR — would keep writing to the
  # original logger and the capture would see nothing either way. Attaching a sink
  # to the existing BroadcastLogger object keeps that reference valid.
  def capture_log_entries
    sink = RecordingLogger.new
    Rails.logger.broadcast_to(sink)

    yield

    sink.entries
  ensure
    Rails.logger.stop_broadcasting_to(sink)
  end

  class RecordingLogger < ::Logger
    attr_reader :entries

    def initialize
      super(nil)
      self.level = ::Logger::DEBUG
      @entries = []
    end

    def add(severity, message = nil, progname = nil, &block)
      severity ||= ::Logger::UNKNOWN
      resolved = message || (block ? block.call : progname)
      @entries << [ format_severity(severity), resolved.to_s ]

      super
    end
  end
end
