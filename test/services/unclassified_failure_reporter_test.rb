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
    AlertService.expects(:raise_alert).with do |title, opts|
      assert_equal "Unclassified failure: process exit", title
      assert_match(/exit code: 2/, opts[:details])
      # The output travels as error:, which AlertService renders through
      # AlertSnippet into its own fenced block — not pasted into details.
      assert_match(/Some brand new error wording/, opts[:error])
      assert_equal "ProcessLifecycleManager#handle_exit", opts[:source]
      true
    end.returns(true)

    UnclassifiedFailureReporter.report(
      kind: "process exit",
      summary: "Session process died with exit code: 2 and no recovery classifier matched",
      source: "ProcessLifecycleManager#handle_exit",
      session: @session,
      output: "Some brand new error wording nobody has a pattern for"
    )
  end

  test "links the session so an operator can open it from the alert" do
    AlertService.expects(:raise_alert).with do |_title, opts|
      assert_match(%r{/sessions/#{@session.id}}, opts[:details])
      true
    end.returns(true)

    UnclassifiedFailureReporter.report(
      kind: "process exit", summary: "exit code: 2",
      source: "Test", session: @session
    )
  end

  test "works without a session or output" do
    AlertService.expects(:raise_alert).returns(true)

    assert_nothing_raised do
      UnclassifiedFailureReporter.report(kind: "process exit", summary: "exit code: 2", source: "Test")
    end
  end

  # The noise budget: a fleet-wide wave of the same unknown failure must collapse
  # into one alert, not one per session. That only works if the dedup key ignores
  # the session and keys on (kind, summary).
  test "dedup key is identical for the same kind and summary across different sessions" do
    other = Session.create!(prompt: "Other", git_root: "https://github.com/test/repo.git", status: :running)

    keys = []
    AlertService.stubs(:raise_alert).with do |_title, opts|
      keys << opts[:dedup_key]
      true
    end.returns(true)

    UnclassifiedFailureReporter.report(kind: "process exit", summary: "exit code: 2", source: "Test", session: @session)
    UnclassifiedFailureReporter.report(kind: "process exit", summary: "exit code: 2", source: "Test", session: other)

    assert_equal 2, keys.size
    assert_equal keys.first, keys.last
  end

  test "dedup key differs for a different failure mode so a new unknown still pages" do
    keys = []
    AlertService.stubs(:raise_alert).with do |_title, opts|
      keys << opts[:dedup_key]
      true
    end.returns(true)

    UnclassifiedFailureReporter.report(kind: "process exit", summary: "exit code: 2", source: "Test")
    UnclassifiedFailureReporter.report(kind: "process exit", summary: "exit code: 137", source: "Test")

    assert_not_equal keys.first, keys.last
  end

  test "truncates very long output so the alert stays inside Slack's block limits" do
    AlertService.expects(:raise_alert).with do |_title, opts|
      assert_operator opts[:details].length, :<, 3000
      true
    end.returns(true)

    UnclassifiedFailureReporter.report(
      kind: "process exit", summary: "exit code: 2", source: "Test",
      output: "x" * 50_000
    )
  end

  # The whole point of the change: an unknown failure mode has to be greppable
  # in the logs, not just visible in Slack.
  test "logs loudly with the word unclassified and the unmatched output" do
    AlertService.stubs(:raise_alert).returns(true)

    logged = nil
    Rails.logger.stubs(:error).with { |msg| logged = msg.to_s; true }

    UnclassifiedFailureReporter.report(
      kind: "process exit", summary: "exit code: 2", source: "Test",
      output: "brand new wording"
    )

    assert_match(/unclassified/i, logged)
    assert_match(/brand new wording/, logged)
  end

  # This is the first path routing raw agent stderr and transcript text to Slack.
  # Session logs already carry both, but they stay inside Zimmer's own UI. The
  # output travels as `error:` so AlertSnippet redacts, clamps, and fences it —
  # a second, weaker copy of that seam here would be the actual risk.
  test "hands the unmatched output to AlertService as error: so it is redacted" do
    captured = nil
    AlertService.stubs(:raise_alert).with do |_title, opts|
      captured = opts[:error]
      true
    end.returns(true)

    UnclassifiedFailureReporter.report(
      kind: "process exit", summary: "exit code: 2", source: "Test",
      output: "spawn failed: npx -y some-mcp"
    )

    assert_equal "spawn failed: npx -y some-mcp", captured,
      "the raw output must reach error:, not be pre-mangled into details"
  end

  # The complement: the raw output must NOT also be pasted into `details`, or
  # redaction would be bypassed for the copy that reaches Slack first.
  test "does not paste the unmatched output into details" do
    token = "ghp_" + ("A" * 20)
    captured = nil
    AlertService.stubs(:raise_alert).with do |_title, opts|
      captured = opts[:details]
      true
    end.returns(true)

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
    AlertService.stubs(:raise_alert).raises(StandardError, "slack is on fire")

    assert_nothing_raised do
      UnclassifiedFailureReporter.report(kind: "process exit", summary: "exit code: 2", source: "Test")
    end
  end

  # A logger that blows up must not swallow the alert that follows it.
  test "still alerts when the loud log itself fails" do
    Rails.logger.stubs(:error).raises(StandardError, "logger is broken")
    AlertService.expects(:raise_alert).returns(true)

    assert_nothing_raised do
      UnclassifiedFailureReporter.report(kind: "process exit", summary: "exit code: 2", source: "Test")
    end
  end
end
