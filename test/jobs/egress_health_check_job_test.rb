# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class EgressHealthCheckJobTest < ActiveJob::TestCase
  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache.delete(EgressHealthCheck::CACHE_KEY)
    # Stub the GlitchTip seam off by default so no test depends on it; the paging
    # test sets its own expectation.
    ErrorReporter.stubs(:report_message)
  end

  teardown do
    Rails.cache = @original_cache
  end

  # A real prober wired to a fake DNS boundary via the injectable probe lambda —
  # dependency injection, NOT stubbing our own code. The job takes `check:`, so
  # the test drives the real record/cache path and only fakes the network edge.
  def check(healthy:)
    EgressHealthCheck.new(resolver: "r", hosts: [ "api.anthropic.com" ], probe: ->(_host, _resolver) { healthy })
  end

  test "persists a healthy status when the resolver works" do
    EgressHealthCheckJob.perform_now(check: check(healthy: true))
    assert_equal "ok", EgressHealthCheck.status["status"]
    assert_not EgressHealthCheck.degraded?
  end

  test "raises the banner only after sustained failures (hysteresis)" do
    EgressHealthCheckJob.perform_now(check: check(healthy: false))
    assert_not EgressHealthCheck.degraded?, "a single failing tick must not raise the banner"

    EgressHealthCheckJob.perform_now(check: check(healthy: false))
    assert EgressHealthCheck.degraded?, "sustained failure raises the banner"
    assert_equal "primary resolver r could not resolve api.anthropic.com",
      EgressHealthCheck.status["detail"]
  end

  test "clears the banner once egress recovers" do
    2.times { EgressHealthCheckJob.perform_now(check: check(healthy: false)) }
    assert EgressHealthCheck.degraded?

    EgressHealthCheckJob.perform_now(check: check(healthy: true))
    assert_not EgressHealthCheck.degraded?
  end

  test "pages once on the healthy->degraded transition, then stays quiet" do
    ErrorReporter.unstub(:report_message)
    # Exactly one page across all three ticks: none on streak 1, one when the
    # threshold is crossed, none on the steady-state degraded tick.
    ErrorReporter.expects(:report_message).once.with do |message, opts|
      message == "Network egress degraded" &&
        opts[:level] == :error &&
        opts[:context][:source] == "EgressHealthCheckJob"
    end

    EgressHealthCheckJob.perform_now(check: check(healthy: false)) # streak 1 -> ok
    EgressHealthCheckJob.perform_now(check: check(healthy: false)) # streak 2 -> degraded (pages)
    EgressHealthCheckJob.perform_now(check: check(healthy: false)) # still degraded (no page)
  end

  test "logs at ERROR exactly once on the transition into degraded, not every tick" do
    EgressHealthCheckJob.perform_now(check: check(healthy: false)) # streak 1, still ok

    entries = capture_log_entries do
      EgressHealthCheckJob.perform_now(check: check(healthy: false)) # streak 2 -> degraded (pages)
      EgressHealthCheckJob.perform_now(check: check(healthy: false)) # still degraded (stays quiet)
    end

    degraded = entries.select { |severity, message| severity == "ERROR" && message.include?("network egress degraded") }
    assert_equal 1, degraded.size,
      "the ERROR record is the page: one on the healthy->degraded transition, none on later degraded ticks"
  end
end
