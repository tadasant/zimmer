# frozen_string_literal: true

require "test_helper"
require "stringio"

class CertExpiryMonitorJobTest < ActiveSupport::TestCase
  # A checker stub that returns canned Results keyed by host and records which
  # hosts it was asked about (so we never touch the network in tests).
  class FakeChecker
    attr_reader :checked_hosts

    def initialize(results)
      @results = results
      @checked_hosts = []
    end

    def check(host, port: 443)
      @checked_hosts << host
      @results.fetch(host) { healthy_result(host) }
    end

    private

    def healthy_result(host)
      CertExpiryChecker::Result.new(host: host, port: 443, not_after: Time.now.utc + (60 * 86_400), days_remaining: 60, error: nil)
    end
  end

  setup do
    @log_io = StringIO.new
    @original_logger = Rails.logger
    logger = ActiveSupport::Logger.new(@log_io)
    # ActiveSupport's default SimpleFormatter emits only the message body, so the
    # severity label (WARN/ERROR) would be absent from the capture. Prepend it so
    # the level assertions below actually verify the log level we emitted.
    logger.formatter = proc { |severity, _time, _progname, msg| "#{severity} #{msg}\n" }
    Rails.logger = logger
  end

  teardown do
    Rails.logger = @original_logger
  end

  def ok_result(host, days)
    CertExpiryChecker::Result.new(
      host: host, port: 443,
      not_after: Time.now.utc + (days * 86_400),
      days_remaining: days, error: nil
    )
  end

  def error_result(host)
    CertExpiryChecker::Result.new(host: host, port: 443, not_after: nil, days_remaining: nil, error: "Errno::ECONNREFUSED: refused")
  end

  # Capture calls to ErrorReporter (the GlitchTip alert seam). StructuredLogger#error
  # routes through ErrorReporter.report_message, so a non-empty capture means the
  # job paged.
  def capture_alerts
    messages = []
    ErrorReporter.stub(:report_message, ->(message, context: {}) { messages << { message: message, context: context } }) do
      ErrorReporter.stub(:report_exception, ->(*, **) { messages << { exception: true } }) do
        yield messages
      end
    end
  end

  test "pages (error + GlitchTip) when a cert expires within the error threshold" do
    checker = FakeChecker.new("zimmer.example.com" => ok_result("zimmer.example.com", 10))

    capture_alerts do |alerts|
      CertExpiryMonitorJob.perform_now(hosts: [ "zimmer.example.com" ], checker: checker)
      assert_equal 1, alerts.size, "expected exactly one GlitchTip alert"
      assert_equal 10, alerts.first[:context][:days_remaining]
      assert_match(/ao\.pulsemcp\.com/, alerts.first[:context][:host].to_s)
    end

    assert_match(/ERROR/, @log_io.string)
    assert_match(/expires in 10 day/i, @log_io.string)
  end

  test "error threshold is inclusive at 14 days" do
    checker = FakeChecker.new("zimmer.example.com" => ok_result("zimmer.example.com", 14))

    capture_alerts do |alerts|
      CertExpiryMonitorJob.perform_now(hosts: [ "zimmer.example.com" ], checker: checker)
      assert_equal 1, alerts.size, "14 days should still page"
    end
  end

  test "warns (no page) in the 15-21 day band" do
    checker = FakeChecker.new("zimmer.example.com" => ok_result("zimmer.example.com", 18))

    capture_alerts do |alerts|
      CertExpiryMonitorJob.perform_now(hosts: [ "zimmer.example.com" ], checker: checker)
      assert_empty alerts, "warn band must not page GlitchTip"
    end

    assert_match(/WARN/, @log_io.string)
    assert_match(/expires in 18 day/i, @log_io.string)
  end

  test "warn threshold is inclusive at 21 days" do
    checker = FakeChecker.new("zimmer.example.com" => ok_result("zimmer.example.com", 21))

    capture_alerts do |alerts|
      CertExpiryMonitorJob.perform_now(hosts: [ "zimmer.example.com" ], checker: checker)
      assert_empty alerts
    end

    assert_match(/WARN/, @log_io.string)
  end

  test "logs info (no page) for a healthy cert beyond the warn threshold" do
    checker = FakeChecker.new("zimmer.example.com" => ok_result("zimmer.example.com", 60))

    capture_alerts do |alerts|
      CertExpiryMonitorJob.perform_now(hosts: [ "zimmer.example.com" ], checker: checker)
      assert_empty alerts
    end

    assert_match(/healthy/i, @log_io.string)
    refute_match(/ERROR/, @log_io.string)
  end

  test "warns (no page) when a host cannot be inspected" do
    checker = FakeChecker.new("zimmer.example.com" => error_result("zimmer.example.com"))

    capture_alerts do |alerts|
      CertExpiryMonitorJob.perform_now(hosts: [ "zimmer.example.com" ], checker: checker)
      assert_empty alerts, "an unreachable host should not page — it may be transient"
    end

    assert_match(/WARN/, @log_io.string)
    assert_match(/Could not inspect/i, @log_io.string)
  end

  test "checks every host independently and keeps going after a bad one" do
    checker = FakeChecker.new(
      "good.example.com" => ok_result("good.example.com", 60),
      "expiring.example.com" => ok_result("expiring.example.com", 5),
      "down.example.com" => error_result("down.example.com")
    )

    capture_alerts do |alerts|
      CertExpiryMonitorJob.perform_now(
        hosts: [ "good.example.com", "expiring.example.com", "down.example.com" ],
        checker: checker
      )
      assert_equal 1, alerts.size, "only the expiring host should page"
      assert_equal "expiring.example.com", alerts.first[:context][:host]
    end

    assert_equal [ "good.example.com", "expiring.example.com", "down.example.com" ], checker.checked_hosts
  end

  # Temporarily set ENV vars for the duration of the block, restoring prior values
  # (including absence) afterward — keeps host-selection tests hermetic.
  def with_env(vars)
    originals = vars.keys.to_h { |k| [ k, ENV[k] ] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    originals.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  test "defaults to DEFAULT_HOSTS when no hosts are given and APP_HOST is unset" do
    checker = FakeChecker.new({})

    with_env("CERT_EXPIRY_MONITOR_HOSTS" => nil, "APP_HOST" => nil) do
      capture_alerts do |_alerts|
        CertExpiryMonitorJob.perform_now(checker: checker)
      end
    end

    assert_equal CertExpiryMonitorJob::DEFAULT_HOSTS, checker.checked_hosts
  end

  test "drops this environment's own APP_HOST from the default set (hairpin-unreachable)" do
    checker = FakeChecker.new({})

    with_env("CERT_EXPIRY_MONITOR_HOSTS" => nil, "APP_HOST" => "staging.zimmer.example.com") do
      capture_alerts do |_alerts|
        CertExpiryMonitorJob.perform_now(checker: checker)
      end
    end

    refute_includes checker.checked_hosts, "staging.zimmer.example.com",
      "the worker cannot reach its own host's tailscale origin, so it must skip it"
    # The peer AO host and the public obs hosts are still watched.
    assert_includes checker.checked_hosts, "zimmer.example.com"
    assert_includes checker.checked_hosts, "obs.example.com"
  end

  test "matches APP_HOST against the host list ignoring port and case" do
    checker = FakeChecker.new({})

    # APP_HOST carrying a port and mixed case must still drop the bare lowercase
    # host from the default set — otherwise the environment self-monitors.
    with_env("CERT_EXPIRY_MONITOR_HOSTS" => nil, "APP_HOST" => "zimmer.example.com:443") do
      capture_alerts do |_alerts|
        CertExpiryMonitorJob.perform_now(checker: checker)
      end
    end

    refute_includes checker.checked_hosts, "staging.zimmer.example.com"
    assert_includes checker.checked_hosts, "zimmer.example.com"
  end

  test "honors the CERT_EXPIRY_MONITOR_HOSTS env override" do
    checker = FakeChecker.new({})

    with_env("CERT_EXPIRY_MONITOR_HOSTS" => "a.example.com, b.example.com", "APP_HOST" => nil) do
      capture_alerts do |_alerts|
        CertExpiryMonitorJob.perform_now(checker: checker)
      end
    end

    assert_equal [ "a.example.com", "b.example.com" ], checker.checked_hosts
  end

  test "the env override also drops the environment's own APP_HOST" do
    checker = FakeChecker.new({})

    with_env("CERT_EXPIRY_MONITOR_HOSTS" => "self.example.com, peer.example.com", "APP_HOST" => "self.example.com") do
      capture_alerts do |_alerts|
        CertExpiryMonitorJob.perform_now(checker: checker)
      end
    end

    assert_equal [ "peer.example.com" ], checker.checked_hosts
  end

  test "is enqueued on the default queue" do
    assert_equal "default", CertExpiryMonitorJob.new.queue_name
  end
end
