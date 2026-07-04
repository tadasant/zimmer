# frozen_string_literal: true

require "test_helper"

class ErrorReporterTest < ActiveSupport::TestCase
  # In the test environment SENTRY_DSN_BACKEND is unset, so Sentry is never
  # initialized and ErrorReporter is a hard no-op. This mirrors development.
  test "reporting is disabled when Sentry is not initialized" do
    refute ErrorReporter.reporting_enabled?
  end

  test "report_exception is a no-op (returns nil, never touches Sentry) when not initialized" do
    called = false
    Sentry.stub(:capture_exception, ->(*) { called = true }) do
      assert_nil ErrorReporter.report_exception(StandardError.new("boom"))
    end
    refute called, "Sentry.capture_exception must not be called when Sentry is not initialized"
  end

  test "report_message is a no-op when not initialized" do
    called = false
    Sentry.stub(:capture_message, ->(*) { called = true }) do
      assert_nil ErrorReporter.report_message("something")
    end
    refute called
  end

  test "report_exception forwards the exception, level, and compacted context when initialized" do
    captured = nil
    Sentry.stub(:initialized?, true) do
      Sentry.stub(:capture_exception, ->(exc, **kw) { captured = [ exc, kw ] }) do
        err = StandardError.new("kaboom")
        ErrorReporter.report_exception(err, context: { session_id: 7, blank: nil }, level: :warning)
      end
    end

    assert_instance_of Array, captured
    assert_equal "kaboom", captured[0].message
    assert_equal :warning, captured[1][:level]
    # nil values are stripped so they don't clutter the GlitchTip event.
    assert_equal({ session_id: 7 }, captured[1][:extra])
  end

  test "report_message forwards the message, level, and context when initialized" do
    captured = nil
    Sentry.stub(:initialized?, true) do
      Sentry.stub(:capture_message, ->(msg, **kw) { captured = [ msg, kw ] }) do
        ErrorReporter.report_message("lifecycle warning", context: { session_id: 9 })
      end
    end

    assert_equal "lifecycle warning", captured[0]
    assert_equal :error, captured[1][:level]
    assert_equal({ session_id: 9 }, captured[1][:extra])
  end

  test "report_exception never raises into the caller even if Sentry itself blows up" do
    Sentry.stub(:initialized?, true) do
      Sentry.stub(:capture_exception, ->(*) { raise "sentry transport down" }) do
        assert_nothing_raised do
          assert_nil ErrorReporter.report_exception(StandardError.new("boom"))
        end
      end
    end
  end
end
