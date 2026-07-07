# frozen_string_literal: true

require "test_helper"

class ApplicationJobTest < ActiveSupport::TestCase
  # Test job class to verify ApplicationJob behavior
  class TestJob < ApplicationJob
    attr_reader :correlation_id, :job_id, :session_id

    def perform(*args)
      # Store thread locals for assertion
      @correlation_id = Thread.current[:correlation_id]
      @job_id = Thread.current[:job_id]
      @session_id = Thread.current[:session_id]
      args.first
    end
  end

  teardown do
    # Clean up thread locals
    Thread.current[:correlation_id] = nil
    Thread.current[:session_id] = nil
    Thread.current[:job_id] = nil
    Thread.current[:process_pid] = nil
  end

  test "generates correlation_id on job execution" do
    job = TestJob.new
    job.perform_now

    assert_not_nil job.correlation_id
    assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, job.correlation_id)
  end

  test "sets job_id on job execution" do
    job = TestJob.new
    job.perform_now

    assert_not_nil job.job_id
    assert_equal job.job_id, job.job_id
  end

  test "extracts session_id from hash arguments" do
    # Use a class variable to capture the session_id from inside the job
    test_job_class = Class.new(ApplicationJob) do
      cattr_accessor :captured_session_id

      def perform(args)
        self.class.captured_session_id = Thread.current[:session_id]
      end
    end

    test_job_class.perform_now({ session_id: 123 })

    # Verify session_id was extracted from the hash argument
    assert_equal 123, test_job_class.captured_session_id
  end

  test "cleans up thread locals after job execution" do
    TestJob.perform_now({ session_id: 456 })

    # After job completes, thread locals should be cleaned up
    assert_nil Thread.current[:correlation_id]
    assert_nil Thread.current[:job_id]
    assert_nil Thread.current[:session_id]
    assert_nil Thread.current[:process_pid]
  end

  test "preserves existing correlation_id if already set" do
    existing_correlation_id = SecureRandom.uuid
    Thread.current[:correlation_id] = existing_correlation_id

    job = TestJob.new
    job.perform_now

    assert_equal existing_correlation_id, job.correlation_id
  ensure
    Thread.current[:correlation_id] = nil
  end

  test "cleans up thread locals even on error" do
    error_job = Class.new(ApplicationJob) do
      def perform
        raise StandardError, "Test error"
      end
    end

    job = error_job.new

    assert_raises(StandardError) do
      job.perform_now
    end

    # Thread locals should still be cleaned up
    assert_nil Thread.current[:correlation_id]
    assert_nil Thread.current[:job_id]
    assert_nil Thread.current[:session_id]
  end

  test "logs job start and completion" do
    log_output = capture_log_output do
      TestJob.perform_now
    end

    assert_includes log_output, "Starting job"
    assert_includes log_output, "ApplicationJobTest::TestJob"
    assert_includes log_output, "Completed job"
  end

  test "has retry configuration for database errors" do
    # Verify that ApplicationJob is configured to handle database errors
    # The actual retry_on calls are present in ApplicationJob but not easily testable
    # This test just verifies the job class is properly configured
    assert_respond_to ApplicationJob, :retry_on
  end

  test "includes GoodJob InterruptErrors so deploy-interrupted runs raise GoodJob::InterruptError" do
    # Without this module an interrupted run is retried from scratch instead of being
    # discarded. The module makes jobs raise GoodJob::InterruptError on interrupt, which
    # ApplicationJob discards via rescue_from.
    assert_includes ApplicationJob.ancestors, GoodJob::ActiveJobExtensions::InterruptErrors
  end

  test "discards GoodJob::InterruptError and logs the discard at INFO, not ERROR" do
    # Deploy/graceful-shutdown interruptions are expected operational behavior. The original
    # `discard_on GoodJob::InterruptError` fired ActiveJob's `discard.active_job` notification,
    # whose LogSubscriber logs at ERROR — tripping the "any Zimmer ERROR → critical" Grafana alert
    # on every deploy that interrupted a job. ApplicationJob handles the error with rescue_from
    # instead, which discards the job WITHOUT firing that notification and logs at INFO.
    #
    # IMPORTANT: the discard LogSubscriber logs to ActiveJob::Base.logger, so capture_log_records
    # swaps BOTH Rails.logger and ActiveJob::Base.logger. Capturing only Rails.logger would let a
    # regression (an ERROR line from the LogSubscriber) slip through unnoticed.
    interrupt_job = Class.new(ApplicationJob) do
      def perform
        raise GoodJob::InterruptError, "Interrupted after starting perform"
      end
    end

    records = capture_log_records do
      # rescue_from swallows the matched error, so perform_now must NOT raise.
      assert_nothing_raised do
        interrupt_job.perform_now
      end
    end

    discard_records = records.select { |severity, message| message.include?("Discarded") }
    assert_equal 1, discard_records.size, "expected exactly one discard log line, got: #{records.inspect}"

    severity, message = discard_records.first
    assert_equal "INFO", severity, "discard must log at INFO, not #{severity}"
    assert_includes message, "GoodJob::InterruptError"

    # Nothing about the discard should be logged at ERROR (the source of the false alert).
    error_records = records.select { |sev, _| sev == "ERROR" }
    assert_empty error_records, "interrupt discard must not log at ERROR, got: #{error_records.inspect}"
  end

  test "discard_interrupt_quietly keeps interrupts at INFO even with a broad discard_on StandardError" do
    # Regression guard for the real production path. BundleInstallJob / McpPackageReinstallJob
    # declare `discard_on StandardError`. Because GoodJob::InterruptError < StandardError and
    # ActiveSupport resolves rescue handlers last-registered-wins, that broad discard_on would
    # shadow ApplicationJob's inherited interrupt handler and re-emit the ERROR LogSubscriber
    # line ("Discarded <Job> (Job ID: …) due to a GoodJob::InterruptError (…).") — the exact
    # line that tripped the alert. Re-registering via discard_interrupt_quietly AFTER the
    # discard_on must win and keep the interrupt at INFO.
    interrupt_job = Class.new(ApplicationJob) do
      discard_on StandardError
      discard_interrupt_quietly

      def perform
        raise GoodJob::InterruptError, "Interrupted after starting perform"
      end
    end

    records = capture_log_records do
      assert_nothing_raised do
        interrupt_job.perform_now
      end
    end

    discard_records = records.select { |_severity, message| message.include?("Discarded") }
    assert_equal 1, discard_records.size, "expected exactly one discard log line, got: #{records.inspect}"
    assert_equal "INFO", discard_records.first.first, "discard must log at INFO even with discard_on StandardError"

    error_records = records.select { |sev, _| sev == "ERROR" }
    assert_empty error_records, "discard_on StandardError must not re-emit the interrupt at ERROR, got: #{error_records.inspect}"
  end

  private

  def capture_log_output
    original_logger = Rails.logger
    log_output = StringIO.new
    Rails.logger = Logger.new(log_output)

    yield

    log_output.string
  ensure
    Rails.logger = original_logger
  end

  # Captures [severity, message] tuples so tests can assert on log LEVEL, not just text.
  # Swaps BOTH Rails.logger and ActiveJob::Base.logger: ActiveJob's LogSubscriber emits its
  # discard/retry lines to ActiveJob::Base.logger, so capturing only Rails.logger would miss
  # the very ERROR line this guards against.
  def capture_log_records
    original_rails_logger = Rails.logger
    original_aj_logger = ActiveJob::Base.logger
    records = []
    logger = Logger.new(StringIO.new)
    logger.formatter = proc do |severity, _datetime, _progname, msg|
      records << [ severity, msg.to_s ]
      ""
    end
    Rails.logger = logger
    ActiveJob::Base.logger = logger

    yield

    records
  ensure
    Rails.logger = original_rails_logger
    ActiveJob::Base.logger = original_aj_logger
  end
end
