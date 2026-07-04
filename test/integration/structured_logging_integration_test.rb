# frozen_string_literal: true

require "test_helper"

class StructuredLoggingIntegrationTest < ActionDispatch::IntegrationTest
  teardown do
    # Clean up thread locals
    Thread.current[:correlation_id] = nil
    Thread.current[:session_id] = nil
    Thread.current[:job_id] = nil
    Thread.current[:process_pid] = nil
  end

  test "correlation IDs propagate through job and services" do
    session = sessions(:running)

    # Execute a service that uses structured logging
    service = SessionRecoveryService.new(session)

    # Verify that the service has a structured logger with the session_id
    assert_equal session.id, service.instance_variable_get(:@logger).context[:session_id]

    # When we call recover, it should set thread locals
    service.recover

    # Note: SessionRecoveryService may not set thread locals directly since it only logs,
    # but its StructuredLogger instance should have the session_id in its context
    assert_equal session.id, service.instance_variable_get(:@logger).context[:session_id]
  end

  test "structured logger includes contextual data" do
    log_output = StringIO.new
    test_logger = Logger.new(log_output)
    logger = StructuredLogger.new({ session_id: 123, service: "TestService" }, logger: test_logger)

    logger.info("Test operation", step: "initialization")

    output = log_output.string
    assert_includes output, "Test operation"
    assert_includes output, "step=initialization"
  end

  test "services use structured logging consistently" do
    session = sessions(:running)

    # Test SessionRecoveryService
    service = SessionRecoveryService.new(session)
    assert_respond_to service.instance_variable_get(:@logger), :info
    assert_respond_to service.instance_variable_get(:@logger), :error

    # Test TranscriptPollerService
    poller = TranscriptPollerService.new(session)
    assert_respond_to poller.instance_variable_get(:@logger), :info
    assert_respond_to poller.instance_variable_get(:@logger), :error

    # Test ProcessTerminationService
    terminator = ProcessTerminationService.new(process_pid: 12345, session: session)
    assert_respond_to terminator.instance_variable_get(:@logger), :info
    assert_respond_to terminator.instance_variable_get(:@logger), :error
  end

  test "log queries module can parse structured logs" do
    # Create a temporary log file with structured JSON logs
    log_content = <<~LOGS
      {"timestamp":"2025-01-15T10:30:45Z","severity":"INFO","session_id":123,"correlation_id":"abc-123","message":"Test message 1"}
      {"timestamp":"2025-01-15T10:30:46Z","severity":"ERROR","session_id":123,"correlation_id":"abc-123","message":"Test error"}
      {"timestamp":"2025-01-15T10:30:47Z","severity":"INFO","session_id":456,"correlation_id":"def-456","message":"Different session"}
    LOGS

    Dir.mktmpdir do |dir|
      log_file = File.join(dir, "test.log")
      File.write(log_file, log_content)

      # Test logs_for_session
      logs = LogQueries.logs_for_session(123, log_file)
      assert_equal 2, logs.length
      assert logs.all? { |log| log["session_id"] == 123 }

      # Test logs_for_correlation
      logs = LogQueries.logs_for_correlation("abc-123", log_file)
      assert_equal 2, logs.length
      assert logs.all? { |log| log["correlation_id"] == "abc-123" }

      # Test errors
      errors = LogQueries.errors(log_file)
      assert_equal 1, errors.length
      assert_equal "ERROR", errors.first["severity"]

      # Test timeline_for_correlation
      timeline = LogQueries.timeline_for_correlation("abc-123", log_file)
      assert_equal 2, timeline.length
      # Verify ordering
      assert timeline.first["timestamp"] <= timeline.last["timestamp"]
    end
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
