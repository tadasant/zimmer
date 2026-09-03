# frozen_string_literal: true

require "test_helper"

class RetryBudgetTest < ActiveSupport::TestCase
  setup do
    @session = Session.create!(
      prompt: "Test prompt",
      agent_runtime: "claude_code",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    )
  end

  # The table below is the whole point of the object: a metadata key or a maximum that
  # drifts changes whether a real session recovers or fails permanently, silently, and
  # only on a long-running session in production. These are the values every loop used
  # before RetryBudget existed (issue #527), asserted literally rather than derived.
  DECLARED = {
    sigterm: {
      key: "sigterm_retry_count", max: 3, stamp: "last_sigterm_at",
      clears: %w[sigterm_retry_count sigterm_retry_timestamps last_sigterm_at]
    },
    api_error: {
      key: "api_error_retry_count", max: 6, stamp: "last_api_error_retry_at",
      clears: %w[api_error_retry_count last_api_error_retry_at]
    },
    signal_death: {
      key: "signal_death_retry_count", max: 3, stamp: "last_signal_death_at",
      clears: %w[signal_death_retry_count last_signal_death_at]
    },
    mcp_connection: {
      key: "mcp_retry_count", max: 3, stamp: "mcp_last_retry_at",
      clears: %w[mcp_retry_count mcp_last_retry_at]
    },
    context_length: {
      key: "compact_retry_count", max: 2, stamp: "last_compact_at",
      clears: %w[compact_retry_count last_compact_at]
    },
    session_id_conflict: {
      key: "session_id_conflict_count", max: 2, stamp: "last_session_id_conflict_at",
      clears: %w[session_id_conflict_count last_session_id_conflict_at]
    },
    empty_turn: {
      key: "empty_turn_recovery_count", max: 2, stamp: "last_empty_turn_recovery_at",
      clears: %w[empty_turn_recovery_count last_empty_turn_recovery_at]
    }
  }.freeze

  DECLARED.each do |name, expected|
    test "#{name} budget declares the metadata keys and maximum its loop has always used" do
      budget = RetryBudget.find(name)

      assert_equal expected[:key], budget.key
      assert_equal expected[:max], budget.max
      assert_equal expected[:stamp], budget.stamp
      assert_equal expected[:clears], budget.clears
    end
  end

  test "all declares exactly the seven auto-recovery budgets" do
    assert_equal DECLARED.keys, RetryBudget.all.map(&:name)
  end

  # The one budget that does NOT share the house window, and the reason it cannot:
  # its branch fires only while neither transcript store holds a conversation, so
  # "the process is up" is not evidence it is working. A 60-second window inside a
  # 180-second MCP startup timeout would hand the budget back before the restarted
  # process had produced anything, one cycle per timeout, without end.
  test "only the empty-turn budget departs from the shared 60-second window" do
    off_default = RetryBudget.all.reject { |budget| budget.reset_after == RetryBudget::DEFAULT_RESET_AFTER }

    assert_equal [ :empty_turn ], off_default.map(&:name)
    assert_equal 30.minutes.to_i, RetryBudget::EMPTY_TURN.reset_after
    assert RetryBudget::EMPTY_TURN.reset_after > McpStartupTimeout::SECONDS,
      "the window has to clear the whole startup dead zone or it manufactures a restart loop"
  end

  # The negative half of #727: a session-id conflict that repeats inside one turn
  # must still exhaust its budget. Conflicts are spawn-time refusals seconds apart,
  # so no reset can land between them.
  test "a session-id conflict repeating inside one turn is not handed its budget back" do
    budget = RetryBudget::SESSION_ID_CONFLICT
    started = Time.utc(2026, 9, 3, 12, 0, 0)

    travel_to(started) { budget.record!(@session) }
    travel_to(started + 3.seconds) do
      assert_nil budget.reset_if_stable!(@session, since: budget.last_attempt_at(@session))
      budget.record!(@session)
    end

    assert budget.exhausted?(@session), "two conflicts seconds apart must spend the budget"
  end

  test "the SIGTERM budget clears the constant the follow-up delivery paths also clear" do
    # Deliberately the existing Session constant rather than a copy of its key list:
    # Session::STALE_RETRY_METADATA_KEYS is built from it and is spread through
    # sixteen `except(...)` call sites (issue #508). Two lists would drift.
    assert_equal Session::SIGTERM_RETRY_METADATA_KEYS, RetryBudget::SIGTERM.clears
  end

  test "declaring the same budget name twice raises" do
    error = assert_raises(ArgumentError) do
      RetryBudget.define(
        name: :sigterm, key: "x", max: 1, stamp: "y", clears: %w[x],
        label: "X", counter_label: "X counter"
      )
    end

    assert_match(/already declared/, error.message)
  end

  test "count_for reads the counter and treats a missing one as zero" do
    assert_equal 0, RetryBudget::SIGTERM.count_for(@session)

    @session.update!(metadata: { "sigterm_retry_count" => 2 })

    assert_equal 2, RetryBudget::SIGTERM.count_for(@session)
  end

  test "exhausted? is true only at or above the maximum" do
    @session.update!(metadata: { "compact_retry_count" => 1 })
    assert_not RetryBudget::CONTEXT_LENGTH.exhausted?(@session)

    @session.update!(metadata: { "compact_retry_count" => 2 })
    assert RetryBudget::CONTEXT_LENGTH.exhausted?(@session)

    @session.update!(metadata: { "compact_retry_count" => 3 })
    assert RetryBudget::CONTEXT_LENGTH.exhausted?(@session)
  end

  test "next_attempt is one past what is stored" do
    assert_equal 1, RetryBudget::API_ERROR.next_attempt(@session)

    @session.update!(metadata: { "api_error_retry_count" => 4 })

    assert_equal 5, RetryBudget::API_ERROR.next_attempt(@session)
  end

  test "record! bumps the counter, stamps the time and returns the attempt" do
    frozen = Time.utc(2026, 8, 23, 12, 0, 0)

    attempt = travel_to(frozen) { RetryBudget::SIGNAL_DEATH.record!(@session) }

    assert_equal 1, attempt
    @session.reload
    assert_equal 1, @session.metadata["signal_death_retry_count"]
    assert_equal frozen.iso8601, @session.metadata["last_signal_death_at"]
  end

  test "record! writes the caller's attempt number and extra keys, and leaves others alone" do
    @session.update!(metadata: { "process_pid" => 4242, "api_error_retry_count" => 1 })

    attempt = RetryBudget::API_ERROR.record!(
      @session, attempt: 4, extra: { "api_error_last_checked_line" => 88 }
    )

    assert_equal 4, attempt
    @session.reload
    assert_equal 4, @session.metadata["api_error_retry_count"]
    assert_equal 88, @session.metadata["api_error_last_checked_line"]
    assert_equal 4242, @session.metadata["process_pid"], "an unrelated key must survive"
  end

  test "attempt_attributes is the count/stamp pair for a caller batching a wider update" do
    frozen = Time.utc(2026, 8, 23, 12, 0, 0)

    attributes = travel_to(frozen) { RetryBudget::MCP_CONNECTION.attempt_attributes(2) }

    assert_equal({ "mcp_retry_count" => 2, "mcp_last_retry_at" => frozen.iso8601 }, attributes)
  end

  test "last_attempt_at parses the stamp, and reads a corrupt one as never" do
    assert_nil RetryBudget::SIGTERM.last_attempt_at(@session)

    @session.update!(metadata: { "last_sigterm_at" => "2026-08-23T12:00:00Z" })
    assert_equal Time.utc(2026, 8, 23, 12, 0, 0), RetryBudget::SIGTERM.last_attempt_at(@session)

    @session.update!(metadata: { "last_sigterm_at" => "not-a-valid-timestamp" })
    assert_nil RetryBudget::SIGTERM.last_attempt_at(@session)
  end

  test "reset_if_stable! clears the budget once the process has been stable long enough" do
    @session.update!(metadata: {
      "sigterm_retry_count" => 2,
      "sigterm_retry_timestamps" => [ "2026-08-23T11:00:00Z" ],
      "last_sigterm_at" => "2026-08-23T11:00:00Z",
      "process_pid" => 4242
    })

    reset = RetryBudget::SIGTERM.reset_if_stable!(@session, since: 65.seconds.ago)

    assert_equal 2, reset.previous_count
    assert_operator reset.elapsed_seconds, :>=, 60
    @session.reload
    assert_nil @session.metadata["sigterm_retry_count"]
    assert_nil @session.metadata["sigterm_retry_timestamps"]
    assert_nil @session.metadata["last_sigterm_at"]
    assert_equal 4242, @session.metadata["process_pid"]
  end

  test "reset_if_stable! does nothing before the threshold, with no counter, or with no stamp" do
    @session.update!(metadata: { "sigterm_retry_count" => 2 })

    assert_nil RetryBudget::SIGTERM.reset_if_stable!(@session, since: 30.seconds.ago)
    assert_equal 2, @session.reload.metadata["sigterm_retry_count"]

    assert_nil RetryBudget::SIGTERM.reset_if_stable!(@session, since: nil)
    assert_equal 2, @session.reload.metadata["sigterm_retry_count"]

    @session.update!(metadata: {})
    assert_nil RetryBudget::SIGTERM.reset_if_stable!(@session, since: 65.seconds.ago)
  end

  test "reset_if_stable! keeps the scan positions and continuation flags it does not own" do
    @session.update!(metadata: {
      "api_error_retry_count" => 3,
      "last_api_error_retry_at" => "2026-08-23T11:00:00Z",
      "api_error_last_checked_line" => 42
    })
    RetryBudget::API_ERROR.reset_if_stable!(@session, since: 65.seconds.ago)

    assert_equal 42, @session.reload.metadata["api_error_last_checked_line"]

    @session.update!(metadata: {
      "compact_retry_count" => 1,
      "last_compact_at" => "2026-08-23T11:00:00Z",
      "pending_compact_continuation" => true,
      "context_length_last_checked_line" => 17
    })
    RetryBudget::CONTEXT_LENGTH.reset_if_stable!(@session, since: 65.seconds.ago)

    @session.reload
    assert_nil @session.metadata["compact_retry_count"]
    assert_equal true, @session.metadata["pending_compact_continuation"],
      "the compact still owes the user a continuation — only the budget is handed back"
    assert_equal 17, @session.metadata["context_length_last_checked_line"]
  end

  test "the MCP budget reset keeps the failed-server diagnosis" do
    @session.update!(metadata: {
      "mcp_retry_count" => 2,
      "mcp_last_retry_at" => "2026-08-23T11:00:00Z",
      "mcp_failed_servers" => [ { "name" => "slack", "error" => "timeout" } ]
    })

    RetryBudget::MCP_CONNECTION.reset_if_stable!(@session, since: 65.seconds.ago)

    @session.reload
    assert_nil @session.metadata["mcp_retry_count"]
    assert_nil @session.metadata["mcp_last_retry_at"]
    assert_equal [ { "name" => "slack", "error" => "timeout" } ], @session.metadata["mcp_failed_servers"]
  end

  test "sessions, stamped_sessions and exhausted_sessions scope by the budget's own keys" do
    spent = Session.create!(
      prompt: "Spent", agent_runtime: "claude_code", status: :failed,
      git_root: "https://github.com/test/repo.git", branch: "main",
      execution_provider: "local_filesystem",
      metadata: { "mcp_retry_count" => 3, "mcp_last_retry_at" => 1.hour.ago.iso8601 }
    )
    Session.create!(
      prompt: "Recovering", agent_runtime: "claude_code", status: :running,
      git_root: "https://github.com/test/repo.git", branch: "main",
      execution_provider: "local_filesystem",
      metadata: { "mcp_retry_count" => 1 }
    )

    budget = RetryBudget::MCP_CONNECTION

    assert_equal 2, budget.sessions.count
    assert_equal [ spent.id ], budget.stamped_sessions.pluck(:id)
    assert_equal [ spent.id ], budget.exhausted_sessions.pluck(:id)
    assert_equal 0, RetryBudget::SIGTERM.sessions.count, "another budget's key must not match"
  end
end
