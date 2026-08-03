# frozen_string_literal: true

require "test_helper"

class ClaudeUsageRateServiceTest < ActiveSupport::TestCase
  setup do
    @account = ClaudeAccount.create!(email: "rate-test@example.com", runtime: "claude_code", oauth_config: { "x" => 1 })
    @now = Time.current
  end

  def snapshot(minutes_ago:, util_5h:, sessions:, reset_5h: nil, util_7d: nil, reset_7d: nil)
    ClaudeAccountQuotaSnapshot.create!(
      claude_account: @account,
      utilization_5h: util_5h,
      utilization_7d: util_7d,
      reset_5h: reset_5h || (@now + 3.hours),
      reset_7d: reset_7d || (@now + 3.days),
      active_session_count: sessions,
      trigger: "usage_sample",
      created_at: @now - minutes_ago.minutes
    )
  end

  test "computes utilization consumed per session-hour" do
    # 2 sessions running for 1 hour consume 10 points of the 5h window.
    # => 0.10 / (2 × 1h) = 0.05 per session-hour.
    snapshot(minutes_ago: 90, util_5h: 0.10, sessions: 2)
    snapshot(minutes_ago: 30, util_5h: 0.20, sessions: 2)

    result = ClaudeUsageRateService.call(now: @now)

    assert_equal 1, result.sample_count
    assert_in_delta 2.0, result.session_hours, 0.001
    assert_in_delta 0.05, result.rate_5h, 0.0001
    assert_in_delta 5.0, result.rate_5h_pct, 0.01
  end

  test "skips a pair that straddles a window reset" do
    # reset_5h moves forward: the later reading counts against a new allowance,
    # so the difference between the two measures nothing.
    snapshot(minutes_ago: 90, util_5h: 0.90, sessions: 1, reset_5h: @now - 10.minutes)
    snapshot(minutes_ago: 30, util_5h: 0.05, sessions: 1, reset_5h: @now + 4.hours)

    result = ClaudeUsageRateService.call(now: @now)
    assert_equal 0, result.sample_count
    assert_nil result.rate_5h
  end

  test "drops a falling counter rather than recording negative usage" do
    snapshot(minutes_ago: 90, util_5h: 0.40, sessions: 1)
    snapshot(minutes_ago: 30, util_5h: 0.30, sessions: 1)

    result = ClaudeUsageRateService.call(now: @now)
    assert_equal 0, result.sample_count
  end

  test "drops a pair with no session-count denominator" do
    snapshot(minutes_ago: 90, util_5h: 0.10, sessions: nil)
    snapshot(minutes_ago: 30, util_5h: 0.20, sessions: nil)

    result = ClaudeUsageRateService.call(now: @now)
    assert_equal 0, result.sample_count
    assert_nil result.rate_5h
  end

  test "drops a pair with zero sessions running" do
    snapshot(minutes_ago: 90, util_5h: 0.10, sessions: 0)
    snapshot(minutes_ago: 30, util_5h: 0.20, sessions: 0)

    result = ClaudeUsageRateService.call(now: @now)
    assert_equal 0, result.sample_count
  end

  test "drops a pair separated by more than the max gap" do
    snapshot(minutes_ago: 300, util_5h: 0.10, sessions: 2)
    snapshot(minutes_ago: 30, util_5h: 0.20, sessions: 2)

    result = ClaudeUsageRateService.call(now: @now)
    assert_equal 0, result.sample_count
  end

  test "ignores snapshots older than the lookback" do
    snapshot(minutes_ago: 600, util_5h: 0.10, sessions: 2)
    snapshot(minutes_ago: 570, util_5h: 0.90, sessions: 2)

    result = ClaudeUsageRateService.call(lookback: 2.hours, now: @now)
    assert_equal 0, result.sample_count
  end

  test "sufficient? needs at least MIN_SAMPLES usable pairs" do
    # Four evenly spaced readings => three pairs.
    snapshot(minutes_ago: 120, util_5h: 0.10, sessions: 1)
    snapshot(minutes_ago: 90, util_5h: 0.15, sessions: 1)
    snapshot(minutes_ago: 60, util_5h: 0.20, sessions: 1)
    snapshot(minutes_ago: 30, util_5h: 0.25, sessions: 1)

    result = ClaudeUsageRateService.call(now: @now)
    assert_equal 3, result.sample_count
    assert result.sufficient?
  end

  test "an empty history is not sufficient and reports no rate" do
    result = ClaudeUsageRateService.call(now: @now)
    refute result.sufficient?
    assert_nil result.rate_5h
    assert_equal 0, result.sample_count
  end

  test "active_session_count counts only running Claude Code sessions" do
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "a", status: :running, agent_runtime: "claude_code")
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "b", status: :waiting, agent_runtime: "claude_code")
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "c", status: :running, agent_runtime: "codex")

    assert_equal 1, ClaudeUsageRateService.active_session_count
  end
end
