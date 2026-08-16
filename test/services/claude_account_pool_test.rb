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
end
