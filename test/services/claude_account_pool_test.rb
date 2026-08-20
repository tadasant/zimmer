# frozen_string_literal: true

require "test_helper"

# The pool figure /quotas prints and the spot gate decides on. These tests pin
# down what goes into it — every account, whatever its status — because both
# surfaces read this one computation.
class ClaudeAccountPoolTest < ActiveSupport::TestCase
  setup do
    ClaudeAccountQuotaSnapshot.delete_all
    ClaudeAccount.delete_all
  end

  def account(email, status: :active, runtime: "claude_code")
    ClaudeAccount.create!(email: email, runtime: runtime, oauth_config: { "x" => 1 }, status: status)
  end

  def seed(account, five_hour:, weekly:, reset_5h: 2.hours.from_now, reset_7d: 2.days.from_now)
    ClaudeAccountQuotaSnapshot.create!(
      claude_account: account, utilization_5h: five_hour, utilization_7d: weekly,
      reset_5h: reset_5h, reset_7d: reset_7d, active_session_count: 1, trigger: "usage_sample"
    )
  end

  test "both windows are averaged across the accounts that have a reading" do
    seed(account("a@example.com"), five_hour: 0.90, weekly: 0.40)
    seed(account("b@example.com"), five_hour: 0.10, weekly: 0.20)

    measure = ClaudeAccountPool.measure

    assert_in_delta 0.50, measure.five_hour
    assert_in_delta 0.30, measure.weekly
    assert_in_delta 0.90, measure.worst_five_hour
    assert_in_delta 0.40, measure.worst_weekly
    assert_equal 2, measure.read_count
    assert_equal 2, measure.account_count
  end

  # The explicit ask: an account waiting on a human to re-authenticate still
  # holds quota, and its window keeps draining while it waits.
  test "a needs_reauth account is in the pool" do
    seed(account("serving@example.com"), five_hour: 0.90, weekly: 0.40)
    seed(account("reauth@example.com", status: :needs_reauth), five_hour: 0.10, weekly: 0.20)

    assert_in_delta 0.50, ClaudeAccountPool.measure.five_hour
    assert_equal 2, ClaudeAccountPool.measure.read_count
  end

  test "a quota_exceeded account is in the pool too" do
    seed(account("serving@example.com"), five_hour: 0.20, weekly: 0.40)
    seed(account("spent@example.com", status: :quota_exceeded), five_hour: 0.80, weekly: 0.60)

    assert_in_delta 0.50, ClaudeAccountPool.measure.five_hour
  end

  # An account whose week is gone cannot serve a request, so its empty 5-hour
  # counter is not headroom the pool can spend.
  test "an account whose 7-day window is spent counts as 100% in the 5-hour figure" do
    seed(account("healthy@example.com"), five_hour: 0.20, weekly: 0.10)
    seed(account("weekly-spent@example.com"), five_hour: 0.01, weekly: 1.0)

    measure = ClaudeAccountPool.measure

    assert_in_delta 0.60, measure.five_hour, 0.0001
    assert_equal 1, measure.weekly_spent_count
  end

  test "an account with no reading is not averaged, and the pool says so" do
    seed(account("read@example.com"), five_hour: 0.40, weekly: 0.30)
    account("unread@example.com")

    measure = ClaudeAccountPool.measure

    assert_in_delta 0.40, measure.five_hour
    assert_equal 1, measure.read_count
    assert_equal 2, measure.account_count
  end

  test "a reading with neither window readable contributes nothing" do
    seed(account("empty@example.com"), five_hour: nil, weekly: nil)

    measure = ClaudeAccountPool.measure

    assert_nil measure.five_hour
    assert_nil measure.weekly
    assert_equal 0, measure.read_count
    refute measure.any_readings?
  end

  test "a window past its reset carries nothing" do
    seed(account("reset@example.com"), five_hour: 0.99, weekly: 0.99,
         reset_5h: 1.minute.ago, reset_7d: 1.minute.ago)

    measure = ClaudeAccountPool.measure

    assert_in_delta 0.0, measure.five_hour
    assert_in_delta 0.0, measure.weekly
  end

  test "an empty pool has no readings" do
    measure = ClaudeAccountPool.measure

    refute measure.any_readings?
    assert_equal 0, measure.account_count
  end

  # Each runtime keeps its own pool; a Codex account spends nothing against the
  # Claude quota the gate is protecting.
  test "only the runtime's own accounts are pooled" do
    seed(account("claude@example.com"), five_hour: 0.20, weekly: 0.10)
    seed(account("codex@example.com", runtime: "codex"), five_hour: 1.0, weekly: 1.0)

    measure = ClaudeAccountPool.measure

    assert_in_delta 0.20, measure.five_hour
    assert_equal 1, measure.account_count
  end

  test "the latest reading per account is the one that counts" do
    acct = account("moving@example.com")
    seed(acct, five_hour: 0.90, weekly: 0.50)
    seed(acct, five_hour: 0.10, weekly: 0.20)

    measure = ClaudeAccountPool.measure

    assert_in_delta 0.10, measure.five_hour
    assert_equal 1, measure.read_count
  end

  # Two readings can share a timestamp — a rotation captures the outgoing and
  # incoming accounts in the same instant. Ordering by time alone then picks
  # arbitrarily, and the pool would average either one. Same tiebreaker
  # ClaudeAccount#latest_snapshot applies, for the same reason.
  test "readings that share a timestamp are broken by id, newest first" do
    acct = account("tied@example.com")
    stamp = 5.minutes.ago
    older = seed(acct, five_hour: 0.90, weekly: 0.50)
    newer = seed(acct, five_hour: 0.10, weekly: 0.20)
    ClaudeAccountQuotaSnapshot.where(id: [ older.id, newer.id ]).update_all(created_at: stamp)

    assert_in_delta 0.10, ClaudeAccountPool.measure.five_hour
  end

  # The reset times the Account Pool renders as "we're blocked until X".

  test "the next 5-hour reset is the soonest among accounts whose week is not spent" do
    seed(account("soon@example.com"), five_hour: 0.90, weekly: 0.30, reset_5h: 40.minutes.from_now)
    seed(account("later@example.com"), five_hour: 0.50, weekly: 0.20, reset_5h: 3.hours.from_now)

    assert_in_delta 40.minutes.from_now.to_f, ClaudeAccountPool.measure.next_five_hour_reset.to_f, 5
  end

  # The whole point of the figure: an account whose week is gone does not come
  # back when its 5-hour window rolls over, so its earlier reset must not be
  # reported as the moment the pool recovers.
  test "the next 5-hour reset ignores accounts whose 7-day window is spent" do
    seed(account("weekly-spent@example.com"), five_hour: 0.01, weekly: 1.0,
      reset_5h: 20.minutes.from_now, reset_7d: 2.days.from_now)
    seed(account("servable@example.com"), five_hour: 0.95, weekly: 0.40,
      reset_5h: 4.hours.from_now, reset_7d: 5.days.from_now)

    measure = ClaudeAccountPool.measure

    assert_in_delta 4.hours.from_now.to_f, measure.next_five_hour_reset.to_f, 5
    assert_in_delta 2.days.from_now.to_f, measure.next_weekly_reset.to_f, 5
  end

  test "the next 5-hour reset is nil when every account with a reading has spent its week" do
    seed(account("a@example.com"), five_hour: 0.0, weekly: 1.0, reset_5h: 30.minutes.from_now)
    seed(account("b@example.com"), five_hour: 0.0, weekly: 1.0, reset_5h: 90.minutes.from_now)

    measure = ClaudeAccountPool.measure

    assert_nil measure.next_five_hour_reset
    assert_equal 0, measure.weekly_available_count
  end

  # A weekly reset on an account that was never blocked returns nothing, so it
  # is not what the pool is waiting for.
  test "the next 7-day reset is the soonest among accounts whose week IS spent" do
    seed(account("healthy@example.com"), five_hour: 0.20, weekly: 0.10, reset_7d: 1.day.from_now)
    seed(account("spent@example.com"), five_hour: 0.20, weekly: 1.0, reset_7d: 4.days.from_now)

    assert_in_delta 4.days.from_now.to_f, ClaudeAccountPool.measure.next_weekly_reset.to_f, 5
  end

  test "the next 7-day reset is nil when no account's week is spent" do
    seed(account("healthy@example.com"), five_hour: 0.20, weekly: 0.10, reset_7d: 1.day.from_now)

    measure = ClaudeAccountPool.measure

    assert_nil measure.next_weekly_reset
    assert_equal 0, measure.weekly_spent_count
    assert_equal 1, measure.weekly_available_count
  end

  # A timestamp in the past describes a window that has already rolled over —
  # the same rule the counters follow — so it is not a wait.
  test "a reset time already in the past is not reported as the next reset" do
    seed(account("rolled@example.com"), five_hour: 0.90, weekly: 0.30,
      reset_5h: 10.minutes.ago, reset_7d: 3.days.from_now)

    assert_nil ClaudeAccountPool.measure.next_five_hour_reset
  end

  # A refused 7-day window with no reset timestamp is spent with no known way
  # back. The count says so even though there is no time to report.
  test "a spent week with no recorded reset time leaves the 7-day reset nil" do
    reading = seed(account("blind@example.com"), five_hour: 0.20, weekly: nil, reset_7d: nil)
    reading.update!(status_7d: "rejected")

    measure = ClaudeAccountPool.measure

    assert_equal 1, measure.weekly_spent_count
    assert_nil measure.next_weekly_reset
  end
end
