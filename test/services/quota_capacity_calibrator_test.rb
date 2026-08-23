# frozen_string_literal: true

require "test_helper"

# The percentage-to-dollars translation. Anthropic reports quota as a bare
# percentage; this is what makes "the 5-hour window is at 76%" comparable to a
# reserve, a burn rate, or a decision about whether one more session fits.
class QuotaCapacityCalibratorTest < ActiveSupport::TestCase
  FIVE_HOUR = QuotaCapacityEstimate::FIVE_HOUR
  WEEKLY = QuotaCapacityEstimate::WEEKLY

  setup do
    SessionTokenUsage.delete_all
    AdhocTokenUsage.delete_all
    QuotaCapacityEstimate.delete_all
    ClaudeAccountQuotaSnapshot.delete_all
    @session = Session.create!(git_root: "https://github.com/t/r.git", prompt: "work",
                               genesis: SessionGenesis::WEB_UI)
  end

  # `output_tokens` Opus output tokens is `output_tokens * 25 / 1_000_000` dollars.
  def spend(usd:, at: 1.hour.ago, model: "claude-opus-5")
    SessionTokenUsage.create!(
      request_id: "req_#{SecureRandom.hex(6)}", model: model, agent_root: "zimmer",
      session_id: @session.id, called_at: at,
      input_tokens: 0, output_tokens: (usd * 1_000_000 / 25).round,
      cache_read_tokens: 0, cache_creation_tokens: 0
    )
  end

  # `five_hour_uncorrected` defaults to the same figure; the one test that cares
  # about the difference passes them apart.
  def measure(five_hour:, weekly:, five_hour_uncorrected: nil)
    ClaudeAccountPool::Measure.new(
      five_hour: five_hour, five_hour_uncorrected: five_hour_uncorrected || five_hour,
      weekly: weekly, worst_five_hour: five_hour, worst_weekly: weekly,
      account_count: 3, read_count: 3, weekly_spent_count: 0, blocked_count: 0,
      next_capacity_at: nil, next_weekly_reset: nil,
      five_hour_seconds_remaining: 1.hour.to_i, weekly_seconds_remaining: 1.day.to_i
    )
  end

  # --- the estimator ------------------------------------------------------------

  # The whole translation in one case: $400 of spend at 50% utilization means a
  # full window is worth $800.
  test "capacity is spend over utilization" do
    spend(usd: 400.0, at: 1.hour.ago)

    observation = QuotaCapacityCalibrator.observe(FIVE_HOUR, measure(five_hour: 0.50, weekly: 0.10))

    assert observation.usable?
    assert_in_delta 400.0, observation.cost_usd, 0.01
    assert_in_delta 0.50, observation.utilization, 0.0001
    assert_in_delta 800.0, observation.capacity_usd, 0.01
  end

  # Total spend over MEAN utilization is what makes the answer the POOL's whole
  # capacity rather than one account's — see the class comment for the algebra.
  test "the weekly window is measured over its own seven days" do
    spend(usd: 100.0, at: 3.days.ago)
    spend(usd: 50.0, at: 3.hours.ago)

    weekly = QuotaCapacityCalibrator.observe(WEEKLY, measure(five_hour: 0.10, weekly: 0.30))
    five = QuotaCapacityCalibrator.observe(FIVE_HOUR, measure(five_hour: 0.10, weekly: 0.30))

    assert_in_delta 150.0, weekly.cost_usd, 0.01, "the week sees both"
    assert_in_delta 500.0, weekly.capacity_usd, 0.01
    assert_in_delta 50.0, five.cost_usd, 0.01, "the 5-hour window sees only the recent one"
    assert_in_delta 500.0, five.capacity_usd, 0.01
  end

  # "In terms of Opus spend" is the unit the request asked for, and it is not the
  # same as the bill: Haiku volumes re-price to Opus money.
  test "spend is denominated in Opus, whatever model actually ran" do
    spend(usd: 20.0, model: "claude-haiku-4-5")

    observation = QuotaCapacityCalibrator.observe(FIVE_HOUR, measure(five_hour: 0.50, weekly: 0.10))

    # 800k Haiku output tokens bill at $5/M ($4) but re-price at Opus's $25/M.
    assert_in_delta 20.0, observation.cost_usd, 0.01
    assert_in_delta 40.0, observation.capacity_usd, 0.01
  end

  test "an unpriced model stays unpriced rather than inheriting Opus money" do
    spend(usd: 100.0, model: "some-future-model")

    observation = QuotaCapacityCalibrator.observe(FIVE_HOUR, measure(five_hour: 0.50, weekly: 0.10))

    refute observation.usable?, "a model with no rate contributes nothing to the numerator"
    assert_in_delta 0.0, observation.cost_usd, 0.01
  end

  # Zimmer's own inference spends against the same windows an agent session does.
  test "ad hoc spend counts toward the window it was billed against" do
    AdhocTokenUsage.create!(
      request_id: "req_adhoc", source: "cli_status_probe", model: "claude-opus-5",
      called_at: 1.hour.ago, input_tokens: 0, output_tokens: 4_000_000,
      cache_read_tokens: 0, cache_creation_tokens: 0
    )

    observation = QuotaCapacityCalibrator.observe(FIVE_HOUR, measure(five_hour: 0.50, weekly: 0.10))

    assert_in_delta 100.0, observation.cost_usd, 0.01
    assert_in_delta 200.0, observation.capacity_usd, 0.01
  end

  # The pooled 5-hour figure counts an account whose WEEK is spent as 100%, which
  # is right for deciding whether work can be served and wrong for dividing spend
  # by. Calibrating off it would inflate the denominator and under-report the
  # window, shrinking the budget the gate paces against.
  test "the 5-hour window calibrates off the uncorrected average, not the servability-corrected one" do
    spend(usd: 400.0, at: 1.hour.ago)

    # The pool reads 80% only because a weekly-spent account is counted as 100%;
    # the accounts' own 5-hour counters average 50%.
    observation = QuotaCapacityCalibrator.observe(
      FIVE_HOUR, measure(five_hour: 0.80, five_hour_uncorrected: 0.50, weekly: 0.10)
    )

    assert_in_delta 0.50, observation.utilization, 0.0001
    assert_in_delta 800.0, observation.capacity_usd, 0.01,
      "dividing by the corrected 0.80 would have said $500 — a fifth less budget than there is"
  end

  # --- the observations it refuses ----------------------------------------------

  test "a tiny denominator is refused rather than divided by" do
    spend(usd: 400.0)

    observation = QuotaCapacityCalibrator.observe(FIVE_HOUR, measure(five_hour: 0.001, weekly: 0.10))

    refute observation.usable?, "$400 over 0.1% implies a $400,000 window — noise, not a reading"
    assert_match(/too small a denominator/, observation.reason)
  end

  test "a window with almost no spend says nothing about how big it is" do
    spend(usd: 0.10)

    observation = QuotaCapacityCalibrator.observe(FIVE_HOUR, measure(five_hour: 0.50, weekly: 0.10))

    refute observation.usable?
    assert_match(/of spend in the window/, observation.reason)
  end

  test "a pool with no reading is refused" do
    spend(usd: 400.0)

    observation = QuotaCapacityCalibrator.observe(FIVE_HOUR, measure(five_hour: nil, weekly: 0.10))

    refute observation.usable?
    assert_match(/no pooled utilization reading/, observation.reason)
  end

  # --- persistence and smoothing -------------------------------------------------

  test "the first observation is taken whole" do
    spend(usd: 400.0, at: 1.hour.ago)
    stub_pool(five_hour: 0.50, weekly: 0.50) { QuotaCapacityCalibrator.calibrate! }

    estimate = QuotaCapacityEstimate.find_by(window_key: FIVE_HOUR)
    assert_in_delta 800.0, estimate.capacity_usd, 0.01,
      "seeding at a fraction of the truth would hold everything for the first hour of a deployment's life"
    assert_equal 1, estimate.observation_count
    assert estimate.usable?
  end

  test "later observations are smoothed into the estimate" do
    estimate = QuotaCapacityEstimate.create!(window_key: FIVE_HOUR, capacity_usd: 1000.0,
                                             observation_count: 1, computed_at: 1.hour.ago)

    estimate.absorb(observed: 2000.0, sample_cost_usd: 1.0, sample_utilization: 0.5)

    expected = (QuotaCapacityEstimate::SMOOTHING * 2000.0) +
               ((1 - QuotaCapacityEstimate::SMOOTHING) * 1000.0)
    assert_in_delta expected, estimate.capacity_usd, 0.0001
    assert_in_delta 2000.0, estimate.observed_capacity_usd, 0.0001,
      "the raw observation is kept so a surface can show its own provenance"
    assert_equal 2, estimate.observation_count
  end

  test "calibration is idempotent — a second run is a second observation, not corruption" do
    spend(usd: 400.0, at: 1.hour.ago)

    stub_pool(five_hour: 0.50, weekly: 0.50) do
      QuotaCapacityCalibrator.calibrate!
      QuotaCapacityCalibrator.calibrate!
    end

    assert_equal 1, QuotaCapacityEstimate.where(window_key: FIVE_HOUR).count
    estimate = QuotaCapacityEstimate.find_by(window_key: FIVE_HOUR)
    assert_equal 2, estimate.observation_count
    assert_in_delta 800.0, estimate.capacity_usd, 0.01, "the same observation twice moves nothing"
  end

  test "an unusable window writes nothing rather than a wrong number" do
    stub_pool(five_hour: 0.001, weekly: 0.001) { QuotaCapacityCalibrator.calibrate! }

    assert_equal 0, QuotaCapacityEstimate.count
  end

  test "the job records what the calibrator observes" do
    spend(usd: 400.0, at: 1.hour.ago)

    stub_pool(five_hour: 0.50, weekly: 0.50) { QuotaCapacityCalibrationJob.new.perform }

    assert_in_delta 800.0, QuotaCapacityEstimate.find_by(window_key: FIVE_HOUR).capacity_usd, 0.01
  end

  # --- the worked example --------------------------------------------------------

  # The production numbers this feature was calibrated against, end to end:
  # $18,563 of spend over seven days with the pool's weekly window at 70.71%
  # implies a ~$26,251 week.
  test "the production reading translates end to end" do
    spend(usd: 18_562.91, at: 2.days.ago)
    live = measure(five_hour: 0.7629, weekly: 0.7071)

    observation = QuotaCapacityCalibrator.observe(WEEKLY, live)
    assert_in_delta 26_251.0, observation.capacity_usd, 5.0

    QuotaCapacityEstimate.create!(window_key: WEEKLY, capacity_usd: observation.capacity_usd,
                                  computed_at: Time.current)
    setting = AppSetting.editable

    # A 20% reserve holds back ~$5,250 and leaves ~$21,001 for spot work, of
    # which ~$2,438 is still unspent — paced over the day the week has left,
    # that is about $1.69 a minute.
    setting.update!(spot_reserve_weekly_pct: 20)
    window = QuotaCapacityModel.windows(measure: live, setting: setting).fetch(WEEKLY)

    assert_in_delta 5_250.0, window.reserve_usd, 5.0
    assert_in_delta 21_001.0, window.spot_budget_usd, 5.0
    assert_in_delta 2_438.0, window.remaining_spot_usd, 5.0
    assert_in_delta 1.69, window.sustainable_units_per_minute, 0.02

    # …and the reserve production was actually running (a 70% fill target, so a
    # 30% reserve) is the state the old gate reported as HELD: the spot budget is
    # $18,376 and $18,563 has already gone, so there is nothing left to pace.
    setting.update!(spot_reserve_weekly_pct: 30)
    tighter = QuotaCapacityModel.windows(measure: live, setting: setting).fetch(WEEKLY)

    assert_in_delta 7_875.0, tighter.reserve_usd, 5.0
    assert_in_delta 18_376.0, tighter.spot_budget_usd, 5.0
    assert_in_delta 0.0, tighter.remaining_spot_usd, 0.0001
    refute tighter.within_cap?(0.0), "overspent by ~$187 — the model says held, and says by how much"
  end

  def stub_pool(five_hour:, weekly:, &block)
    ClaudeAccountPool.stub(:measure, measure(five_hour: five_hour, weekly: weekly), &block)
  end
end
