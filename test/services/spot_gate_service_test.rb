# frozen_string_literal: true

require "test_helper"

class SpotGateServiceTest < ActiveSupport::TestCase
  setup do
    @now = Time.current
    # The controller sizes the whole account pool and multiplies by the running
    # fleet, so a fixture account's readings or a fixture session in `running`
    # silently changes the arithmetic these tests assert on. Clear both, then
    # build the one account this suite forecasts from.
    ClaudeAccountQuotaSnapshot.delete_all
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
  # rate is `2 * step` per session-hour — and 1.5 observed session-hours, which
  # clears ClaudeUsageRateService::MIN_SESSION_HOURS. The 0.02 default therefore
  # means 4% of the 5-hour window per session-hour: over the 10-minute control
  # interval one session burns 0.667% of it, so an empty window carries far more
  # sessions than the operator's fleet cap, which is then what binds.
  def seed_history(current_5h:, current_7d: 0.10, sessions: 1, rate_step: 0.02, rate_step_7d: 0.002,
                   account: @account)
    [ 90, 60, 30, 0 ].each_with_index do |minutes_ago, i|
      steps_back = 3 - i
      ClaudeAccountQuotaSnapshot.create!(
        claude_account: account,
        utilization_5h: current_5h - (rate_step * steps_back),
        utilization_7d: current_7d - (rate_step_7d * steps_back),
        reset_5h: @now + 2.hours, reset_7d: @now + 2.days,
        active_session_count: sessions, trigger: "usage_sample",
        created_at: @now - minutes_ago.minutes
      )
    end
  end

  # A second account whose only readings are a flat pair — no rise, so it
  # contributes no rate of its own and only its utilization matters to the pool.
  def seed_spare(email:, current_5h:, current_7d:)
    spare = ClaudeAccount.create!(email: email, runtime: "claude_code", oauth_config: { "x" => 1 })
    ClaudeAccountQuotaSnapshot.create!(
      claude_account: spare, utilization_5h: current_5h, utilization_7d: current_7d,
      reset_5h: @now + 2.hours, reset_7d: @now + 2.days,
      active_session_count: 1, trigger: "usage_sample", created_at: @now
    )
    spare
  end

  test "fails open when gating is disabled" do
    @setting.update!(spot_gating_enabled: false)
    decision = SpotGateService.evaluate(now: @now)

    assert decision.allowed?
    assert_equal "gating_disabled", decision.reason
  end

  test "fails open when there is no reading to size capacity from" do
    decision = SpotGateService.evaluate(now: @now)

    assert decision.allowed?, "a monitoring gap must not become an outage of all automated work"
    assert_equal "no_snapshot", decision.reason
  end

  # The production case: 9 pairs over 0.75 observed session-hours drove a 24-hour
  # projection that held 25 sessions for a day. Three quarters of one session-hour
  # is an anecdote, and an anecdote does not get to hold a queue.
  test "a rate measured over too little session activity does not hold work" do
    # Three pairs 10 minutes apart with one session running: 0.5 session-hours.
    [ 30, 20, 10, 0 ].each_with_index do |minutes_ago, i|
      ClaudeAccountQuotaSnapshot.create!(
        claude_account: @account,
        utilization_5h: 0.20 + (0.10 * i), utilization_7d: 0.70,
        reset_5h: @now + 2.hours, reset_7d: @now + 2.days,
        active_session_count: 1, trigger: "usage_sample", created_at: @now - minutes_ago.minutes
      )
    end

    rate = ClaudeUsageRateService.call(now: @now)
    assert_equal 3, rate.sample_count
    assert_operator rate.session_hours, :<, ClaudeUsageRateService::MIN_SESSION_HOURS
    refute rate.sufficient?

    decision = SpotGateService.evaluate(now: @now, candidate_sessions: 1)
    assert decision.allowed?
    assert_equal "insufficient_data", decision.reason
  end

  # The heart of the change: an idle window admits many sessions AT ONCE rather
  # than releasing one and re-deciding. The old rule projected the fleet's burn
  # across every remaining hour of the window, so the first admission breached
  # and everything behind it queued.
  test "an empty window admits sessions in parallel, up to the fleet cap" do
    seed_history(current_5h: 0.02, current_7d: 0.10)

    decision = SpotGateService.evaluate(now: @now, candidate_sessions: 1)
    assert decision.allowed?
    assert_equal "within_capacity", decision.reason
    assert_equal SpotGateService.fleet_cap, decision.capacity,
      "quota this idle should admit every slot the operator allows at once"

    # Not a trickle: with the fleet already several sessions deep, the next
    # candidate still starts.
    3.times { |i| running_session(i) }
    assert SpotGateService.evaluate(now: @now, candidate_sessions: 1).allowed?
  end

  test "capacity is the sessions that fit under the ceiling over the control interval" do
    # 5-hour window at 60% with a 4%/session-hour burn: over 10 minutes one
    # session spends 0.667%, so 20 points of headroom carry 30 sessions — more
    # than the fleet cap allows, which is then what binds.
    seed_history(current_5h: 0.60, current_7d: 0.10)
    decision = SpotGateService.evaluate(now: @now, candidate_sessions: 1)

    assert_equal 30, decision.forecast_5h.capacity
    assert_equal SpotGateService.fleet_cap, decision.capacity
    assert decision.allowed?
  end

  test "the fleet is held once it reaches the capacity a window can carry" do
    # 5-hour window at 78%: 2 points of headroom carry 3 concurrent sessions.
    seed_history(current_5h: 0.78, current_7d: 0.10)
    assert_equal 3, SpotGateService.evaluate(now: @now, candidate_sessions: 1).forecast_5h.capacity

    3.times { |i| running_session(i) }
    decision = SpotGateService.evaluate(now: @now, candidate_sessions: 1)

    refute decision.allowed?, "the fourth session would carry the window past its ceiling"
    assert_equal "at_capacity", decision.reason
    assert_equal 3, decision.capacity
    assert decision.forecast_5h.breached?
    assert_match(/5-hour window forecast/, decision.detail)
  end

  test "a window already past its ceiling carries nothing" do
    seed_history(current_5h: 0.95, current_7d: 0.10)
    decision = SpotGateService.evaluate(now: @now, candidate_sessions: 1)

    refute decision.allowed?
    assert_equal 0, decision.capacity
  end

  test "the weekly window binds when it is the tighter of the two" do
    seed_history(current_5h: 0.10, current_7d: 0.799, rate_step_7d: 0.02)
    decision = SpotGateService.evaluate(now: @now, candidate_sessions: 1)

    refute decision.allowed?
    assert_equal 0, decision.forecast_7d.capacity
    assert_operator decision.forecast_5h.capacity, :>, 0
    assert_match(/weekly window forecast/, decision.detail)
  end

  test "a higher target lets the same fleet through" do
    seed_history(current_5h: 0.78, current_7d: 0.10)
    3.times { |i| running_session(i) }
    assert SpotGateService.evaluate(now: @now, candidate_sessions: 1).held?

    @setting.update!(spot_gate_five_hour_threshold_pct: 100, spot_gate_weekly_threshold_pct: 100)
    assert SpotGateService.evaluate(now: @now, candidate_sessions: 1).allowed?
  end

  # Zimmer rotates accounts automatically when the serving one is refused, so the
  # question is whether the POOL can absorb the work — not whether the account
  # that happens to be current can. Production held a queue for a day while three
  # spare accounts sat under 50%.
  test "a spare account with room admits work the serving account could not" do
    seed_history(current_5h: 0.95, current_7d: 0.10)
    assert SpotGateService.evaluate(now: @now, candidate_sessions: 1).held?

    seed_spare(email: "spare@example.com", current_5h: 0.05, current_7d: 0.10)

    decision = SpotGateService.evaluate(now: @now, candidate_sessions: 1)
    assert decision.allowed?, "the pool has room even though the serving account does not"
    assert_equal "spare@example.com", decision.account_email
    assert_equal 2, decision.accounts_considered
  end

  test "an account already marked quota_exceeded does not vote on the pool's room" do
    seed_history(current_5h: 0.95, current_7d: 0.10)
    spare = seed_spare(email: "spare@example.com", current_5h: 0.05, current_7d: 0.10)
    assert SpotGateService.evaluate(now: @now, candidate_sessions: 1).allowed?

    spare.update!(status: :quota_exceeded)
    assert SpotGateService.evaluate(now: @now, candidate_sessions: 1).held?,
      "a spent account cannot lend headroom it does not have"
  end

  test "the start gate counts the session being asked about" do
    seed_history(current_5h: 0.78, current_7d: 0.10)
    3.times { |i| running_session(i) }

    informational = SpotGateService.evaluate(now: @now)
    assert informational.allowed?, "three running sessions are exactly the capacity"

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

  # Regression: a nil reset used to fall back to the forecast cap, so a burn rate
  # got projected over a horizon that field never established.
  test "a window with no reset time places no bound rather than manufacturing one" do
    seed_history(current_5h: 0.99, current_7d: 0.10)
    ClaudeAccountQuotaSnapshot.create!(
      claude_account: @account,
      utilization_5h: 0.99, utilization_7d: 0.10,
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
    # Stamped a second later so it is unambiguously the latest.
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

  # /quotas and get_spot_policy both render current_decision. They used to ask
  # different questions — the card showed the fleet as it stands, the tool showed
  # something else — and rendered a green badge above the words "would be held".
  test "current_decision is the start decision, so every surface agrees" do
    seed_history(current_5h: 0.78, current_7d: 0.10)
    3.times { |i| running_session(i) }

    assert SpotGateService.current_decision.held?
    assert_equal 3, SpotGateService.current_decision.active_sessions
    assert_equal 4, SpotGateService.current_decision.forecast_sessions
  end

  # --- Brake 1: the hard stop --------------------------------------------------

  test "reaching the target stops spot work on the measured number, not a forecast" do
    seed_history(current_5h: 0.80, current_7d: 0.10)

    decision = SpotGateService.evaluate(now: @now, candidate_sessions: 1)
    refute decision.allowed?
    assert_equal "at_utilization_limit", decision.reason
    assert decision.forecast_5h.at_limit?
    refute decision.forecast_7d.at_limit?
    assert_equal 0, decision.capacity
    assert_match(/5-hour window at 80% of its 80% target/, decision.detail)
  end

  # The forecast fails open with no measurable rate. The hard stop must not: it is
  # a statement about a number that has already been read.
  test "the hard stop holds even when the rate is not measurable" do
    ClaudeAccountQuotaSnapshot.create!(
      claude_account: @account, utilization_5h: 0.85, utilization_7d: 0.10,
      reset_5h: @now + 2.hours, reset_7d: @now + 2.days,
      active_session_count: 1, trigger: "usage_sample", created_at: @now
    )
    refute ClaudeUsageRateService.call(now: @now).sufficient?

    decision = SpotGateService.evaluate(now: @now, candidate_sessions: 1)
    refute decision.allowed?, "a window over its target holds regardless of what can be forecast"
    assert_equal "at_utilization_limit", decision.reason
  end

  # The release is not a hair-trigger: coming back under the target is not enough
  # on its own, because capacity is room for a whole session's burn over the
  # control interval. At 4%/session-hour that band is ~0.67 of a point.
  test "dipping under the target does not release the queue until a session's burn fits" do
    seed_history(current_5h: 0.7995, current_7d: 0.10)
    just_under = SpotGateService.evaluate(now: @now, candidate_sessions: 1)
    refute just_under.allowed?, "under the target, but with no room for a session"
    assert_equal "at_capacity", just_under.reason
    assert_equal 0, just_under.capacity

    ClaudeAccountQuotaSnapshot.create!(
      claude_account: @account, utilization_5h: 0.79, utilization_7d: 0.10,
      reset_5h: @now + 2.hours, reset_7d: @now + 2.days,
      active_session_count: 1, trigger: "usage_sample", created_at: @now + 1.second
    )
    decayed = SpotGateService.evaluate(now: @now, candidate_sessions: 1)
    assert decayed.allowed?, "a point of decay is a whole session's burn, so work resumes"
    assert_equal 1, decayed.capacity
  end

  # --- Brake 2: the fleet cap --------------------------------------------------

  test "the fleet cap holds spot sessions once every slot is taken" do
    seed_history(current_5h: 0.02, current_7d: 0.10)
    @setting.update!(spot_max_concurrent_sessions: 3)

    2.times { |i| running_session(i) }
    assert SpotGateService.evaluate(now: @now, candidate_sessions: 1).allowed?

    running_session(2)
    decision = SpotGateService.evaluate(now: @now, candidate_sessions: 1)
    refute decision.allowed?, "the fourth session has no slot"
    assert_equal "fleet_at_cap", decision.reason
    assert_equal 3, decision.fleet_cap
    assert_match(/3 of 3 session slots/, decision.detail)
  end

  test "the cap is the operator's, and raising it admits work immediately" do
    seed_history(current_5h: 0.02, current_7d: 0.10)
    @setting.update!(spot_max_concurrent_sessions: 2)
    2.times { |i| running_session(i) }
    assert SpotGateService.evaluate(now: @now, candidate_sessions: 1).held?

    @setting.update!(spot_max_concurrent_sessions: 10)
    assert SpotGateService.evaluate(now: @now, candidate_sessions: 1).allowed?
  end

  # The asymmetry Tadas asked for, in one test: the cap gates spot work and does
  # not gate priority work, and priority sessions are what fill the slots.
  test "a full fleet holds a spot session and lets a priority session through" do
    seed_history(current_5h: 0.02, current_7d: 0.10)
    @setting.update!(spot_max_concurrent_sessions: 2)
    2.times { |i| running_session(i) }

    spot = Session.create!(git_root: "https://github.com/t/r.git", prompt: "s", genesis: SessionGenesis::GITHUB_ISSUE)
    priority = Session.create!(git_root: "https://github.com/t/r.git", prompt: "p", genesis: SessionGenesis::WEB_UI)

    refute SpotGateService.allow_start?(spot)
    assert SpotGateService.allow_start?(priority), "the cap must never gate priority work"
    assert_equal "priority", SpotGateService.start_decision(priority).reason
  end

  # And the consequence, stated as its own case because it is intended rather
  # than incidental: priority work crowds spot work out of the slots entirely.
  test "a fleet of priority sessions leaves zero spot slots" do
    seed_history(current_5h: 0.02, current_7d: 0.10)
    @setting.update!(spot_max_concurrent_sessions: 10)
    10.times { |i| running_session(i, genesis: SessionGenesis::WEB_UI) }

    decision = SpotGateService.evaluate(now: @now, candidate_sessions: 1)
    refute decision.allowed?, "ten priority sessions leave nothing for spot work, by design"
    assert_equal "fleet_at_cap", decision.reason
    assert_equal 10, decision.active_sessions

    priority = Session.create!(git_root: "https://github.com/t/r.git", prompt: "p", genesis: SessionGenesis::WEB_UI)
    assert SpotGateService.allow_start?(priority), "an eleventh priority session still starts"
  end

  # The incident this controller was rewritten for, replayed from the numbers
  # production reported at 2026-08-16T01:10Z: weekly at 69% with 24 hours left,
  # the 5-hour window freshly reset to 1%, a measured burn of 42.65% of the
  # 5-hour window and 2.22% of the weekly one per session-hour, one session
  # running — and 25 spot sessions waiting, the oldest for 23 hours.
  test "the production incident replays as a parallel admission" do
    seed_production_incident

    rate = ClaudeUsageRateService.call(now: @now)
    assert_in_delta 0.4265, rate.rate_5h, 0.0005
    assert_in_delta 0.0222, rate.rate_7d, 0.0005
    assert rate.sufficient?, "this replay has to exercise the forecast, not the sample floor"

    # What the old rule did with exactly these inputs: extrapolate one session's
    # burn across all 24 remaining hours of the weekly window. 122% against an 80%
    # ceiling — so the FIRST candidate breached, and 25 sessions queued behind it.
    old_weekly_projection = 0.69 + (rate.rate_7d * 1 * 24)
    assert_operator old_weekly_projection, :>, 0.80

    running_session(0)
    decision = SpotGateService.evaluate(now: @now, candidate_sessions: 1)

    assert decision.allowed?, "the queue that starved has to start"
    assert_equal 11, decision.forecast_5h.capacity, "quota carries 11 concurrent sessions"
    assert_equal 29, decision.forecast_7d.capacity
    # The operator's cap is the tighter of the two, and it is what the fleet
    # actually fills to: 10 at once, not one at a time.
    assert_equal 10, decision.capacity
    assert_equal 10, decision.fleet_cap
    # 11 sessions burning for one control interval land the 5-hour window on its
    # target: the ceiling is what the controller climbs to, not what it avoids.
    assert_in_delta 0.792, 0.01 + (rate.rate_5h * 11 * (SpotGateService::CONTROL_INTERVAL / 3600.0)), 0.005
  end

  private

  # matt@'s series: a 5-hour window burnt to 90% and then reset to 1%, with the
  # weekly counter running straight through to 69%. The rate is measured off the
  # burn before the reset, which is exactly why a freshly-reset window and a steep
  # rate coexist in the reported numbers.
  def seed_production_incident
    weekly = 0.6345
    [ 150, 120, 90, 60, 30 ].each_with_index do |minutes_ago, i|
      ClaudeAccountQuotaSnapshot.create!(
        claude_account: @account,
        utilization_5h: 0.05 + (0.21325 * i), utilization_7d: weekly + (0.0111 * i),
        reset_5h: @now - 10.minutes, reset_7d: @now + 24.hours,
        active_session_count: 1, trigger: "usage_sample", created_at: @now - minutes_ago.minutes
      )
    end
    ClaudeAccountQuotaSnapshot.create!(
      claude_account: @account,
      utilization_5h: 0.01, utilization_7d: 0.69,
      reset_5h: @now + 49.minutes, reset_7d: @now + 24.hours,
      active_session_count: 1, trigger: "usage_sample", created_at: @now
    )
  end

  def running_session(index, genesis: SessionGenesis::WEB_UI)
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "running #{index}",
                    genesis: genesis, status: :running, agent_runtime: "claude_code")
  end
end
