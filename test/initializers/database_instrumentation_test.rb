require "test_helper"

# Unit tests for the slow-query subscriber
# (config/initializers/database_instrumentation.rb). The subscriber's logic is
# extracted into DatabaseInstrumentation.log_slow_query so it can be exercised
# directly with real durations and SQL — no ActiveSupport::Notifications
# plumbing or mocks of internal code. We capture the real Rails.logger output
# and assert on both the emitted level and the message content.
#
# The central contract these tests pin (issue #4403): a slow-but-COMPLETED
# query must log at WARN, never ERROR. rules-ao-errors.yaml pages on any single
# severity_text:ERROR line from agent-orchestrator, so an ERROR here would page
# the production critical alert on a transient, self-resolving blip.
class DatabaseInstrumentationTest < ActiveSupport::TestCase
  test "queries under the slow threshold log nothing" do
    output = capture_log_output do
      DatabaseInstrumentation.log_slow_query(999, "SELECT 1")
    end

    assert_equal "", output.strip
  end

  test "queries over 1s but under 5s log [DatabaseSlow] at WARN" do
    output = capture_log_output do
      DatabaseInstrumentation.log_slow_query(2500, "SELECT * FROM sessions")
    end

    assert_includes output, "WARN"
    assert_includes output, "[DatabaseSlow]"
    assert_includes output, "2500ms"
    assert_not_includes output, "ERROR"
    assert_not_includes output, "[DatabaseChoke]"
  end

  test "queries over 5s log [DatabaseChoke] at WARN, not ERROR" do
    output = capture_log_output do
      DatabaseInstrumentation.log_slow_query(6200, "BEGIN")
    end

    assert_includes output, "WARN"
    assert_includes output, "[DatabaseChoke]"
    assert_includes output, "6200ms"
    # The crux of issue #4403: this must NOT page the prod ERROR alert.
    assert_not_includes output, "ERROR"
  end

  test "duration is rendered as an integer ms (the subscriber feeds a Float)" do
    # In production duration_ms = (finish - start) * 1000 is always a Float, so
    # the line must read "6201ms", not "6201.0ms".
    output = capture_log_output do
      DatabaseInstrumentation.log_slow_query(6200.4, "BEGIN")
    end

    assert_includes output, "6200ms"
    assert_not_includes output, "6200.0ms"
    assert_not_includes output, "6200.4ms"
  end

  test "[DatabaseChoke] message names both possible causes and notes completion" do
    output = capture_log_output do
      DatabaseInstrumentation.log_slow_query(6200, "BEGIN")
    end

    # No longer asserts "severe lock contention" as fact — saturation is the
    # more common cause and the subscriber cannot distinguish them.
    assert_not_includes output, "severe lock contention"
    assert_includes output, "saturation"
    assert_includes output, "query completed"
  end

  test "a single slow query emits exactly one line (Slow and Choke are mutually exclusive)" do
    choke_output = capture_log_output do
      DatabaseInstrumentation.log_slow_query(7000, "BEGIN")
    end
    assert_equal 1, choke_output.lines.count { |l| l.include?("[Database") }
    assert_not_includes choke_output, "[DatabaseSlow]"

    slow_output = capture_log_output do
      DatabaseInstrumentation.log_slow_query(1500, "SELECT 1")
    end
    assert_equal 1, slow_output.lines.count { |l| l.include?("[Database") }
    assert_not_includes slow_output, "[DatabaseChoke]"
  end

  test "long SQL is truncated to keep log lines bounded" do
    long_sql = "SELECT " + ("a" * 500)
    output = capture_log_output do
      DatabaseInstrumentation.log_slow_query(6000, long_sql)
    end

    assert_includes output, "..."
    # The SQL is capped at SQL_MAX_LEN chars (+ the "..." marker), so the
    # original 507-char body cannot appear in full.
    refute_includes output, long_sql
    refute_includes output, "a" * (DatabaseInstrumentation::SQL_MAX_LEN + 1)
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
