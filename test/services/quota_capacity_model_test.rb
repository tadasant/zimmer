# frozen_string_literal: true

require "test_helper"

# The unified model: capacity, the reserve carved out of it, and the pacing
# curve that fills the rest. Every figure the /quotas page and `get_spot_policy`
# render comes from here, and so does every decision the spot gate makes.
class QuotaCapacityModelTest < ActiveSupport::TestCase
  FIVE_HOUR = QuotaCapacityEstimate::FIVE_HOUR
  WEEKLY = QuotaCapacityEstimate::WEEKLY

  # A window built directly, so the arithmetic can be tested without a pool, a
  # snapshot, or a calibration run standing between the inputs and the answer.
  def window(capacity_usd: 1000.0, utilization: 0.0, reserve_pct: 20,
             seconds_remaining: 5.hours.to_i, margin_pct: 0, key: FIVE_HOUR)
    QuotaCapacityModel::Window.new(
      key: key, utilization: utilization, reserve_pct: reserve_pct,
      seconds_remaining: seconds_remaining, capacity_usd: capacity_usd, margin_pct: margin_pct
    )
  end

  # --- capacity, reserve, budget -----------------------------------------------

  test "the reserve is a percentage in and dollars out" do
    w = window(capacity_usd: 1000.0, reserve_pct: 20)

    assert w.dollars?
    assert_in_delta 200.0, w.reserve_usd, 0.0001, "20% of a $1,000 window"
    assert_in_delta 800.0, w.spot_budget_usd, 0.0001
    assert_in_delta 1000.0, w.remaining_usd, 0.0001, "nothing spent yet"
  end

  test "spend eats the remaining figures in dollars" do
    w = window(capacity_usd: 1000.0, utilization: 0.30, reserve_pct: 20)

    assert_in_delta 300.0, w.spent_usd, 0.0001
    assert_in_delta 700.0, w.remaining_usd, 0.0001
    assert_in_delta 500.0, w.remaining_spot_usd, 0.0001, "$800 of budget less $300 spent"
  end

  # The edge cases the control has to survive at both ends.
  test "a zero reserve leaves the whole window to spot work" do
    w = window(capacity_usd: 1000.0, reserve_pct: 0)

    assert_in_delta 0.0, w.reserve_usd, 0.0001
    assert_in_delta 1000.0, w.spot_budget_usd, 0.0001
  end

  test "a full reserve leaves spot work nothing" do
    w = window(capacity_usd: 1000.0, reserve_pct: 100)

    assert_in_delta 1000.0, w.reserve_usd, 0.0001
    assert_in_delta 0.0, w.spot_budget_usd, 0.0001
    assert_in_delta 0.0, w.remaining_spot_usd, 0.0001
    refute w.within_cap?(0.01), "no burn rate at all fits inside a zero budget"
  end

  test "remaining never goes negative when the window is overspent" do
    w = window(capacity_usd: 1000.0, utilization: 0.95, reserve_pct: 20)

    assert_in_delta 50.0, w.remaining_usd, 0.0001
    assert_in_delta 0.0, w.remaining_spot_usd, 0.0001,
      "$950 spent against an $800 budget is zero left, not minus $150"
    refute w.within_cap?(0.0)
  end

  # --- the pacing curve --------------------------------------------------------

  test "the sustainable rate empties the spot budget exactly at rollover" do
    w = window(capacity_usd: 1000.0, utilization: 0.0, reserve_pct: 20, seconds_remaining: 5.hours.to_i)

    # $800 over 300 minutes.
    assert_in_delta 800.0 / 300, w.sustainable_units_per_minute, 0.0001
    assert_in_delta 0.0, w.elapsed_fraction, 0.0001

    # Spending at exactly that rate for the whole window lands on the budget.
    assert_in_delta 800.0, w.sustainable_units_per_minute * 300, 0.0001
  end

  # Self-correcting downward: run ahead and the rate that is still sustainable
  # falls, which is what throttles the fleet instead of stopping it dead.
  test "spending ahead of the curve lowers the sustainable rate rather than hitting a cliff" do
    early = window(capacity_usd: 1000.0, utilization: 0.0, seconds_remaining: 5.hours.to_i)
    ahead = window(capacity_usd: 1000.0, utilization: 0.50, seconds_remaining: 4.hours.to_i)

    assert ahead.sustainable_units_per_minute < early.sustainable_units_per_minute
    assert ahead.sustainable_units_per_minute.positive?,
      "a throttle, not a stop — there is still $300 of budget and four hours to spend it"
    assert_in_delta 300.0 / 240, ahead.sustainable_units_per_minute, 0.0001
  end

  # …and upward: a window that has been quiet releases work FASTER, which is what
  # gets the budget consumed rather than left on the table.
  test "spending behind the curve raises the sustainable rate" do
    behind = window(capacity_usd: 1000.0, utilization: 0.10, seconds_remaining: 1.hour.to_i)

    assert_in_delta 700.0 / 60, behind.sustainable_units_per_minute, 0.0001,
      "$700 of budget left and an hour to spend it: over $11 a minute"
    assert behind.within_pace?(10.0), "a $10/min fleet is inside that"
    refute behind.within_pace?(12.0)
  end

  # The far end of the window: the rate goes to infinity because the allowance is
  # use-it-or-lose-it. The CAP is what stops that eating the reserve.
  test "at the rollover instant the pace is unbounded but the cap still binds" do
    w = window(capacity_usd: 1000.0, utilization: 0.79, reserve_pct: 20, seconds_remaining: 0)

    assert w.sustainable_units_per_minute.infinite?
    assert w.within_pace?(1_000_000.0), "nothing is too fast in the last instant"
    refute w.within_cap?(1_000_000.0), "…but the reserve is still protected"
    assert w.within_cap?(0.05), "a small burn still fits in the $10 that is left"
  end

  test "a window with no rollover time has no curve, and the cap alone decides" do
    w = window(capacity_usd: 1000.0, utilization: 0.50, seconds_remaining: nil)

    assert_nil w.elapsed_fraction
    assert_nil w.sustainable_units_per_minute
    assert w.within_pace?(999.0), "no time axis means nothing to be ahead of"
    assert w.within_cap?(1.0)
    refute w.within_cap?(100.0), "the cap is unaffected by the missing clock"
  end

  # --- the cap projects, it does not merely compare -----------------------------

  test "the cap refuses a session whose projected spend would cross the reserve" do
    # $790 spent of an $800 budget: $10 of room over a ten-minute lookahead.
    w = window(capacity_usd: 1000.0, utilization: 0.79, reserve_pct: 20)

    assert w.within_cap?(1.0), "$1/min for 10 minutes is $10 — exactly the room left"
    refute w.within_cap?(1.5), "$15 would spend $5 of the priority reserve"
    assert_in_delta 800.0, w.projected_spend_units(1.0), 0.0001
  end

  test "the lookahead is the gate's own re-check interval" do
    assert_equal SpotGateService::RETRY_DELAY, QuotaCapacityModel::LOOKAHEAD,
      "the cap has to hold until the next decision, so the two must not drift"
  end

  # --- the resume margin --------------------------------------------------------

  test "the resume margin widens the reserve without changing what the page shows" do
    plain = window(capacity_usd: 1000.0, reserve_pct: 20)
    resuming = window(capacity_usd: 1000.0, reserve_pct: 20, margin_pct: 5)

    assert_in_delta 800.0, plain.spot_budget_usd, 0.0001
    assert_in_delta 750.0, resuming.spot_budget_usd, 0.0001, "5 more points held back"
    assert_in_delta 200.0, resuming.reserve_usd, 0.0001,
      "the RESERVE the operator set is still $200 — the margin is not part of the policy on screen"
  end

  test "the margin cannot drive the spot budget below zero" do
    w = window(capacity_usd: 1000.0, reserve_pct: 98, margin_pct: 5)

    assert_in_delta 0.0, w.spot_budget_usd, 0.0001
  end

  # --- degrading to percentages -------------------------------------------------

  # Before any calibration has run there is nothing honest to say in dollars, and
  # the model has to say so rather than print a zero.
  test "without a capacity estimate the window reasons in window-fractions" do
    w = window(capacity_usd: nil, utilization: 0.30, reserve_pct: 20)

    refute w.dollars?
    assert_nil w.capacity_usd
    assert_nil w.remaining_usd, "nil is 'we don't know', which is not the same claim as $0.00"
    assert_nil w.reserve_usd
    assert_in_delta 1.0, w.capacity_units, 0.0001
    assert_in_delta 0.30, w.spent_units, 0.0001
    assert_in_delta 0.80, w.spot_budget_units, 0.0001
    assert_in_delta 0.50, w.remaining_spot_units, 0.0001
  end

  test "the fraction mode reaches 100% of the spot budget at rollover too" do
    w = window(capacity_usd: nil, utilization: 0.0, reserve_pct: 20, seconds_remaining: 5.hours.to_i)

    assert_in_delta 0.8 / 300, w.sustainable_units_per_minute, 0.000001
  end

  # --- building both windows from a pool measure --------------------------------

  test "windows are built from the pool reading and the operator's two reserves" do
    setting = AppSetting.editable
    setting.update!(spot_reserve_five_hour_pct: 25, spot_reserve_weekly_pct: 40)
    QuotaCapacityEstimate.create!(window_key: FIVE_HOUR, capacity_usd: 500.0, computed_at: Time.current)

    windows = QuotaCapacityModel.windows(measure: measure(five_hour: 0.40, weekly: 0.10), setting: setting)

    five = windows.fetch(FIVE_HOUR)
    assert five.dollars?
    assert_equal 25, five.reserve_pct
    assert_in_delta 125.0, five.reserve_usd, 0.0001
    assert_in_delta 200.0, five.spent_usd, 0.0001

    weekly = windows.fetch(WEEKLY)
    refute weekly.dollars?, "only the 5-hour window has been calibrated"
    assert_equal 40, weekly.reserve_pct
  end

  test "a window the pool could not read is omitted rather than guessed at" do
    windows = QuotaCapacityModel.windows(measure: measure(five_hour: 0.4, weekly: nil),
                                         setting: AppSetting.editable)

    assert_includes windows.keys, FIVE_HOUR
    refute_includes windows.keys, WEEKLY
  end

  # An estimate the calibration cron has stopped refreshing is not one the model
  # may go on quoting dollars from.
  test "a stale estimate degrades the window to fractions rather than quoting old dollars" do
    QuotaCapacityEstimate.create!(
      window_key: FIVE_HOUR, capacity_usd: 500.0,
      computed_at: (QuotaCapacityEstimate::FRESHNESS_HORIZON + 1.hour).ago
    )

    windows = QuotaCapacityModel.windows(measure: measure(five_hour: 0.4, weekly: 0.1),
                                         setting: AppSetting.editable)

    refute windows.fetch(FIVE_HOUR).dollars?
  end

  def measure(five_hour:, weekly:, five_hour_seconds_remaining: 2.hours.to_i,
              weekly_seconds_remaining: 2.days.to_i)
    ClaudeAccountPool::Measure.new(
      five_hour: five_hour, weekly: weekly, worst_five_hour: five_hour, worst_weekly: weekly,
      account_count: 1, read_count: 1, weekly_spent_count: 0, blocked_count: 0,
      next_capacity_at: nil, next_weekly_reset: nil,
      five_hour_seconds_remaining: five_hour_seconds_remaining,
      weekly_seconds_remaining: weekly_seconds_remaining
    )
  end
end
