# frozen_string_literal: true

require "test_helper"

# The copy on /quotas and in `get_spot_policy`, built from a real decision rather
# than a stub — the bug this class fixes was a view branching on the wrong field,
# so a test that hand-builds the decision would not have caught it.
class SpotHoldExplanationTest < ActiveSupport::TestCase
  setup do
    ClaudeAccountQuotaSnapshot.delete_all
    ClaudeAccount.update_all(is_current: false)
    Session.where(status: :running).update_all(status: Session.statuses[:needs_input])
    HarnessModelBurnRate.delete_all
    @account = ClaudeAccount.create!(
      email: "explainer-test@example.com", runtime: "claude_code",
      oauth_config: { "x" => 1 }, is_current: true
    )
    @setting = AppSetting.editable
    @setting.update!(spot_gating_enabled: true,
                     spot_reserve_five_hour_pct: 20,
                     spot_reserve_weekly_pct: 20,
                     spot_max_concurrent_sessions: 10)
  end

  def seed(current_5h:, current_7d: 0.05, reset_5h: 2.hours.from_now, reset_7d: 2.days.from_now)
    ClaudeAccountQuotaSnapshot.create!(
      claude_account: @account,
      utilization_5h: current_5h, utilization_7d: current_7d,
      reset_5h: reset_5h, reset_7d: reset_7d,
      active_session_count: 1, trigger: "usage_sample"
    )
  end

  def calibrate(capacity_usd: 1000.0, window: QuotaCapacityEstimate::FIVE_HOUR)
    QuotaCapacityEstimate.create!(window_key: window, capacity_usd: capacity_usd,
                                  sample_cost_usd: capacity_usd / 2, sample_utilization: 0.5,
                                  observation_count: 5, computed_at: Time.current)
  end

  def burn_rate(usd_per_minute)
    HarnessModelBurnRate.delete_all
    HarnessModelBurnRate.create!(harness: "zimmer", model: "claude-opus-5",
                                 usd_per_minute: usd_per_minute,
                                 sample_cost_usd: usd_per_minute * 100, sample_minutes: 100.0,
                                 sample_session_count: 25, computed_at: Time.current)
  end

  def running_session(index)
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "running #{index}",
                    genesis: SessionGenesis::WEB_UI, status: :running, agent_runtime: "claude_code")
  end

  def explain(decision, paused_count: 0)
    SpotHoldExplanation.new(decision, paused_count: paused_count)
  end

  # The decision that produced Tadas's screenshot: budget left, but the fleet is
  # outrunning the curve. This is the case the old copy got wrong.
  def pacing_hold
    calibrate(capacity_usd: 1000.0)
    seed(current_5h: 0.30, reset_5h: 100.minutes.from_now)
    burn_rate(4.0)
    running_session(0)

    SpotGateService.evaluate.tap do |d|
      refute d.allowed?
      assert d.five_hour.within_cap, "the budget must NOT be spent for this to be the pacing case"
    end
  end

  def budget_hold
    calibrate(capacity_usd: 1000.0)
    seed(current_5h: 0.79, reset_5h: 100.minutes.from_now)
    burn_rate(2.0)

    SpotGateService.evaluate.tap do |d|
      refute d.allowed?
      refute d.five_hour.within_cap
    end
  end

  # --- which ceiling -----------------------------------------------------------

  test "a pacing hold says the budget has room and that nothing is being paused" do
    lines = explain(pacing_hold).lines

    assert_equal [ "Why it's held", "Held until" ], lines.map(&:label)
    why = lines.first.sentence
    assert_match(/5-hour window's spot budget still has \$500 left/, why)
    # The comparison the gate made is fleet + candidate, not the fleet alone.
    assert_match(%r{fleet at \$4\.00/min plus the \$4\.00/min the next spot session is priced at}, why)
    assert_match(%r{comes to \$8\.00/min, against \$5\.00/min sustainable}, why)
    assert_match(/already running are not paused for this/, why)
  end

  test "a spent budget says so, and says it is the ceiling that pauses running work" do
    why = explain(budget_hold).lines.first.sentence

    assert_match(/5-hour window's spot budget is spent/, why)
    assert_match(/also pauses spot sessions already running/, why)
  end

  test "the fleet cap names the slots, and no window" do
    @setting.update!(spot_max_concurrent_sessions: 2)
    calibrate(capacity_usd: 1000.0)
    seed(current_5h: 0.10)
    burn_rate(0.01)
    2.times { |i| running_session(i) }

    decision = SpotGateService.evaluate
    assert_equal SpotGateService::FLEET_CAP_REASON, decision.reason
    assert_equal :fleet_cap, decision.ceiling

    lines = explain(decision).lines
    assert_match(/Every session slot is taken — 2 of 2/, lines.first.sentence)
    assert_match(/No quota window is holding anything/, lines.first.sentence)
    assert_match(/A slot frees up when a running session finishes/, lines.last.sentence)
  end

  # --- held until --------------------------------------------------------------

  # The whole reason this ships a condition rather than an ETA: while the fleet
  # outruns the curve, the sustainable rate falls, so waiting widens the gap.
  test "a pacing hold refuses to give an ETA and names the burn rate instead" do
    held_until = explain(pacing_hold).lines.last.sentence

    # $5.00/min sustainable less the $4.00/min the next session is priced at.
    assert_match(%r{When the fleet's burn falls below \$1\.00/min}, held_until)
    assert_match(%r{\$5\.00/min sustainable, less the \$4\.00/min}, held_until)
    assert_match(/Waiting alone does not get there/, held_until)
    assert_match(/upper bound on the wait, not a forecast/, held_until)
    # The rollover is offered as the backstop, and it is the window that refused.
    assert_match(/5-hour window's rollover refills the budget, about .* from now/, held_until)
    assert_match(/estimated from the pool average/, held_until)
  end

  test "a spent budget is held until the rollover, and says no sooner" do
    held_until = explain(budget_hold).lines.last.sentence

    assert_match(/No sooner than the 5-hour window's rollover, about .* from now/, held_until)
    assert_match(/Only a rollover puts money back in the budget/, held_until)
  end

  # A window with no rollover time cannot be turned into a clock, and the copy
  # must not invent one. Only the cap can refuse without a rollover time — with
  # no time axis there is no curve to be ahead of (Window#within_pace?).
  test "no rollover time means no time in the sentence" do
    calibrate(capacity_usd: 1000.0)
    seed(current_5h: 0.85, reset_5h: nil)
    burn_rate(2.0)

    decision = SpotGateService.evaluate
    refute decision.allowed?
    assert_equal :spot_budget, decision.ceiling

    held_until = explain(decision).lines.last.sentence
    assert_equal "The 5-hour window's rollover, which could not be read.", held_until
  end

  # One session alone priced above the sustainable rate: there is no fleet burn
  # low enough that admits it, and saying "falls below -$1.00/min" would be
  # nonsense. The duty cycle the idle-fleet waiver produces is the real answer.
  test "a session priced above the whole sustainable rate says the fleet must empty" do
    calibrate(capacity_usd: 1000.0)
    seed(current_5h: 0.30, reset_5h: 100.minutes.from_now)
    burn_rate(6.0)
    running_session(0)

    decision = SpotGateService.evaluate
    assert_equal :pacing_curve, decision.ceiling

    held_until = explain(decision).lines.last.sentence
    assert_match(/Not until the fleet empties/, held_until)
    refute_match(/falls below -/, held_until)
  end

  # --- how many sessions -------------------------------------------------------

  test "the asleep line separates the backlog from what the ceiling is doing now" do
    pacing = explain(pacing_hold, paused_count: 17).sessions_asleep

    assert_match(/\AEach was paused mid-run when a window's spot budget ran out/, pacing)
    assert_match(/asleep rather than running, so they count toward neither the sessions-running figure nor the concurrency limit/, pacing)
    assert_match(/The ceiling is not pausing anything right now/, pacing)
  end

  test "a spent budget says the ceiling IS pausing running sessions right now" do
    assert_match(/The ceiling is pausing running spot sessions right now/,
      explain(budget_hold, paused_count: 3).sessions_asleep)
  end

  test "zero asleep is stated rather than left as a bare zero" do
    assert_equal "None is asleep in the spot queue.",
      explain(pacing_hold, paused_count: 0).sessions_asleep
  end

  test "one asleep session is singular" do
    singular = explain(pacing_hold, paused_count: 1).sessions_asleep
    assert_match(/\AIt was paused mid-run/, singular)
    assert_match(/It resumes automatically/, singular)
  end

  # --- not held ----------------------------------------------------------------

  test "there is nothing to explain when spot work is running" do
    calibrate(capacity_usd: 1000.0)
    seed(current_5h: 0.10)
    burn_rate(0.01)

    decision = SpotGateService.evaluate
    assert decision.allowed?
    assert_empty explain(decision).lines
    # The backlog line still renders — a queue left over from an earlier ceiling
    # is worth seeing after the gate reopens.
    assert_match(/\AEach was paused mid-run/, explain(decision, paused_count: 4).sessions_asleep)
  end
end
