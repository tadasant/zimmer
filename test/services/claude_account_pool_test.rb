# frozen_string_literal: true

require "test_helper"

# The pool figure /inference prints and the spot gate decides on. These tests pin
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

  # ── when the pool next has capacity ──
  #
  # An account serves when BOTH its windows have room, so its own moment is the
  # later of the resets it is waiting on, and the pool's is the earliest of those.

  # The reported bug, in the shape production was in. The soonest thing that
  # unblocked the pool was a 7-day reset 22 minutes out, on an account whose
  # 5-hour window was already empty — and the page advertised a 5-hour reset
  # 3h52m out instead, because the two candidates were measured over disjoint
  # sets and an account blocked only by its week could never set the headline.
  test "the pool comes back on a weekly reset that frees an already-free 5-hour window" do
    weekly_back = 22.minutes.from_now
    five_hour_back = 232.minutes.from_now

    # 5-hour window empty, week spent: nothing to wait for but the week.
    seed(account("sam@example.com"), five_hour: 0.0, weekly: 1.0,
      reset_5h: 10.minutes.from_now, reset_7d: weekly_back)
    seed(account("jon@example.com"), five_hour: 0.0, weekly: 1.0,
      reset_5h: 15.minutes.from_now, reset_7d: 44.hours.from_now)
    seed(account("tadas412@example.com"), five_hour: 0.0, weekly: 1.0,
      reset_5h: 25.minutes.from_now, reset_7d: 83.hours.from_now)
    # Over its 5-hour cap, week still there: back when the 5-hour window rolls.
    seed(account("matt@example.com"), five_hour: 1.03, weekly: 0.79,
      reset_5h: five_hour_back, reset_7d: 5.days.from_now)
    seed(account("bob@example.com"), five_hour: 1.0, weekly: 0.10,
      reset_5h: 262.minutes.from_now, reset_7d: 6.days.from_now)
    seed(account("tadas@example.com"), five_hour: 1.0, weekly: 0.10,
      reset_5h: 262.minutes.from_now, reset_7d: 6.days.from_now)

    measure = ClaudeAccountPool.measure

    assert_in_delta weekly_back.to_f, measure.next_capacity_at.to_f, 5
    # The answer the old split reported, and the reason this test exists.
    assert measure.next_capacity_at < five_hour_back,
      "the weekly reset that frees free 5-hour headroom must beat the next 5-hour rollover"
    assert_not measure.capacity_now?
    assert_equal 6, measure.blocked_count
    assert_equal 3, measure.weekly_spent_count
  end

  test "an account blocked on both windows waits for the later of the two resets" do
    seed(account("both@example.com"), five_hour: 1.0, weekly: 1.0,
      reset_5h: 1.hour.from_now, reset_7d: 6.hours.from_now)

    assert_in_delta 6.hours.from_now.to_f, ClaudeAccountPool.measure.next_capacity_at.to_f, 5
  end

  test "a 5-hour window with room contributes nothing, however soon it rolls over" do
    seed(account("weekly-only@example.com"), five_hour: 0.30, weekly: 1.0,
      reset_5h: 2.minutes.from_now, reset_7d: 9.hours.from_now)

    assert_in_delta 9.hours.from_now.to_f, ClaudeAccountPool.measure.next_capacity_at.to_f, 5
  end

  test "the soonest account sets the pool's moment" do
    seed(account("late@example.com"), five_hour: 1.0, weekly: 0.20,
      reset_5h: 4.hours.from_now, reset_7d: 5.days.from_now)
    seed(account("soon@example.com"), five_hour: 1.0, weekly: 0.20,
      reset_5h: 40.minutes.from_now, reset_7d: 5.days.from_now)

    assert_in_delta 40.minutes.from_now.to_f, ClaudeAccountPool.measure.next_capacity_at.to_f, 5
  end

  # An account with room on both windows is serving now, so there is nothing for
  # the pool to wait for — and a rollover on it is not a wait either.
  test "an account with room on both windows leaves the pool with capacity now" do
    seed(account("healthy@example.com"), five_hour: 0.20, weekly: 0.10,
      reset_5h: 30.minutes.from_now, reset_7d: 2.days.from_now)
    seed(account("blocked@example.com"), five_hour: 1.0, weekly: 0.10,
      reset_5h: 45.minutes.from_now, reset_7d: 2.days.from_now)

    measure = ClaudeAccountPool.measure

    assert measure.capacity_now?
    assert_nil measure.next_capacity_at
    assert_equal 1, measure.blocked_count
    assert_equal 1, measure.servable_count
  end

  # A window past its reset has already rolled over — the same rule the counters
  # follow — so the account is serving, not waiting.
  test "a counter at the cap past its reset time is not a wait" do
    seed(account("rolled@example.com"), five_hour: 1.0, weekly: 0.30,
      reset_5h: 10.minutes.ago, reset_7d: 3.days.from_now)

    measure = ClaudeAccountPool.measure

    assert measure.capacity_now?
    assert_nil measure.next_capacity_at
  end

  # Blocked with no way to say when it returns. The pool is not serving, and
  # there is no moment to name — two different emptinesses, told apart by
  # capacity_now? rather than by the timestamp.
  test "a blocked account with no recorded reset names no moment" do
    reading = seed(account("blind@example.com"), five_hour: 0.20, weekly: nil, reset_7d: nil)
    reading.update!(status_7d: "rejected")

    measure = ClaudeAccountPool.measure

    assert_not measure.capacity_now?
    assert_nil measure.next_capacity_at
    assert_equal 1, measure.blocked_count
  end

  test "an account that cannot say when it returns does not shadow one that can" do
    blind = seed(account("blind@example.com"), five_hour: 0.20, weekly: nil, reset_7d: nil)
    blind.update!(status_7d: "rejected")
    seed(account("timed@example.com"), five_hour: 1.0, weekly: 0.20,
      reset_5h: 30.minutes.from_now, reset_7d: 4.days.from_now)

    measure = ClaudeAccountPool.measure

    assert_in_delta 30.minutes.from_now.to_f, measure.next_capacity_at.to_f, 5
    assert_equal 2, measure.blocked_count
  end

  # A status Anthropic is still refusing on takes the account out of service
  # whatever its counter reads, so it is a wait like any other.
  test "a refused 5-hour window is a wait even with headroom on the counter" do
    reading = seed(account("refused@example.com"), five_hour: 0.10, weekly: 0.10,
      reset_5h: 25.minutes.from_now, reset_7d: 3.days.from_now)
    reading.update!(status_5h: "rejected")

    measure = ClaudeAccountPool.measure

    assert_not measure.capacity_now?
    assert_in_delta 25.minutes.from_now.to_f, measure.next_capacity_at.to_f, 5
  end

  # ── the 7-day note under the weekly average ──

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

  # The count and the time describe different sets when a spent window carries no
  # reset timestamp: three accounts are spent, two of them can say when.
  test "the next 7-day reset is the soonest of the spent accounts that recorded one" do
    seed(account("timed@example.com"), five_hour: 0.20, weekly: 1.0, reset_7d: 3.days.from_now)
    seed(account("later@example.com"), five_hour: 0.20, weekly: 1.0, reset_7d: 5.days.from_now)
    blind = seed(account("blind@example.com"), five_hour: 0.20, weekly: nil, reset_7d: nil)
    blind.update!(status_7d: "rejected")

    measure = ClaudeAccountPool.measure

    assert_equal 3, measure.weekly_spent_count
    assert_in_delta 3.days.from_now.to_f, measure.next_weekly_reset.to_f, 5
  end

  test "an empty pool is waiting for nothing and serving nothing" do
    measure = ClaudeAccountPool.measure

    assert_nil measure.next_capacity_at
    assert_nil measure.next_weekly_reset
    assert_equal 0, measure.blocked_count
    assert_not measure.capacity_now?
    assert_not measure.any_readings?
  end
end
