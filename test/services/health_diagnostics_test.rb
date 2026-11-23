# frozen_string_literal: true

require "test_helper"

class HealthDiagnosticsTest < ActiveSupport::TestCase
  # A report whose sections are given, so a slow or failing one can be put anywhere.
  class FakeService < HealthMonitorService
    def initialize(overrides)
      super()
      @overrides = overrides
      @calls = Concurrent::Array.new
    end

    attr_reader :calls

    SECTIONS.each do |section|
      define_method(section) do
        @calls << section
        override = @overrides[section]
        override ? override.call : { status: HealthStatus.new(status: :healthy, message: "ok"), section: section }
      end
    end
  end

  setup { HealthDiagnostics.release_sections_thread }
  teardown { HealthDiagnostics.release_sections_thread }

  test "carries every section, in the report's own order, when nothing is slow" do
    report = HealthDiagnostics.new.report

    assert_empty report[:unread_sections]
    assert_equal HealthMonitorService::SECTIONS, report.keys.first(HealthMonitorService::SECTIONS.size)
    assert_equal HealthMonitorService::SECTIONS.sort, report[:section_timings_ms].keys.sort
    assert report[:system_health].key?(:worker_stats)
    assert report[:security_health].key?(:window_seconds)
  end

  test "a section that hangs costs the report its budget and no more" do
    hang = Queue.new
    service = FakeService.new(retry_budget_health: -> { hang.pop })

    report, seconds = timed { HealthDiagnostics.new(service: service, budget: 0.5.seconds).report }

    assert_operator seconds, :<, 3
    assert_equal :system_health, report[:system_health][:section]
    assert_equal :security_health, report[:security_health][:section], "read before anything slow"
    assert_includes report[:unread_sections], :retry_budget_health
    assert report[:retry_budget_health][:unread]
    assert_predicate report[:retry_budget_health][:status], :unknown?
  ensure
    hang << nil
    wait_for_release
  end

  test "only one section thread runs at a time, and the queue facts are still read fresh" do
    hang = Queue.new
    slow = FakeService.new(retry_budget_health: -> { hang.pop })
    HealthDiagnostics.new(service: slow, budget: 0.2.seconds).report

    second = FakeService.new({})
    report, seconds = timed { HealthDiagnostics.new(service: second, budget: 5.seconds).report }

    assert_operator seconds, :<, 2
    assert_equal [ :system_health ], second.calls.to_a
    assert_equal :system_health, report[:system_health][:section]
    assert_equal HealthMonitorService::SECTIONS - [ :system_health ], report[:unread_sections].sort_by { |s| HealthMonitorService::SECTIONS.index(s) }

    hang << nil
    wait_for_release
    assert_empty HealthDiagnostics.new(service: FakeService.new({})).report[:unread_sections]
  end

  test "a section that raises is reported as not read and the rest are unaffected" do
    service = FakeService.new(session_health: -> { raise ActiveRecord::StatementInvalid, "host=secret.example" })

    report = HealthDiagnostics.new(service: service).report

    assert_equal [ :session_health ], report[:unread_sections]
    assert_match(/StatementInvalid/, report[:session_health][:error])
    assert_no_match(/secret/, report.to_json)
  end

  test "an unread section is not counted as a passed check" do
    service = FakeService.new(cron_health: -> { raise "boom" })

    status = HealthDiagnostics.new(service: service).report[:overall_status]

    assert_match(/1 could not be evaluated/, status.message)
  end

  test "queue facts that cannot be read fail the report, even if everything else can" do
    service = FakeService.new(system_health: -> { raise ActiveRecord::QueryCanceled, "host=secret.example" })

    error = assert_raises(HealthDiagnostics::Unreadable) { HealthDiagnostics.new(service: service).report }

    assert_match(/system_health could not be read: ActiveRecord::QueryCanceled/, error.message)
    assert_no_match(/secret/, error.message)
    assert_equal [ :system_health ], service.calls.to_a, "nothing is read once the report has failed"
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

    report, seconds = timed { HealthDiagnostics.new(service: service, statement_timeout: 0.2.seconds).report }

    assert_operator seconds, :<, 5
    assert_match(/QueryCanceled/, report[:log_retention_health][:error])
    assert_equal [ :log_retention_health ], report[:unread_sections]
  end

  test "the statement limit does not stay on the connection" do
    before = Session.connection.select_value("SHOW statement_timeout")

    HealthDiagnostics.new.report

    assert_equal before, Session.connection.select_value("SHOW statement_timeout")
  end

  test "the budget plus a statement fits inside the probes' fifteen seconds" do
    assert_operator HealthDiagnostics::BUDGET + HealthDiagnostics::STATEMENT_TIMEOUT, :<, 15.seconds
  end

  private

  def timed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    [ result, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started ]
  end

  # Until the abandoned section thread has finished and given its place up.
  def wait_for_release
    100.times do
      if HealthDiagnostics.claim_sections_thread
        HealthDiagnostics.release_sections_thread
        return
      end
      sleep 0.02
    end
    flunk "the section thread never finished"
  end
end
