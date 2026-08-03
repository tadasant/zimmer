# frozen_string_literal: true

require "test_helper"

class SpotGateServiceTest < ActiveSupport::TestCase
  setup do
    @now = Time.current
    # The forecast reads the SERVING account's snapshots and multiplies by the
    # running fleet, so a fixture account or a fixture session in `running`
    # silently changes the arithmetic these tests assert on. Clear both, then
    # build the one account this suite forecasts from.
    ClaudeAccount.update_all(is_current: false)
    Session.where(status: :running).update_all(status: Session.statuses[:needs_input])
    @account = ClaudeAccount.create!(
      email: "gate-test@example.com", runtime: "claude_code",
      oauth_config: { "x" => 1 }, is_current: true
    )
    @setting = AppSetting.editable
    @setting.update!(spot_gating_enabled: true,
                     spot_gate_five_hour_threshold_pct: 80,
                     spot_gate_weekly_threshold_pct: 80)
  end

  # Lay down a series that yields a measurable rate, plus a final reading at the
  # given utilization the forecast is built from.
  def seed_history(current_5h:, current_7d: 0.10, sessions: 1, rate_step: 0.01)
    util = 0.01
    [ 120, 90, 60, 30 ].each do |minutes_ago|
      ClaudeAccountQuotaSnapshot.create!(
        claude_account: @account,
        utilization_5h: util, utilization_7d: util,
        reset_5h: @now + 2.hours, reset_7d: @now + 2.days,
        active_session_count: sessions, trigger: "usage_sample",
        created_at: @now - minutes_ago.minutes
      )
      util += rate_step
    end

    ClaudeAccountQuotaSnapshot.create!(
      claude_account: @account,
      utilization_5h: current_5h, utilization_7d: current_7d,
      reset_5h: @now + 2.hours, reset_7d: @now + 2.days,
      active_session_count: sessions, trigger: "usage_sample",
      created_at: @now
    )
  end

  test "fails open when gating is disabled" do
    @setting.update!(spot_gating_enabled: false)
    decision = SpotGateService.evaluate(now: @now)

    assert decision.allowed?
    assert_equal "gating_disabled", decision.reason
  end

  test "fails open when there is not enough data to forecast" do
    decision = SpotGateService.evaluate(now: @now)

    assert decision.allowed?, "a monitoring gap must not become an outage of all automated work"
    assert_equal "insufficient_data", decision.reason
  end

  test "allows spot when the forecast stays under both ceilings" do
    seed_history(current_5h: 0.10, current_7d: 0.05)

    decision = SpotGateService.evaluate(now: @now)
    assert decision.allowed?
    assert_equal "within_forecast", decision.reason
    assert decision.forecast_5h.present?
  end

  test "holds spot when the 5-hour forecast breaches its ceiling" do
    seed_history(current_5h: 0.79, current_7d: 0.05)

    # candidate_sessions: 1 is the real start decision — with nothing else
    # running, the informational reading is flat and could never breach.
    decision = SpotGateService.evaluate(now: @now, candidate_sessions: 1)
    refute decision.allowed?
    assert_equal "forecast_breached", decision.reason
    assert decision.forecast_5h.breached?
    assert_match(/5-hour window forecast/, decision.detail)
  end

  test "holds spot when only the weekly forecast breaches" do
    seed_history(current_5h: 0.05, current_7d: 0.95)

    decision = SpotGateService.evaluate(now: @now, candidate_sessions: 1)
    refute decision.allowed?
    assert decision.forecast_7d.breached?
    refute decision.forecast_5h.breached?
  end

  test "a higher threshold lets the same forecast through" do
    seed_history(current_5h: 0.79, current_7d: 0.05)
    assert SpotGateService.evaluate(now: @now, candidate_sessions: 1).held?

    @setting.update!(spot_gate_five_hour_threshold_pct: 100, spot_gate_weekly_threshold_pct: 100)
    assert SpotGateService.evaluate(now: @now, candidate_sessions: 1).allowed?
  end

  test "the start gate counts the session being asked about" do
    # 4% per session-hour, 2 hours left, currently at 74%. With nothing running,
    # the informational forecast is flat at 74% — but starting one session adds
    # 4% x 1 x 2h = 8%, landing at 82% and over the 80% ceiling. A gate that
    # ignored the candidate would let it start.
    seed_history(current_5h: 0.74, current_7d: 0.05)

    informational = SpotGateService.evaluate(now: @now)
    assert informational.allowed?, "the dashboard reading describes the fleet as it stands"

    spot = Session.create!(git_root: "https://github.com/t/r.git", prompt: "s", genesis: SessionGenesis::GITHUB_ISSUE)
    refute SpotGateService.allow_start?(spot), "the start decision must include the candidate session"
  end

  test "allow_start? never consults the gate for a priority session" do
    seed_history(current_5h: 0.99, current_7d: 0.99)
    priority = Session.create!(git_root: "https://github.com/t/r.git", prompt: "p", genesis: SessionGenesis::WEB_UI)
    spot = Session.create!(git_root: "https://github.com/t/r.git", prompt: "s", genesis: SessionGenesis::GITHUB_ISSUE)

    assert SpotGateService.allow_start?(priority)
    refute SpotGateService.allow_start?(spot)
  end

  test "promoting a genesis lets its sessions start immediately" do
    seed_history(current_5h: 0.99, current_7d: 0.99)
    spot = Session.create!(git_root: "https://github.com/t/r.git", prompt: "s", genesis: SessionGenesis::GITHUB_ISSUE)
    refute SpotGateService.allow_start?(spot)

    @setting.set_genesis_class(SessionGenesis::GITHUB_ISSUE, SessionGenesis::PRIORITY)
    @setting.save!

    assert SpotGateService.allow_start?(spot.reload),
      "the one-click promotion has to take effect for sessions that already exist"
  end

  test "a passed reset reads as zero utilization, matching effective_utilization" do
    ClaudeAccountQuotaSnapshot.create!(
      claude_account: @account,
      utilization_5h: 0.99, utilization_7d: 0.99,
      reset_5h: @now - 1.minute, reset_7d: @now - 1.minute,
      active_session_count: 1, trigger: "usage_sample", created_at: @now
    )
    seed_history(current_5h: 0.01, current_7d: 0.01)

    decision = SpotGateService.evaluate(now: @now)
    assert decision.allowed?
  end
end
