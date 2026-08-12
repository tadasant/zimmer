# frozen_string_literal: true

require "test_helper"

class MangledCloneReportJobTest < ActiveJob::TestCase
  # Collects what the job actually wrote, per level. `Logger#warn("text")` passes
  # the string as `progname`, not `message`, so all three arrival shapes are
  # normalized here — otherwise every assertion below would read an empty string.
  class CollectingLogger < ActiveSupport::Logger
    attr_reader :lines

    def initialize
      @lines = []
      super(File::NULL)
    end

    def add(severity, message = nil, progname = nil, &block)
      content = message || (block && block.call) || progname
      @lines << { severity: severity, message: content.to_s }
      true
    end
  end

  setup do
    # No fixture carries a mangled-clone marker, so every session these tests
    # count is one they stamped themselves.
    @session = sessions(:running)
    @other = sessions(:archived)
  end

  def capture_logs
    original = Rails.logger
    collector = CollectingLogger.new
    Rails.logger = collector
    yield
    collector.lines
  ensure
    Rails.logger = original
  end

  # Only this job's own lines. ActiveJob narrates every perform_now at INFO, and
  # an unrelated deprecation can land at WARN, so an unfiltered count would be
  # asserting on the framework rather than on the report.
  def lines_at(lines, severity)
    lines.select { |l| l[:severity] == severity && l[:message].include?("[MangledCloneReportJob]") }
         .map { |l| l[:message] }
  end

  # update_columns, not update!: these fixtures are being used as carriers for a
  # metadata marker, and a validation unrelated to this job should not decide
  # whether it can be tested.
  def mark_defused(session, dropped:, at: Time.current)
    session.update_columns(
      metadata: (session.metadata || {}).merge(
        MangledCloneReportJob::DROPPED_DELETIONS_KEY => dropped,
        MangledCloneReportJob::DEFUSED_AT_KEY => at.utc.iso8601
      )
    )
  end

  test "runs on the dedicated pollers queue (not default)" do
    assert_equal "pollers", MangledCloneReportJob.new.queue_name
  end

  test "is a singleton so two runs cannot double-report the same window" do
    config = MangledCloneReportJob.good_job_concurrency_config
    assert_equal 1, config[:total_limit]
    assert_equal "mangled_clone_report", MangledCloneReportJob.new.good_job_concurrency_key
  end

  test "reports the count and the deletions dropped at warn, not error" do
    mark_defused(@session, dropped: 854)
    mark_defused(@other, dropped: 295)

    lines = capture_logs { MangledCloneReportJob.perform_now }

    warnings = lines_at(lines, Logger::WARN)
    assert_equal 1, warnings.size, "one aggregate line per run, not one per clone"
    assert_includes warnings.first, "for 2 session(s)"
    assert_includes warnings.first, "dropping 1149 tracked-file deletion(s)"
    assert_includes warnings.first, @session.id.to_s
    assert_includes warnings.first, @other.id.to_s
    assert_includes warnings.first, "zimmer#412"

    assert_empty lines_at(lines, Logger::ERROR),
      "the aggregate must never page — pageability is exactly what #415 removed"
  end

  test "ignores defusals older than the report window so consecutive runs do not double-count" do
    mark_defused(@session, dropped: 500, at: MangledCloneReportJob::REPORT_WINDOW.ago - 1.hour)

    lines = capture_logs { MangledCloneReportJob.perform_now }

    assert_empty lines_at(lines, Logger::WARN)
    assert_includes lines_at(lines, Logger::INFO).join("\n"), "No mangled clones defused"
  end

  test "stays quiet in VictoriaLogs on a clean day" do
    lines = capture_logs { MangledCloneReportJob.perform_now }

    assert_empty lines_at(lines, Logger::WARN)
    assert_empty lines_at(lines, Logger::ERROR)
    assert_includes lines_at(lines, Logger::INFO).join("\n"), "No mangled clones defused"
  end

  # metadata is a free-form column with a dozen writers. Comparing the stamp as a
  # string rather than casting it to timestamptz is what keeps one stray value
  # from raising PG::InvalidDatetimeFormat and taking the whole report down.
  test "a malformed marker cannot take the report down" do
    @session.update_columns(
      metadata: (@session.metadata || {}).merge(
        MangledCloneReportJob::DEFUSED_AT_KEY => "not a timestamp",
        MangledCloneReportJob::DROPPED_DELETIONS_KEY => "not a number"
      )
    )
    mark_defused(@other, dropped: 60)

    lines = nil
    assert_nothing_raised { lines = capture_logs { MangledCloneReportJob.perform_now } }

    assert_includes lines_at(lines, Logger::WARN).first, "dropping 60 tracked-file deletion(s)",
      "a junk count reads as zero rather than corrupting the total"
  end

  test "truncates the session list but still reports the true total" do
    mark_defused(@session, dropped: 100)
    mark_defused(@other, dropped: 100)
    mark_defused(sessions(:failed), dropped: 100)

    lines = with_session_id_display_limit(1) do
      capture_logs { MangledCloneReportJob.perform_now }
    end

    warning = lines_at(lines, Logger::WARN).first
    assert_includes warning, "for 3 session(s)"
    assert_includes warning, "(+2 more)",
      "a bad day can mangle dozens of clones; the line stays readable and still states the total"
  end

  private

  def with_session_id_display_limit(limit)
    original = MangledCloneReportJob::SESSION_ID_DISPLAY_LIMIT
    silence_warnings { MangledCloneReportJob.const_set(:SESSION_ID_DISPLAY_LIMIT, limit) }
    yield
  ensure
    silence_warnings { MangledCloneReportJob.const_set(:SESSION_ID_DISPLAY_LIMIT, original) }
  end
end
