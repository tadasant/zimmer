# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class UnclassifiedFailureReporterTest < ActiveSupport::TestCase
  setup do
    @session = Session.create!(
      prompt: "Test prompt",
      git_root: "https://github.com/test/repo.git",
      status: :running
    )
  end

  test "raises an alert naming the kind and carrying the unmatched output" do
    ErrorReporter.expects(:report_message).with do |message, opts|
      assert_equal "Unclassified failure: process exit", message
      assert_equal :error, opts[:level]
      assert_match(/exit code: 2/, opts[:context][:details])
      # The output travels through AlertSnippet in its own field — not pasted into
      # the prose.
      assert_match(/Some brand new error wording/, opts[:context][:unmatched_output])
      assert_equal "ProcessLifecycleManager#handle_exit", opts[:context][:source]
      true
    end

    UnclassifiedFailureReporter.report(
      kind: "process exit",
      summary: "Session process died with exit code: 2 and no recovery classifier matched",
      source: "ProcessLifecycleManager#handle_exit",
      session: @session,
      output: "Some brand new error wording nobody has a pattern for"
    )
  end

  test "links the session so an operator can open it from the alert" do
    ErrorReporter.expects(:report_message).with do |_message, opts|
      assert_match(%r{/sessions/#{@session.id}}, opts[:context][:details])
      true
    end

    UnclassifiedFailureReporter.report(
      kind: "process exit", summary: "exit code: 2",
      source: "Test", session: @session
    )
  end

  test "works without a session or output" do
    ErrorReporter.expects(:report_message)

    assert_nothing_raised do
      UnclassifiedFailureReporter.report(kind: "process exit", summary: "exit code: 2", source: "Test")
    end
  end

  # The noise budget: a fleet-wide wave of the same unknown failure must collapse
  # into one GlitchTip issue, not one per session. That only works if the reported
  # message ignores the session and names (kind) alone, with the summary alongside.
  test "the reported message is identical for the same kind across different sessions" do
    other = Session.create!(prompt: "Other", git_root: "https://github.com/test/repo.git", status: :running)

    messages = []
    ErrorReporter.stubs(:report_message).with do |message, _opts|
      messages << message
      true
    end

    UnclassifiedFailureReporter.report(kind: "process exit", summary: "exit code: 2", source: "Test", session: @session)
    UnclassifiedFailureReporter.report(kind: "process exit", summary: "exit code: 2", source: "Test", session: other)

    assert_equal 2, messages.size
    assert_equal messages.first, messages.last
    assert_no_match(/#{@session.id}/, messages.first)
  end

  test "the summary rides in the context so a new failure mode is still distinguishable" do
    summaries = []
    ErrorReporter.stubs(:report_message).with do |_message, opts|
      summaries << opts[:context][:summary]
      true
    end

    UnclassifiedFailureReporter.report(kind: "process exit", summary: "exit code: 2", source: "Test")
    UnclassifiedFailureReporter.report(kind: "process exit", summary: "exit code: 137", source: "Test")

    assert_equal [ "exit code: 2", "exit code: 137" ], summaries
  end

  test "truncates very long output so one report cannot be dominated by it" do
    ErrorReporter.expects(:report_message).with do |_message, opts|
      assert_operator opts[:context][:unmatched_output].length, :<=, AlertSnippet::MAX_CHARS
      true
    end

    UnclassifiedFailureReporter.report(
      kind: "process exit", summary: "exit code: 2", source: "Test",
      output: "x" * 50_000
    )
  end

  # The whole point of the change: an unknown failure mode has to be greppable
  # in the logs, not just visible in Slack.
  test "logs loudly with the word unclassified and the unmatched output" do
    ErrorReporter.stubs(:report_message)

    logged = nil
    Rails.logger.stubs(:error).with { |msg| logged = msg.to_s; true }

    UnclassifiedFailureReporter.report(
      kind: "process exit", summary: "exit code: 2", source: "Test",
      output: "brand new wording"
    )

    assert_match(/unclassified/i, logged)
    assert_match(/brand new wording/, logged)
  end

  # This is the first path routing raw agent stderr and transcript text out of the
  # box. Session logs already carry both, but they stay inside Zimmer's own UI. The
  # output travels through AlertSnippet so it is redacted and clamped — a second,
  # weaker copy of that seam here would be the actual risk.
  test "hands the unmatched output through AlertSnippet so it is redacted" do
    captured = nil
    ErrorReporter.stubs(:report_message).with do |_message, opts|
      captured = opts[:context][:unmatched_output]
      true
    end

    UnclassifiedFailureReporter.report(
      kind: "process exit", summary: "exit code: 2", source: "Test",
      output: "spawn failed: npx -y some-mcp"
    )

    assert_equal "spawn failed: npx -y some-mcp", captured,
      "the raw output must reach its own field, not be pre-mangled into the prose"
  end

  # The complement: the raw output must NOT also be pasted into the prose, or
  # redaction would be bypassed for that copy.
  test "does not paste the unmatched output into details" do
    token = "ghp_" + ("A" * 20)
    captured = nil
    ErrorReporter.stubs(:report_message).with do |_message, opts|
      captured = opts[:context][:details]
      true
    end

    UnclassifiedFailureReporter.report(
      kind: "process exit", summary: "exit code: 2", source: "Test",
      output: "env: GITHUB_TOKEN=#{token}"
    )

    assert captured
    assert_not_includes captured, token
    assert_includes captured, "exit code: 2", "the summary still belongs in details"
  end

  # And the seam it delegates to really does redact that shape.
  test "AlertSnippet redacts the credential shapes this reporter forwards" do
    token = "ghp_" + ("A" * 20)

    snippet = AlertSnippet.build("env: GITHUB_TOKEN=#{token}")

    assert_not_includes snippet, token
    assert_includes snippet, "[REDACTED]"
  end

  # Callers must not have to know that announcing a failure could itself fail.
  test "a failing alert never propagates out of report" do
    ErrorReporter.stubs(:report_message).raises(StandardError, "glitchtip is on fire")

    assert_nothing_raised do
      UnclassifiedFailureReporter.report(kind: "process exit", summary: "exit code: 2", source: "Test")
    end
  end

  # The production shape: every call site passes a StructuredLogger, whose #error
  # writes the ERROR record AND routes to ErrorReporter. One emission, not two — a
  # second explicit report here would open a second GlitchTip issue for one event.
  test "a StructuredLogger caller emits exactly one report, through the logger" do
    reports = capture_error_reports do |captured|
      UnclassifiedFailureReporter.report(
        kind: "process exit", summary: "exit code: 2", source: "Test", session: @session,
        output: "brand new wording",
        logger: StructuredLogger.new({ service: "ProcessLifecycleManager" })
      )
      assert_equal 1, captured.size, "one event must not open two issues"
    end

    report = reports.sole
    assert_equal "Unclassified failure: process exit", report.message
    assert_equal :error, report.level
    assert_equal "exit code: 2", report.context[:summary]
    assert_equal @session.id, report.context[:session_id]
    assert_match(/brand new wording/, report.context[:unmatched_output])
    assert_equal "ProcessLifecycleManager", report.context[:service],
      "the logger's own context rides along, which is why the logger is passed at all"
  end

  # The details prose is one line, because it shares a formatted log line with the
  # rest of the context. A multi-paragraph value would split one ERROR record into
  # several lines that nothing reassembles.
  test "the details prose is flattened to a single line" do
    captured = nil
    ErrorReporter.stubs(:report_message).with do |_message, opts|
      captured = opts[:context][:details]
      true
    end

    UnclassifiedFailureReporter.report(kind: "process exit", summary: "exit code: 2", source: "Test", session: @session)

    assert captured
    assert_not_includes captured, "\n"
    assert_includes captured, "No classifier matched this process exit"
  end

  # A logger that blows up must not swallow the report beside it.
  test "still reports when the loud log itself fails" do
    Rails.logger.stubs(:error).raises(StandardError, "logger is broken")
    ErrorReporter.expects(:report_message)

    assert_nothing_raised do
      UnclassifiedFailureReporter.report(kind: "process exit", summary: "exit code: 2", source: "Test")
    end
  end
end
