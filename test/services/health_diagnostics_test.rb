# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require_relative "../support/health_diagnostics_helpers"

class HealthDiagnosticsTest < ActiveSupport::TestCase
  include HealthDiagnosticsHelpers

  # A report whose sections are given, so a slow or failing one can be put anywhere.
  class FakeService < HealthMonitorService
    def initialize(overrides = {})
      super()
      @overrides = overrides
      @calls = Concurrent::Array.new
    end

    attr_reader :calls

    (SECTIONS - [ :system_health ] + [ :queue_health ]).each do |section|
      define_method(section) do
        @calls << section
        override = @overrides[section]
        override ? override.call : { status: HealthStatus.new(status: :healthy, message: "ok"), section: section }
      end
    end

    def recent_error_logs
      @calls << :recent_error_logs
      @overrides[:recent_error_logs]&.call || []
    end
  end

  SECTIONS = HealthMonitorService::SECTIONS

  teardown { wait_for_sections_thread }

  test "carries every section, in the report's own order, when nothing is slow" do
    report = HealthDiagnostics.new.report

    assert_empty report[:unread_sections]
    assert_equal SECTIONS, report.keys.first(SECTIONS.size)
    assert_equal (SECTIONS + [ :recent_errors ]).sort, report[:section_timings_ms].keys.sort
    assert report[:system_health].key?(:worker_stats)
    assert_kind_of Array, report[:system_health][:recent_errors]
    assert report[:security_health].key?(:window_seconds)
  end

  test "a section that hangs costs the report its budget and no more" do
    hang = Hang.new
    service = FakeService.new(retry_budget_health: hang)

    report, seconds = monotonic_timed { HealthDiagnostics.new(service: service, budget: 1.second).report }

    assert_operator seconds, :<, 4
    assert_equal :queue_health, report[:system_health][:section]
    assert_equal :security_health, report[:security_health][:section], "read before anything slow"
    assert_includes report[:unread_sections], :retry_budget_health
    assert_predicate report[:retry_budget_health][:status], :unknown?
    assert_nil report[:system_health][:recent_errors], "an empty list would say no error was recorded"
  ensure
    hang.release
  end

  test "while a section thread is stuck a second report answers with fresh queue facts and starts no other" do
    hang = Hang.new
    HealthDiagnostics.new(service: FakeService.new(security_health: hang), budget: 0.5.seconds).report
    hang.wait_until_reached

    second = FakeService.new
    report, seconds = monotonic_timed { HealthDiagnostics.new(service: second, budget: 0.5.seconds).report }

    assert_operator seconds, :<, 4
    assert_equal [ :queue_health ], second.calls.to_a
    assert_equal :queue_health, report[:system_health][:section]
    assert_equal (SECTIONS - [ :system_health ] + [ :recent_errors ]).sort, report[:unread_sections].sort

    hang.release
    wait_for_sections_thread
    assert_empty HealthDiagnostics.new(service: FakeService.new).report[:unread_sections]
  ensure
    hang.release
  end

  test "a report that finds another one reading waits for it and loses nothing" do
    hang = Hang.new
    first = Thread.new { HealthDiagnostics.new(service: FakeService.new(security_health: hang)).report }
    hang.wait_until_reached
    releaser = Thread.new { sleep 0.2; hang.release }

    assert_empty HealthDiagnostics.new(service: FakeService.new).report[:unread_sections]
  ensure
    hang.release
    releaser&.join
    first&.join
  end

  test "a slow core comes out of the sections' wait rather than on top of it" do
    hang = Hang.new
    service = FakeService.new(queue_health: -> { sleep 0.6; { status: ok } }, security_health: hang)

    _report, seconds = monotonic_timed do
      HealthDiagnostics.new(service: service, budget: 30.seconds, total: 1.second).report
    end

    assert_operator seconds, :<, 5
  ensure
    hang.release
  end

  test "a section that raises is reported as not read and the rest are unaffected" do
    service = FakeService.new(session_health: -> { raise ActiveRecord::StatementInvalid, "host=secret.example" })

    report = HealthDiagnostics.new(service: service).report

    assert_equal [ :session_health ], report[:unread_sections]
    assert_match(/StatementInvalid/, report[:session_health][:error])
    assert_no_match(/secret/, report.to_json)
  end

  test "a section that raises something other than a StandardError does not cost the heartbeat" do
    service = FakeService.new(session_health: -> { raise NotImplementedError })

    report = HealthDiagnostics.new(service: service).report

    assert_equal [ :session_health ], report[:unread_sections]
    assert_equal :queue_health, report[:system_health][:section]
  end

  test "a section thread that cannot start, or get a connection, does not cost the heartbeat" do
    Thread.stubs(:new).raises(ThreadError)
    report = HealthDiagnostics.new(service: FakeService.new).report
    Thread.unstub(:new)

    assert_equal :queue_health, report[:system_health][:section]
    assert_match(/ThreadError/, report[:cron_health][:error])
    assert_empty HealthDiagnostics.new(service: FakeService.new).report[:unread_sections], "the claim was given up"

    diagnostics = HealthDiagnostics.new(service: FakeService.new)
    diagnostics.stubs(:read_core).returns({ status: ok })
    diagnostics.stubs(:with_statement_timeout).raises(ActiveRecord::ConnectionTimeoutError)
    assert_match(/ConnectionTimeoutError/, diagnostics.report[:cron_health][:error])
  end

  # The sections rescue their own failures into a stand-in for the page to render, which
  # would read here as a fact: no stale cron keys, no post-deploy task pending.
  test "a real section's stand-in for a failed read is never served as an answer" do
    CronFreshness.any_instance.stubs(:report).raises(ActiveRecord::QueryCanceled, "host=secret.example")
    PostDeployTaskRun.stubs(:summary).raises(ActiveRecord::QueryCanceled)
    ClaudeCredentialHealth.stubs(:status).raises(ActiveRecord::QueryCanceled)
    SecurityTelemetry.stubs(:report).raises(Redis::BaseConnectionError)

    report = HealthDiagnostics.new.report

    assert_equal %i[auth_health cron_health post_deploy_task_health security_health], report[:unread_sections].sort
    assert_not report[:cron_health].key?(:counts)
    assert_match(/QueryCanceled/, report[:cron_health][:error])
    assert_no_match(/secret/, report.to_json)
  end

  test "every section that renders a stand-in for a page raises for the probes instead" do
    source = File.readlines(Rails.root.join("app/services/health_monitor_service.rb"), chomp: true)
    rescues = source.each_index.select { |i| source[i].match?(/\A  rescue (StandardError )?=> e\z/) }
    # It answers about a thread in this process, and reads nothing.
    exempt = source.index("  def queue_liveness_watchdog_status")
    missing = rescues.reject do |i|
      source[i + 1].include?("raise if @raise_unreadable") || source[i..i + 6].include?("    raise") ||
        (i > exempt && i < exempt + 10)
    end

    assert_empty missing.map { |i| i + 1 }, "health_monitor_service.rb rescues that hide a failed read"
  end

  test "the stand-ins still render where a page asks for them" do
    CronFreshness.any_instance.stubs(:report).raises(ActiveRecord::QueryCanceled)

    assert_predicate HealthMonitorService.new.cron_health[:status], :warning?
  end

  test "an unread check is not counted as a passed one" do
    service = FakeService.new(cron_health: -> { raise "boom" })

    status = HealthDiagnostics.new(service: service).report[:overall_status]

    assert_predicate status, :unknown?
    assert_match(/1 of 7 checks could not be read/, status.message)
  end

  test "a critical check is still critical beside an unread one" do
    critical = HealthMonitorService::HealthStatus.new(status: :critical, message: "down")
    service = FakeService.new(cron_health: -> { raise "boom" }, queue_health: -> { { status: critical } })

    assert_predicate HealthDiagnostics.new(service: service).report[:overall_status], :critical?
  end

  test "queue facts that cannot be read fail the report, even if everything else can" do
    service = FakeService.new(queue_health: -> { raise ActiveRecord::QueryCanceled, "host=secret.example" })

    error = assert_raises(HealthDiagnostics::Unreadable) { HealthDiagnostics.new(service: service).report }

    assert_match(/system_health could not be read: ActiveRecord::QueryCanceled/, error.message)
    assert_no_match(/secret/, error.message)
    assert_equal [ :queue_health ], service.calls.to_a, "nothing is read once the report has failed"
  end

  test "a stale worker heartbeat is reported as stale" do
    GoodJob::Process.create!(id: SecureRandom.uuid, state: { "hostname" => "stopped-worker" }, updated_at: 1.hour.ago)

    details = HealthDiagnostics.new.report.dig(:system_health, :worker_stats, :worker_details)

    worker = details.find { |row| row[:hostname] == "stopped-worker" }
    assert_operator worker[:seconds_since_heartbeat], :>=, 3600
  end

  test "a statement past the limit is cancelled in the database" do
    # A savepoint, because a cancelled statement would otherwise abort the test's transaction.
    sleeping = -> { Session.transaction(requires_new: true) { Session.connection.execute("SELECT pg_sleep(20)") } }
    service = FakeService.new(log_retention_health: sleeping)

    report, seconds = monotonic_timed { HealthDiagnostics.new(service: service, statement_timeout: 0.5.seconds).report }

    assert_operator seconds, :<, 5
    assert_match(/QueryCanceled/, report[:log_retention_health][:error])
    assert_equal [ :log_retention_health ], report[:unread_sections]
  end

  test "the statement limit does not stay on the connection" do
    before = Session.connection.select_value("SHOW statement_timeout")

    HealthDiagnostics.new.report

    assert_equal before, Session.connection.select_value("SHOW statement_timeout")
  end

  test "a failed retry-budget scan is not repeated by the sections that share it" do
    RetryBudget::Usage.expects(:new).once.raises(ActiveRecord::QueryCanceled)

    report = HealthDiagnostics.new.report

    assert_equal %i[api_error_retry_health retry_budget_health sigterm_retry_health], report[:unread_sections].sort
  end

  test "recent errors that cannot be read are named and cost nothing else" do
    service = FakeService.new(recent_error_logs: -> { raise ActiveRecord::QueryCanceled })

    report = HealthDiagnostics.new(service: service).report

    assert_equal [ :recent_errors ], report[:unread_sections]
    assert_nil report[:system_health][:recent_errors]
  end

  test "the wait ends inside the probes' fifteen seconds" do
    assert_operator HealthDiagnostics::TOTAL, :<, 15.seconds
    assert_operator HealthDiagnostics::BUDGET + HealthDiagnostics::STATEMENT_TIMEOUT, :<=, HealthDiagnostics::TOTAL
  end

  private

  def ok
    HealthMonitorService::HealthStatus.new(status: :healthy, message: "ok")
  end
end
