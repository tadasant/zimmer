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

  # A rising series of readings ending AT the given current utilization, 30
  # minutes apart, with `sessions` running throughout.
  #
  # The ramp has to *end* at the current value rather than have it appended: an
  # appended reading is just another sample, so the jump from the ramp to it is
  # differenced as usage and the measured rate becomes whatever that gap happens
  # to be, not the slope the test is setting up.
  #
  # 4 readings => 3 pairs, each half an hour and each rising by the step, so the
  # rate is `2 * step` per session-hour. The 0.02 default therefore means 4% of
  # the 5-hour window per session-hour, which is what the tests below assume.
  #
  # The weekly step is deliberately an order of magnitude smaller. Its forecast
  # horizon is capped at MAX_HORIZON (24h) rather than the 2h the 5-hour window
  # has left, so an equal rate would project ~96% onto the weekly window and
  # swamp every assertion about the 5-hour one. A week accrues slower relative
  # to its own allowance, which is what this reflects.
  def seed_history(current_5h:, current_7d: 0.10, sessions: 1, rate_step: 0.02, rate_step_7d: 0.002)
    [ 90, 60, 30, 0 ].each_with_index do |minutes_ago, i|
      steps_back = 3 - i
      ClaudeAccountQuotaSnapshot.create!(
        claude_account: @account,
        utilization_5h: current_5h - (rate_step * steps_back),
        utilization_7d: current_7d - (rate_step_7d * steps_back),
        reset_5h: @now + 2.hours, reset_7d: @now + 2.days,
        active_session_count: sessions, trigger: "usage_sample",
        created_at: @now - minutes_ago.minutes
      )
    end
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
    seed_history(current_5h: 0.10, current_7d: 0.10)

    decision = SpotGateService.evaluate(now: @now)
    assert decision.allowed?
    assert_equal "within_forecast", decision.reason
    assert decision.forecast_5h.present?
  end

  test "holds spot when the 5-hour forecast breaches its ceiling" do
    seed_history(current_5h: 0.79, current_7d: 0.10)

    # candidate_sessions: 1 is the real start decision — with nothing else
    # running, the informational reading is flat and could never breach.
    decision = SpotGateService.evaluate(now: @now, candidate_sessions: 1)
    refute decision.allowed?
    assert_equal "forecast_breached", decision.reason
    assert decision.forecast_5h.breached?
    assert_match(/5-hour window forecast/, decision.detail)
  end

  test "holds spot when only the weekly forecast breaches" do
    seed_history(current_5h: 0.10, current_7d: 0.95)

    decision = SpotGateService.evaluate(now: @now, candidate_sessions: 1)
    refute decision.allowed?
    assert decision.forecast_7d.breached?
    refute decision.forecast_5h.breached?
  end

  test "a higher threshold lets the same forecast through" do
    seed_history(current_5h: 0.79, current_7d: 0.10)
    assert SpotGateService.evaluate(now: @now, candidate_sessions: 1).held?

    @setting.update!(spot_gate_five_hour_threshold_pct: 100, spot_gate_weekly_threshold_pct: 100)
    assert SpotGateService.evaluate(now: @now, candidate_sessions: 1).allowed?
  end

  test "the start gate counts the session being asked about" do
    # 4% per session-hour, 2 hours left, currently at 74%. With nothing running,
    # the informational forecast is flat at 74% — but starting one session adds
    # 4% x 1 x 2h = 8%, landing at 82% and over the 80% ceiling. A gate that
    # ignored the candidate would let it start.
    seed_history(current_5h: 0.74, current_7d: 0.10)

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
    spot = Session.create!(git_root: "https://github.com/t/r.git", prompt: "s", genesis: SessionGenesis::API)
    refute SpotGateService.allow_start?(spot)

    @setting.set_genesis_class(SessionGenesis::API, SessionGenesis::PRIORITY)
    @setting.save!

    assert SpotGateService.allow_start?(spot.reload),
      "the one-click promotion has to take effect for sessions that already exist"
  end

  test "a session that named its own class starts on that, not on its genesis" do
    seed_history(current_5h: 0.99, current_7d: 0.99)
    held = Session.create!(git_root: "https://github.com/t/r.git", prompt: "s", genesis: SessionGenesis::GITHUB_ISSUE)
    refute SpotGateService.allow_start?(held)

    held.update!(scheduling_class: SessionGenesis::PRIORITY)

    assert SpotGateService.allow_start?(held.reload),
      "this is the lever for one held session — no trigger and no policy is touched"
  end

  # Regression: ActiveRecord::ConnectionNotEstablished descends from AdapterError,
  # not StatementInvalid, so a narrow rescue let it escape into AgentSessionJob —
  # which marks the session `failed`. The gate must never fail a session.
  test "any error while evaluating allows the session rather than escaping" do
    seed_history(current_5h: 0.99, current_7d: 0.99)

    [ ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid, RuntimeError ].each do |klass|
      ClaudeUsageRateService.stub(:call, ->(*) { raise klass, "boom" }) do
        decision = SpotGateService.evaluate(now: @now, candidate_sessions: 1)
        assert decision.allowed?, "#{klass} must not be able to hold a session"
        assert_equal "unavailable", decision.reason
      end
    end
  end

  # Regression: a nil reset used to fall back to the 24h cap, so a 5-hour burn
  # rate got projected over a day and manufactured a breach out of a missing field.
  test "a window with no reset time is skipped rather than projected over the cap" do
    seed_history(current_5h: 0.70, current_7d: 0.10)
    ClaudeAccountQuotaSnapshot.create!(
      claude_account: @account,
      utilization_5h: 0.70, utilization_7d: 0.10,
      reset_5h: nil, reset_7d: @now + 2.days,
      active_session_count: 1, trigger: "usage_sample", created_at: @now + 1.second
    )

    decision = SpotGateService.evaluate(now: @now, candidate_sessions: 1)
    assert_nil decision.forecast_5h, "an unknown horizon is a monitoring gap, not a breach"
    assert decision.allowed?
  end

  test "a priority session is answered without consulting quota at all" do
    seed_history(current_5h: 0.99, current_7d: 0.99)
    priority = Session.create!(git_root: "https://github.com/t/r.git", prompt: "p", genesis: SessionGenesis::WEB_UI)

    decision = SpotGateService.start_decision(priority)
    assert decision.allowed?
    assert_equal "priority", decision.reason
  end

  test "a passed reset reads as zero utilization, matching effective_utilization" do
    seed_history(current_5h: 0.10, current_7d: 0.10)
    # Latest reading: both windows pinned at 99% but already past their reset, so
    # effective_utilization reads them as 0 and the forecast starts from nothing.
    # Stamped a second later so it is unambiguously the one pool_snapshot picks.
    ClaudeAccountQuotaSnapshot.create!(
      claude_account: @account,
      utilization_5h: 0.99, utilization_7d: 0.99,
      reset_5h: @now - 1.minute, reset_7d: @now - 1.minute,
      active_session_count: 1, trigger: "usage_sample", created_at: @now + 1.second
    )

    decision = SpotGateService.evaluate(now: @now, candidate_sessions: 1)
    assert decision.allowed?
    assert_equal 0.0, decision.forecast_5h.current
  end
end
