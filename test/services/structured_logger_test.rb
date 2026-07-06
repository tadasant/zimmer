# frozen_string_literal: true

require "test_helper"

class StructuredLoggerTest < ActiveSupport::TestCase
  setup do
    @logger = StructuredLogger.new({ session_id: 123, process_pid: 456 })
  end

  teardown do
    # Clean up thread locals
    Thread.current[:correlation_id] = nil
    Thread.current[:session_id] = nil
    Thread.current[:job_id] = nil
    Thread.current[:process_pid] = nil
  end

  test "initializes with context" do
    assert_equal({ session_id: 123, process_pid: 456 }, @logger.context)
  end

  test "logs info with context" do
    log_output = StringIO.new
    test_logger = Logger.new(log_output)
    logger = StructuredLogger.new({ session_id: 123 }, logger: test_logger)

    logger.info("Test message", extra: "data")

    output = log_output.string
    assert_includes output, "Test message"
    assert_includes output, "extra=data"
  end

  test "logs debug with context" do
    log_output = StringIO.new
    test_logger = Logger.new(log_output)
    logger = StructuredLogger.new({ session_id: 123 }, logger: test_logger)

    logger.debug("Debug message", value: 42)

    output = log_output.string
    assert_includes output, "Debug message"
    assert_includes output, "value=42"
  end

  test "logs warn with context" do
    log_output = StringIO.new
    test_logger = Logger.new(log_output)
    logger = StructuredLogger.new({ session_id: 123 }, logger: test_logger)

    logger.warn("Warning message", reason: "test")

    output = log_output.string
    assert_includes output, "Warning message"
    assert_includes output, "reason=test"
  end

  test "logs error with context" do
    log_output = StringIO.new
    test_logger = Logger.new(log_output)
    logger = StructuredLogger.new({ session_id: 123 }, logger: test_logger)

    logger.error("Error message", error_code: 500)

    output = log_output.string
    assert_includes output, "Error message"
    assert_includes output, "error_code=500"
  end

  test "log method does not modify thread locals (thread safety)" do
    # The log method should NOT modify thread locals to prevent side effects
    # Thread locals are managed explicitly by ApplicationJob, not by StructuredLogger
    Thread.current[:session_id] = nil
    Thread.current[:process_pid] = nil

    @logger.info("Test")

    # Thread locals should remain unchanged after logging
    assert_nil Thread.current[:session_id]
    assert_nil Thread.current[:process_pid]
  end

  test "with_context sets and restores thread locals" do
    Thread.current[:session_id] = 999
    original_session_id = Thread.current[:session_id]

    @logger.with_context(session_id: 111, job_id: "abc") do
      assert_equal 111, Thread.current[:session_id]
      assert_equal "abc", Thread.current[:job_id]
    end

    assert_equal original_session_id, Thread.current[:session_id]
    assert_nil Thread.current[:job_id]
  end

  test "child logger merges context" do
    child = @logger.child(job_id: "xyz", extra: "value")

    assert_equal 123, child.context[:session_id]
    assert_equal 456, child.context[:process_pid]
    assert_equal "xyz", child.context[:job_id]
    assert_equal "value", child.context[:extra]
  end

  test "logs without additional context uses instance context" do
    log_output = StringIO.new
    test_logger = Logger.new(log_output)
    logger = StructuredLogger.new({ session_id: 123 }, logger: test_logger)

    logger.info("Simple message")

    output = log_output.string
    assert_includes output, "Simple message"
    # Instance context is included even without additional context
    assert_includes output, "session_id=123"
  end

  test "logs with empty context has no separator" do
    log_output = StringIO.new
    test_logger = Logger.new(log_output)
    logger = StructuredLogger.new({}, logger: test_logger)

    logger.info("Simple message")

    output = log_output.string
    assert_includes output, "Simple message"
    # No context = no separator
    refute_includes output, " | "
  end

  test "does not modify existing thread locals when logging" do
    Thread.current[:correlation_id] = "existing-corr-id"

    @logger.info("Test")

    # Log method should not modify thread locals
    assert_equal "existing-corr-id", Thread.current[:correlation_id]
  end

  test "includes context in formatted message regardless of thread locals" do
    log_output = StringIO.new
    test_logger = Logger.new(log_output)
    logger = StructuredLogger.new({ correlation_id: "new-corr-id", session_id: 456 }, logger: test_logger)

    logger.info("Test message")

    # The context should appear in the formatted message
    output = log_output.string
    assert_includes output, "Test message"
    assert_includes output, "correlation_id=new-corr-id"
    assert_includes output, "session_id=456"
  end

  test "error routes an exception object in context to ErrorReporter.report_exception" do
    test_logger = Logger.new(StringIO.new)
    logger = StructuredLogger.new({ session_id: 123 }, logger: test_logger)
    boom = StandardError.new("kaboom")

    captured = nil
    ErrorReporter.stub(:report_exception, ->(exc, **kw) { captured = [ exc, kw ] }) do
      logger.error("Broadcast failed", exception: boom, stream: "s1")
    end

    assert_equal boom, captured[0]
    # The exception/error keys are stripped from the reported context; the rest
    # (including instance context) is forwarded.
    assert_equal 123, captured[1][:context][:session_id]
    assert_equal "s1", captured[1][:context][:stream]
    refute captured[1][:context].key?(:exception)
  end

  test "error treats an Exception-valued :error key as the exception" do
    logger = StructuredLogger.new({}, logger: Logger.new(StringIO.new))
    boom = RuntimeError.new("legacy")

    captured = nil
    ErrorReporter.stub(:report_exception, ->(exc, **) { captured = exc }) do
      logger.error("Legacy style", error: boom)
    end

    assert_equal boom, captured
  end

  test "error routes to ErrorReporter.report_message when no exception is present" do
    logger = StructuredLogger.new({ session_id: 123 }, logger: Logger.new(StringIO.new))

    captured = nil
    ErrorReporter.stub(:report_message, ->(msg, **kw) { captured = [ msg, kw ] }) do
      logger.error("Plain error", error: "just a string")
    end

    assert_equal "Plain error", captured[0]
    assert_equal 123, captured[1][:context][:session_id]
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
end
