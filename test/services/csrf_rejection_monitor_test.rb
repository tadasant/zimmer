require "test_helper"

# Issue #23. The class's whole job is to separate "one CSRF rejection" (a stale
# form, a probe) from "a rate of them" (#19 — a proxy misreporting scheme or host,
# so every write in the UI fails for every real user), and to make only the second
# reach GlitchTip.
#
# Rails.cache is a :null_store in the test env, which is one of the two "no counter"
# states this class must fail silently on — so most cases here swap in a real
# MemoryStore. The null-store case is asserted explicitly rather than relied on.
class CsrfRejectionMonitorTest < ActiveSupport::TestCase
  EXCEPTION_MESSAGE = "Can't verify CSRF token authenticity.".freeze

  # Buckets are wall-clock, so every case runs on a frozen clock parked mid-bucket.
  # Unfrozen, a burst that happened to straddle a five-minute boundary would split
  # across two buckets and the counts below would flake.
  MID_BUCKET = Time.utc(2026, 9, 10, 12, 2, 30)

  setup do
    @reports = []
    travel_to MID_BUCKET
  end

  teardown do
    travel_back
  end

  # A stand-in for ActionDispatch::Request carrying only what the monitor reads.
  FakeRequest = Struct.new(:request_method, :path, :user_agent)

  def request(method: "POST", path: "/triggers/1/toggle", user_agent: "Mozilla/5.0")
    FakeRequest.new(method, path, user_agent)
  end

  def exception(message = EXCEPTION_MESSAGE)
    ActionController::InvalidAuthenticityToken.new(message)
  end

  # Captures what would have gone to GlitchTip without initializing the SDK.
  # ErrorReporter is the seam the monitor reports through; test/initializers/
  # sentry_test.rb covers the other side of it against the real configuration.
  def capturing_reports(&block)
    ErrorReporter.stub(:report_exception, ->(exc, context: {}, level: :error, fingerprint: nil) {
      @reports << { exception: exc, context: context, level: level, fingerprint: fingerprint }
    }, &block)
  end

  def with_memory_cache(&block)
    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new, &block)
  end

  def record(**kwargs)
    CsrfRejectionMonitor.record(
      kwargs[:exception] || exception,
      request: kwargs[:request] || request,
      session_cookie_present: kwargs.fetch(:session_cookie_present, false)
    )
  end

  test "a single rejection reports nothing" do
    with_memory_cache do
      capturing_reports do
        assert_equal :below_threshold, record
      end
    end

    assert_empty @reports, "one CSRF failure is a stale form or a bot, not a page"
  end

  test "rejections below the threshold report nothing" do
    with_memory_cache do
      capturing_reports do
        results = (CsrfRejectionMonitor::THRESHOLD - 1).times.map { record }
        assert_equal [ :below_threshold ], results.uniq
      end
    end

    assert_empty @reports
  end

  test "the rejection that reaches the threshold reports exactly once" do
    with_memory_cache do
      capturing_reports do
        results = CsrfRejectionMonitor::THRESHOLD.times.map { record }
        assert_equal [ :below_threshold ] * (CsrfRejectionMonitor::THRESHOLD - 1) + [ :reported ], results
      end
    end

    assert_equal 1, @reports.size
  end

  test "a storm costs one report per window, however loud it gets" do
    with_memory_cache do
      capturing_reports do
        results = (CsrfRejectionMonitor::THRESHOLD * 20).times.map { record }
        assert_equal 1, results.count(:reported)
        assert_equal CsrfRejectionMonitor::THRESHOLD * 20 - CsrfRejectionMonitor::THRESHOLD,
          results.count(:already_reported)
      end
    end

    assert_equal 1, @reports.size,
      "un-excluding the class must not turn a storm into a hundred GlitchTip events"
  end

  test "a later window reports again — the storm is still happening" do
    with_memory_cache do
      capturing_reports do
        CsrfRejectionMonitor::THRESHOLD.times { record }

        travel CsrfRejectionMonitor::WINDOW
        results = CsrfRejectionMonitor::THRESHOLD.times.map { record }
        assert_equal 1, results.count(:reported)
      end
    end

    assert_equal 2, @reports.size,
      "a storm that outlives one bucket must keep saying so, once per bucket"
  end

  test "the report carries the count and the fields that separate a probe from a broken proxy" do
    with_memory_cache do
      capturing_reports do
        (CsrfRejectionMonitor::THRESHOLD - 1).times { record }
        record(
          request: request(method: "PATCH", path: "/notifications/7/mark_read", user_agent: "curl/8.7.1"),
          session_cookie_present: true,
          exception: exception("HTTP Origin header (https://evil.test) didn't match request.base_url (https://zimmer.test)")
        )
      end
    end

    report = @reports.sole
    assert_kind_of ActionController::InvalidAuthenticityToken, report[:exception]
    assert_equal [ "csrf-rejection-rate" ], report[:fingerprint],
      "the rate signal gets its own GlitchTip issue, apart from per-request CSRF events"
    context = report[:context]
    assert_equal CsrfRejectionMonitor::THRESHOLD, context[:csrf_rejections_in_window]
    assert_equal CsrfRejectionMonitor::WINDOW.to_i, context[:window_seconds]
    assert_equal CsrfRejectionMonitor::THRESHOLD, context[:threshold]
    assert_equal "PATCH", context[:request_method]
    assert_equal "/notifications/7/mark_read", context[:path]
    assert_equal "present", context[:session_cookie]
    assert_equal "curl/8.7.1", context[:user_agent]
    # The Origin-mismatch reason is what distinguishes a server fault from a stale token.
    assert_match(/didn't match request.base_url/, context[:reason])
  end

  # send_default_pii = false is a deliberate decision in config/initializers/sentry.rb.
  # The per-record INFO line still carries the IP for whoever needs it.
  test "the report carries no IP address" do
    with_memory_cache do
      capturing_reports { CsrfRejectionMonitor::THRESHOLD.times { record } }
    end

    refute_includes @reports.sole[:context].keys, :ip
    refute_includes @reports.sole[:context].keys, :remote_ip
  end

  test "crossing the threshold emits exactly one WARN naming the rate" do
    entries = nil

    with_memory_cache do
      capturing_reports do
        entries = capture_log_entries do
          (CsrfRejectionMonitor::THRESHOLD * 3).times { record }
        end
      end
    end

    warns = entries.select { |severity, message| severity == "WARN" && message.include?("CSRF rejection rate exceeded") }
    assert_equal 1, warns.size, "one WARN per window, not one per rejection: #{entries.inspect}"
    assert_includes warns.first.last, "#{CsrfRejectionMonitor::THRESHOLD} in #{CsrfRejectionMonitor::WINDOW.to_i}s"
    assert_includes warns.first.last, "session_cookie=absent"
  end

  # Redis is configured with an error_handler that swallows, so a dead Redis makes
  # `increment` return nil rather than raise. So does the test env's :null_store.
  # Both must mean "no counter, no report" — never "report every rejection", which
  # is an unbounded flood into the alert path.
  test "an unusable cache store reports nothing rather than reporting everything" do
    capturing_reports do
      results = (CsrfRejectionMonitor::THRESHOLD * 5).times.map { record }
      assert_equal [ :not_counted ], results.uniq
    end

    assert_empty @reports
  end

  test "a raising cache store is swallowed so the 422 still renders" do
    exploding = Object.new
    def exploding.increment(*) = raise("redis is on fire")

    Rails.stub(:cache, exploding) do
      capturing_reports do
        assert_equal :not_counted, record
      end
    end

    assert_empty @reports
  end

  test "a raising reporter is swallowed too" do
    with_memory_cache do
      ErrorReporter.stub(:report_exception, ->(*, **) { raise "glitchtip is unreachable" }) do
        results = CsrfRejectionMonitor::THRESHOLD.times.map { record }
        assert_equal :not_counted, results.last, "the caller still owes the client a 422"
      end
    end
  end
end
