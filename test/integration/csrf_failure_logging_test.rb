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

    # Rails logs its own `rescue_from handled ActionController::InvalidAuthenticityToken
    # (…) - <one frame>` line whenever a handler fires. That is fine — it is INFO, it is
    # one frame rather than sixty, and the alert counts ERROR records. What must never
    # appear is the exception at a severity the alert can see.
    exception_mentions = entries.select { |_severity, message| message.include?("InvalidAuthenticityToken") }
    assert exception_mentions.all? { |severity, _message| severity == "INFO" },
      "the exception may only be mentioned at INFO: #{exception_mentions.inspect}"
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
    # This is the one example whose subject is the middleware rather than the
    # controller, so it is the one that depends on capture_log_entries reaching
    # DebugExceptions. DebugExceptions logs to env_config["action_dispatch.logger"];
    # the sink is attached to Rails.logger. State that they are the same object rather
    # than assuming it — a regression should name the broken invariant instead of
    # surfacing as an inexplicably absent ERROR record, which is how #337 presented.
    assert_same Rails.logger, Rails.application.env_config["action_dispatch.logger"],
      "the capture harness cannot observe DebugExceptions unless these are one logger: " \
      "either test_helper.rb's env_config pin is gone, or an earlier example assigned " \
      "Rails.logger and did not restore it"

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

  # --- issue #23: the rate, not the record ------------------------------------------
  #
  # The INFO line above is per-record and never leaves the container. What #19 needed
  # was for a *sustained* rate to reach the one pipeline that carries the URL, the verb
  # and the user agent — and sentry-rails excludes InvalidAuthenticityToken by default,
  # so GlitchTip saw none of the hours in which every write in the UI failed.
  # config/initializers/sentry.rb removes that exclusion; CsrfRejectionMonitor is what
  # keeps the un-excluded class from becoming a flood. These cases pin the controller
  # end of that wiring: the real handler, the real request, the real monitor.

  test "a storm of tokenless writes produces one report, and every request still gets its 422" do
    reports = []
    burst = CsrfRejectionMonitor::THRESHOLD * 3

    with_memory_cache_mid_bucket do
      capturing_reports(reports) do
        burst.times do
          patch mark_read_notification_path(notifications(:default_notification))
          assert_response :unprocessable_entity
        end
      end
    end

    assert_equal 1, reports.size,
      "#{burst} rejections must cost one GlitchTip event, not #{burst}"
    assert_kind_of ActionController::InvalidAuthenticityToken, reports.sole[:exception]
    assert_equal CsrfRejectionMonitor::THRESHOLD, reports.sole[:context][:csrf_rejections_in_window]
    assert_equal "PATCH", reports.sole[:context][:request_method]
    assert_equal mark_read_notification_path(notifications(:default_notification)),
      reports.sole[:context][:path]
  end

  test "a quiet trickle of rejections still reports nothing" do
    reports = []

    with_memory_cache_mid_bucket do
      capturing_reports(reports) do
        (CsrfRejectionMonitor::THRESHOLD - 1).times do
          post toggle_trigger_path(triggers(:enabled_slack_trigger))
          assert_response :unprocessable_entity
        end
      end
    end

    assert_empty reports, "a stale form and a bot must stay as quiet as they were before #23"
  end

  test "the storm's WARN sits alongside the per-record INFO lines, once" do
    entries = nil

    with_memory_cache_mid_bucket do
      capturing_reports([]) do
        entries = capture_log_entries do
          CsrfRejectionMonitor::THRESHOLD.times do
            patch mark_read_notification_path(notifications(:default_notification))
          end
        end
      end
    end

    infos = entries.select { |_severity, message| message.include?("CSRF verification failed 422") }
    assert_equal CsrfRejectionMonitor::THRESHOLD, infos.size, "the per-record line is unchanged"
    assert_equal [ "INFO" ], infos.map(&:first).uniq

    warns = entries.select { |_severity, message| message.include?("CSRF rejection rate exceeded") }
    assert_equal 1, warns.size
    assert_equal "WARN", warns.first.first,
      "WARN so it reaches VictoriaLogs; the production rule counts ERROR, so it must not page twice"

    assert_empty entries.select { |severity, _message| %w[ERROR FATAL].include?(severity) },
      "the rate report must not reintroduce the ERROR record #295 removed: #{entries.inspect}"
  end

  # The rate monitor sits inside the handler that renders the 422. A cache store that
  # raises (rather than the swallowing one production configures) must cost the report,
  # never the response — a monitoring bug that turned a client error into a 500 would
  # page for the wrong reason and hide the storm underneath it.
  test "a cache store that raises costs the report, not the response" do
    exploding = Object.new
    def exploding.increment(*) = raise("redis is on fire")

    entries = Rails.stub(:cache, exploding) do
      capture_log_entries do
        patch mark_read_notification_path(notifications(:default_notification))
      end
    end

    assert_response :unprocessable_entity
    assert_includes csrf_line(entries), "PATCH", "the per-record INFO line survives too"
  end

  private

  # The monitor's buckets are wall-clock five-minute windows, so a burst that
  # happened to straddle a boundary would split across two buckets. Parking the clock
  # mid-bucket makes the counts deterministic.
  def with_memory_cache_mid_bucket(&block)
    travel_to Time.utc(2026, 9, 10, 12, 2, 30) do
      Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new, &block)
    end
  end

  def capturing_reports(sink, &block)
    ErrorReporter.stub(:report_exception, ->(exc, context: {}, level: :error, fingerprint: nil) {
      sink << { exception: exc, context: context, level: level, fingerprint: fingerprint }
    }, &block)
  end

  # rescue_handlers is a class_attribute, so assigning here defines the value on
  # ApplicationController and every descendant reading through it, and restoring it
  # afterwards fully reverts. parallelize() forks processes and examples within a
  # worker run sequentially, so the window is closed before any other example runs.
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

  # capture_log_entries is LogCaptureHelpers (test/support/log_capture_helpers.rb).
  # It broadcasts to a sink instead of assigning Rails.logger, which is what makes the
  # ERROR assertions here able to see ActionDispatch::DebugExceptions at all.
end
