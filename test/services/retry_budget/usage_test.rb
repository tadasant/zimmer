# frozen_string_literal: true

require "test_helper"

class RetryBudget::UsageTest < ActiveSupport::TestCase
  test "every budget and the quota counts come from one read of sessions" do
    create_session(status: :running, "mcp_retry_count" => 1)

    queries = capture_session_queries do
      usage = RetryBudget::Usage.new
      RetryBudget.all.each { |budget| usage.for(budget, since: 24.hours.ago) }
      usage.quota_limited_count
      usage.quota_limited_count_since(24.hours.ago)
    end

    assert_equal 1, queries.size, queries.join("\n")
  end

  test "a budget counts only sessions carrying its own key" do
    create_session(status: :failed, "mcp_retry_count" => 3, "mcp_last_retry_at" => 1.hour.ago.iso8601)
    create_session(status: :running, "mcp_retry_count" => 1)

    mcp = usage_for(RetryBudget::MCP_CONNECTION)

    assert_equal 2, mcp[:total_sessions]
    assert_equal 4, mcp[:total_retries_attempted]
    assert_equal 1, mcp[:exhausted]
    assert_equal 1, mcp[:recovered]
    assert_equal 0, usage_for(RetryBudget::SIGTERM)[:total_sessions]
  end

  # Running out is not the same ending for every loop. All but one budget fail the session;
  # the empty-turn restart parks it in `needs_input` with an empty transcript. A hardcoded
  # `:failed` filter would report zero exhaustions for that one no matter how many sessions
  # Zimmer gave up restarting, and would count every one of them as a recovery.
  test "exhausted and recovered follow the terminal status each budget actually reaches" do
    create_session(status: :needs_input, "empty_turn_recovery_count" => RetryBudget::EMPTY_TURN.max)
    create_session(status: :running, "empty_turn_recovery_count" => 1)

    usage = usage_for(RetryBudget::EMPTY_TURN)

    assert_equal :needs_input, RetryBudget::EMPTY_TURN.terminal_status
    assert_equal 1, usage[:exhausted]
    assert_equal 1, usage[:recovered], "a session Zimmer gave up restarting is not a recovery"
  end

  test "recent is the ids of newer attempts, newest first" do
    older = create_session("last_sigterm_at" => 3.hours.ago.iso8601)
    newer = create_session("last_sigterm_at" => 1.hour.ago.iso8601)
    create_session("last_sigterm_at" => 30.hours.ago.iso8601)

    assert_equal [ newer.id, older.id ], usage_for(RetryBudget::SIGTERM)[:recent]
  end

  test "corrupt and null values are read as nothing rather than raising" do
    create_session("sigterm_retry_count" => "junk", "last_sigterm_at" => "not-a-time")
    create_session("sigterm_retry_count" => nil, "last_sigterm_at" => nil)

    usage = usage_for(RetryBudget::SIGTERM)

    assert_equal 1, usage[:total_sessions]
    assert_equal 0, usage[:total_retries_attempted]
    assert_empty usage[:recent]
  end

  test "metadata that is not an object does not take the read down" do
    session = create_session({})
    Session.where(id: session.id).update_all([ "metadata = ?::jsonb", [ "mcp_retry_count" ].to_json ])

    assert_equal 0, usage_for(RetryBudget::MCP_CONNECTION)[:total_sessions]
  end

  test "quota counts, all and recent" do
    create_session("last_quota_limit_at" => 2.hours.ago.iso8601)
    create_session("last_quota_limit_at" => 3.days.ago.iso8601)
    usage = RetryBudget::Usage.new

    assert_equal 2, usage.quota_limited_count
    assert_equal 1, usage.quota_limited_count_since(24.hours.ago)
  end

  private

  def usage_for(budget)
    RetryBudget::Usage.new.for(budget, since: 24.hours.ago)
  end

  def create_session(metadata = {}, status: :waiting, **rest)
    Session.create!(prompt: "x", agent_runtime: "claude_code", status: status,
      git_root: "https://github.com/test/repo.git", branch: "main", metadata: metadata.merge(rest.stringify_keys))
  end

  def capture_session_queries(&block)
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?('FROM "sessions"') }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
    queries
  end
end
