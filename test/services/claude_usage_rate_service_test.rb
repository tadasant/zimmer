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

  test "ignores readings whose account has been deleted" do
    # Orphaned snapshots all share a nil account id, so pairing across them would
    # splice two accounts' readings into one series and invent the consumption
    # between them.
    snapshot(minutes_ago: 90, util_5h: 0.10, sessions: 2).update_column(:claude_account_id, nil)
    snapshot(minutes_ago: 30, util_5h: 0.90, sessions: 2).update_column(:claude_account_id, nil)

    result = ClaudeUsageRateService.call(now: @now)

    assert_equal 0, result.sample_count
    assert_nil result.rate_5h
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

  # Regression: the two windows used to share one session-hours denominator, so a
  # pair straddling a 5h reset (while the weekly counter ran straight through)
  # credited hours to the 5h rate whose numerator got nothing — understating it.
  test "a one-sided window reset does not dilute the other window's rate" do
    # 7d rises steadily across all three pairs. 5h rises for the first, then its
    # window resets, so only the first pair is usable for 5h.
    snapshot(minutes_ago: 90, util_5h: 0.10, util_7d: 0.10, sessions: 1, reset_5h: @now + 1.hour)
    snapshot(minutes_ago: 60, util_5h: 0.20, util_7d: 0.20, sessions: 1, reset_5h: @now + 1.hour)
    snapshot(minutes_ago: 30, util_5h: 0.05, util_7d: 0.30, sessions: 1, reset_5h: @now + 4.hours)

    result = ClaudeUsageRateService.call(now: @now)

    # 5h: one usable pair, 0.10 over 0.5 session-hours => 0.20/session-hour.
    assert_in_delta 0.20, result.rate_5h, 0.0001
    # 7d: two usable pairs, 0.20 over 1.0 session-hours => 0.20/session-hour.
    # Sharing a denominator would have halved the 5h figure to 0.10.
    assert_in_delta 0.20, result.rate_7d, 0.0001
  end

  # Regression: the two windows used to share one session-hour denominator, so a
  # pair straddling a 5-hour reset (while the weekly counter ran straight through)
  # credited hours to the 5h rate that its numerator never saw, understating it.
  # A 5h reset happens every five hours against a six-hour lookback, so this is
  # the common case in production, not an edge one.
  test "a reset in one window does not dilute the other window's rate" do
    # 7d rises 0.01 per half hour throughout. 5h rises too, but its window resets
    # between the second and third readings.
    snapshot(minutes_ago: 90, util_5h: 0.10, util_7d: 0.10, sessions: 1, reset_5h: @now + 3.hours)
    snapshot(minutes_ago: 60, util_5h: 0.20, util_7d: 0.11, sessions: 1, reset_5h: @now + 3.hours)
    snapshot(minutes_ago: 30, util_5h: 0.02, util_7d: 0.12, sessions: 1, reset_5h: @now + 5.hours)
    snapshot(minutes_ago: 0,  util_5h: 0.12, util_7d: 0.13, sessions: 1, reset_5h: @now + 5.hours)

    result = ClaudeUsageRateService.call(now: @now)

    # 5h: two usable pairs (the reset pair dropped), 0.10 each over 0.5 session-hours
    # => 0.20 / 1.0 = 0.20 per session-hour.
    assert_in_delta 0.20, result.rate_5h, 0.0001
    # 7d: three usable pairs, 0.01 each over 1.5 session-hours
    # => 0.03 / 1.5 = 0.02 per session-hour. Unaffected by the 5h reset.
    assert_in_delta 0.02, result.rate_7d, 0.0001
  end

  test "active_session_count counts only running Claude Code sessions" do
    # Measured as a delta: the fixture set already contains sessions, and this
    # asserts what the three new rows contribute, not the absolute total.
    before = ClaudeUsageRateService.active_session_count

    Session.create!(git_root: "https://github.com/t/r.git", prompt: "a", status: :running, agent_runtime: "claude_code")
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "b", status: :waiting, agent_runtime: "claude_code")
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "c", status: :running, agent_runtime: "codex")

    assert_equal before + 1, ClaudeUsageRateService.active_session_count,
      "only the running claude_code session counts"
  end
end
