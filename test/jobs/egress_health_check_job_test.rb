# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class EgressHealthCheckJobTest < ActiveJob::TestCase
  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache.delete(EgressHealthCheck::CACHE_KEY)
    # AlertService posts to Slack (an external boundary) — stub it off by default
    # so tests never reach out; the paging test sets its own expectation.
    AlertService.stubs(:raise_alert)
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

  test "pages #eng-alerts once on the healthy->degraded transition, then stays quiet" do
    AlertService.unstub(:raise_alert)
    # Exactly one page across all three ticks: none on streak 1, one when the
    # threshold is crossed, none on the steady-state degraded tick.
    AlertService.expects(:raise_alert).once.with do |title, opts|
      title == "Network egress degraded" && opts[:dedup_key] == EgressHealthCheckJob::ALERT_DEDUP_KEY
    end

    EgressHealthCheckJob.perform_now(check: check(healthy: false)) # streak 1 -> ok
    EgressHealthCheckJob.perform_now(check: check(healthy: false)) # streak 2 -> degraded (pages)
    EgressHealthCheckJob.perform_now(check: check(healthy: false)) # still degraded (no page)
  end

  test "warns exactly once on the transition into degraded, not every tick" do
    EgressHealthCheckJob.perform_now(check: check(healthy: false)) # streak 1, still ok

    io = StringIO.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    begin
      EgressHealthCheckJob.perform_now(check: check(healthy: false)) # streak 2 -> degraded (warns once)
      EgressHealthCheckJob.perform_now(check: check(healthy: false)) # still degraded (stays quiet)
    ensure
      Rails.logger = original_logger
    end

    assert_equal 1, io.string.scan(/network egress degraded/).size,
      "must warn once on the healthy->degraded transition, not on every degraded tick"
  end
end
