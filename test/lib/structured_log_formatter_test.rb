# frozen_string_literal: true

require "test_helper"

# Test the StructuredLogFormatter functionality
class StructuredLogFormatterTest < ActiveSupport::TestCase
  setup do
    @formatter = StructuredLogFormatter.new
    @timestamp = Time.parse("2025-01-15 10:30:45 UTC")
  end

  teardown do
    # Clean up thread locals
    Thread.current[:correlation_id] = nil
    Thread.current[:session_id] = nil
    Thread.current[:job_id] = nil
    Thread.current[:process_pid] = nil
  end

  test "formats basic log message as JSON" do
    result = @formatter.call("INFO", @timestamp, "test", "Test message")
    parsed = JSON.parse(result)

    assert_equal "2025-01-15T10:30:45Z", parsed["timestamp"]
    assert_equal "INFO", parsed["severity"]
    assert_equal "test", parsed["progname"]
    assert_equal "Test message", parsed["message"]
  end

  test "includes correlation_id when set in thread" do
    Thread.current[:correlation_id] = "test-correlation-123"

    result = @formatter.call("INFO", @timestamp, nil, "Test message")
    parsed = JSON.parse(result)

    assert_equal "test-correlation-123", parsed["correlation_id"]
  end

  test "includes session_id when set in thread" do
    Thread.current[:session_id] = 456

    result = @formatter.call("INFO", @timestamp, nil, "Test message")
    parsed = JSON.parse(result)

    assert_equal 456, parsed["session_id"]
  end

  test "includes job_id when set in thread" do
    Thread.current[:job_id] = "job-789"

    result = @formatter.call("INFO", @timestamp, nil, "Test message")
    parsed = JSON.parse(result)

    assert_equal "job-789", parsed["job_id"]
  end

  test "includes process_pid when set in thread" do
    Thread.current[:process_pid] = 12345

    result = @formatter.call("INFO", @timestamp, nil, "Test message")
    parsed = JSON.parse(result)

    assert_equal 12345, parsed["process_pid"]
  end

  test "includes all context fields when set" do
    Thread.current[:correlation_id] = "corr-123"
    Thread.current[:session_id] = 789
    Thread.current[:job_id] = "job-abc"
    Thread.current[:process_pid] = 54321

    result = @formatter.call("ERROR", @timestamp, "app", "Error occurred")
    parsed = JSON.parse(result)

    assert_equal "corr-123", parsed["correlation_id"]
    assert_equal 789, parsed["session_id"]
    assert_equal "job-abc", parsed["job_id"]
    assert_equal 54321, parsed["process_pid"]
    assert_equal "ERROR", parsed["severity"]
    assert_equal "Error occurred", parsed["message"]
  end

  test "formats exception messages with backtrace" do
    exception = StandardError.new("Test error")
    exception.set_backtrace([ "/path/to/file.rb:10:in `method'", "/path/to/other.rb:20:in `other'" ])

    result = @formatter.call("ERROR", @timestamp, nil, exception)
    parsed = JSON.parse(result)

    assert_includes parsed["message"], "Test error (StandardError)"
    assert_includes parsed["message"], "/path/to/file.rb:10:in `method'"
    assert_includes parsed["message"], "/path/to/other.rb:20:in `other'"
  end

  test "formats non-string messages with inspect" do
    result = @formatter.call("DEBUG", @timestamp, nil, { key: "value" })
    parsed = JSON.parse(result)

    assert_includes parsed["message"], "key"
    assert_includes parsed["message"], "value"
  end

  test "output ends with newline" do
    result = @formatter.call("INFO", @timestamp, nil, "Test")
    assert_match(/\n\z/, result)
  end
end
