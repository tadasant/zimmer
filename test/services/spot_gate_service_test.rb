# frozen_string_literal: true

require "test_helper"

class SpotGateServiceTest < ActiveSupport::TestCase
  setup do
    # The gate averages every account's latest snapshot and counts every running
    # session, so a fixture reading or a fixture session in `running` silently
    # changes what these tests assert on. Clear both, then build the one account
    # this suite seeds by default. Fixture accounts stay in the pool with nothing
    # to read, which is exactly what an un-probed account contributes: nothing.
    ClaudeAccountQuotaSnapshot.delete_all
    ClaudeAccount.update_all(is_current: false)
    Session.where(status: :running).update_all(status: Session.statuses[:needs_input])
    @account = ClaudeAccount.create!(
      email: "gate-test@example.com", runtime: "claude_code",
      oauth_config: { "x" => 1 }, is_current: true
    )
    @setting = AppSetting.editable
    # A 20% priority reserve leaves an 80% spot budget, which is the same line
    # the old "80% target" drew — so the pool and fleet-cap assertions below are
    # comparing against the number they always were.
    @setting.update!(spot_gating_enabled: true,
                     spot_reserve_five_hour_pct: 20,
                     spot_reserve_weekly_pct: 20,
                     spot_max_concurrent_sessions: 10)
  end

  # One reading is all the gate needs — there is no rate to differentiate and no
  # series to fit, just the utilization each window is carrying now.
  def seed(current_5h:, current_7d: 0.10, account: @account, reset_5h: 2.hours.from_now,
           reset_7d: 2.days.from_now)
    ClaudeAccountQuotaSnapshot.create!(
      claude_account: account,
      utilization_5h: current_5h, utilization_7d: current_7d,
      reset_5h: reset_5h, reset_7d: reset_7d,
      active_session_count: 1, trigger: "usage_sample"
    )
  end

  def seed_spare(email:, current_5h:, current_7d:, status: :active)
    spare = ClaudeAccount.create!(email: email, runtime: "claude_code",
                                  oauth_config: { "x" => 1 }, status: status)
    seed(current_5h: current_5h, current_7d: current_7d, account: spare)
    spare
  end

  def pool_size = ClaudeAccount.for_runtime("claude_code").count

  # --- fail-open ---------------------------------------------------------------

  test "fails open when gating is disabled" do
    @setting.update!(spot_gating_enabled: false)
    decision = SpotGateService.evaluate

    assert decision.allowed?
    assert_equal "gating_disabled", decision.reason
  end

  test "fails open when there is no reading to decide on" do
    decision = SpotGateService.evaluate

    assert decision.allowed?, "a monitoring gap must not become an outage of all automated work"
    assert_equal "no_snapshot", decision.reason
  end

  # Regression: ActiveRecord::ConnectionNotEstablished descends from AdapterError,
  # not StatementInvalid, so a narrow rescue let it escape into AgentSessionJob —
  # which marks the session `failed`. The gate must never fail a session.
  test "any error while evaluating allows the session rather than escaping" do
    seed(current_5h: 0.99, current_7d: 0.99)

    [ ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid, RuntimeError ].each do |klass|
      Session.stub(:running_claude_code_turns, ->(*) { raise klass, "boom" }) do
        decision = SpotGateService.evaluate
        assert decision.allowed?, "#{klass} must not be able to hold a session"
        assert_equal "unavailable", decision.reason
      end
    end
  end

  # --- the reserve and the cap -------------------------------------------------

  # With no calibrated dollar capacity these tests run the model in its fraction
  # mode: every quantity is a share of the window, the reserve is carved off the
  # top, and spot work fills what is left. That is deliberate — it is the mode a
  # deployment is in before the calibration cron has ever run, and it has to be
  # correct on its own.
  test "a window inside its spot budget runs spot sessions" do
    seed(current_5h: 0.42, current_7d: 0.10)

    decision = SpotGateService.evaluate
    assert decision.allowed?
    assert_equal "within_limits", decision.reason
    assert_in_delta 42.0, decision.five_hour.current_pct, 0.001
    assert_in_delta 80.0, decision.five_hour.spot_budget_pct, 0.001
    assert_equal 20, decision.five_hour.window.reserve_pct
  end

  # Spot work fills right up to the edge of the non-reserved budget. It stops at
  # the edge because the next session would spend INTO the reserve, which is the
  # one thing the model never allows.
  test "spot work runs at 79% and stops where the priority reserve begins" do
    seed(current_5h: 0.79, current_7d: 0.10)
    assert SpotGateService.evaluate.allowed?, "79% is inside an 80% spot budget"

    seed(current_5h: 0.80, current_7d: 0.10)
    decision = SpotGateService.evaluate

    refute decision.allowed?
    assert_equal "at_utilization_limit", decision.reason
    assert decision.five_hour.at_limit?
    refute decision.weekly.at_limit?
    assert_match(/5-hour window is at 80% of the 80% spot budget/, decision.detail)
  end

  # Reserve 0% means "spot work may have the whole window". Nothing is held back,
  # and a reading that would have been refused under any reserve runs.
  test "a zero reserve lets spot work fill the entire window" do
    @setting.update!(spot_reserve_five_hour_pct: 0, spot_reserve_weekly_pct: 0)
    seed(current_5h: 0.97, current_7d: 0.10)

    decision = SpotGateService.evaluate
    assert decision.allowed?, "with nothing reserved, 97% is still inside the budget"
    assert_in_delta 100.0, decision.five_hour.spot_budget_pct, 0.001
    assert_equal 0.0, decision.five_hour.window.reserve_units
  end

  # Reserve 100% is the other end of the same control: the whole window belongs
  # to priority work, so no spot session ever starts, however empty the window is.
  test "a full reserve holds every spot session, even on an empty window" do
    @setting.update!(spot_reserve_five_hour_pct: 100)
    seed(current_5h: 0.0, current_7d: 0.10)

    decision = SpotGateService.evaluate
    refute decision.allowed?, "a window entirely reserved for priority has no spot budget at all"
    assert_equal "at_utilization_limit", decision.reason
    assert_equal 0.0, decision.five_hour.window.spot_budget_units
  end

  # --- the pacing curve --------------------------------------------------------

  # The curve is what stops the fleet burning the whole budget in the first hour.
  # With a session already running the pace test applies, and a window only 20%
  # of the way through allows only 20% of its budget to have been spent.
  test "a window early in its life holds work that is ahead of the curve" do
    running_session(0)
    # 4 hours left of a 5-hour window: 20% elapsed, so the curve allows 16% of
    # the window (20% of the 80% budget).
    seed(current_5h: 0.40, current_7d: 0.05, reset_5h: 4.hours.from_now)

    decision = SpotGateService.evaluate
    refute decision.allowed?, "40% spent against a curve at 16% is running ahead of the budget"
    assert_equal "at_utilization_limit", decision.reason
    assert_in_delta 16.0, decision.five_hour.pace_pct, 0.001
    refute decision.five_hour.within_pace
    assert decision.five_hour.within_cap, "the budget is not spent — the fleet is merely early"
  end

  # …and the same reading late in the window runs, because by then the curve has
  # caught up with it. This is the difference from a flat target: the line moves.
  test "the same reading runs later in the window, once the curve has caught up" do
    running_session(0)
    seed(current_5h: 0.40, current_7d: 0.05, reset_5h: 1.hour.from_now)

    decision = SpotGateService.evaluate
    assert decision.allowed?, "80% through the window, the curve allows 64%"
    assert_in_delta 64.0, decision.five_hour.pace_pct, 0.001
  end

  # A session is not infinitely divisible. With nothing running at all the pace
  # test is waived, so a deployment always does SOME work rather than idling
  # through a window it could not fill one session at a time.
  test "an idle fleet is admitted even when it is ahead of the curve" do
    seed(current_5h: 0.40, current_7d: 0.05, reset_5h: 4.hours.from_now)

    decision = SpotGateService.evaluate
    assert decision.allowed?, "nothing is running, so the pacing curve is waived"
    refute decision.five_hour.within_pace, "…but the reading is still ahead of it"
    assert decision.five_hour.pace_waived
  end

  # The waiver is only ever of the PACE. The reserve is absolute: an idle fleet
  # facing a spent spot budget is still held.
  test "the idle-fleet waiver never spends into the reserve" do
    seed(current_5h: 0.92, current_7d: 0.05, reset_5h: 4.hours.from_now)

    decision = SpotGateService.evaluate
    refute decision.allowed?, "the spot budget is spent; nothing waives that"
    refute decision.five_hour.within_cap
  end

  # A window with no recorded rollover has no time axis, so there is no curve to
  # be ahead of — the cap alone decides, which is the safe direction to degrade.
  test "a window with no rollover time is capped but not paced" do
    running_session(0)
    seed(current_5h: 0.40, current_7d: 0.05, reset_5h: nil)

    decision = SpotGateService.evaluate
    assert decision.allowed?
    assert_nil decision.five_hour.pace_pct
    assert_nil decision.five_hour.window.seconds_remaining
  end

  # --- dollar mode -------------------------------------------------------------

  # Everything above runs the fraction fallback. This section is the production
  # path: a calibrated window and measured burn rates, so the gate projects real
  # money over its own lookahead rather than comparing levels.
  def calibrate(capacity_usd: 1000.0, window: QuotaCapacityEstimate::FIVE_HOUR)
    QuotaCapacityEstimate.create!(window_key: window, capacity_usd: capacity_usd,
                                  sample_cost_usd: capacity_usd / 2, sample_utilization: 0.5,
                                  observation_count: 5, computed_at: Time.current)
  end

  # Replaces the whole table, so `fleet_default_usd_per_minute` — which is
  # cost-weighted over `sample_cost_usd / sample_minutes`, not over the rate
  # column — moves with it. A session with no sampled combination is priced at
  # that default, which is what these tests are usually exercising.
  def burn_rate(usd_per_minute, harness: "zimmer", model: "claude-opus-5")
    HarnessModelBurnRate.delete_all
    HarnessModelBurnRate.create!(harness: harness, model: model, usd_per_minute: usd_per_minute,
                                 sample_cost_usd: usd_per_minute * 100, sample_minutes: 100.0,
                                 sample_session_count: 25, computed_at: Time.current)
  end

  test "a calibrated window decides in dollars and reports them" do
    calibrate(capacity_usd: 1000.0)
    burn_rate(0.5)
    seed(current_5h: 0.30, current_7d: 0.05)

    decision = SpotGateService.evaluate
    window = decision.five_hour.window

    assert window.dollars?
    assert_in_delta 1000.0, window.capacity_usd, 0.0001
    assert_in_delta 300.0, window.spent_usd, 0.0001
    assert_in_delta 200.0, window.reserve_usd, 0.0001, "20% of a $1,000 window"
    assert_in_delta 500.0, window.remaining_spot_usd, 0.0001
    assert decision.allowed?
    assert_match(/5-hour has \$500\.00 of spot budget left/, decision.detail)
  end

  # The cap is a PROJECTION, which is the whole reason the burn rates exist: the
  # same reading admits or refuses depending on what the fleet is about to spend.
  test "the cap refuses a session whose ten minutes would cross the reserve" do
    calibrate(capacity_usd: 1000.0)
    seed(current_5h: 0.79, current_7d: 0.05)

    burn_rate(0.5)
    assert SpotGateService.evaluate.allowed?, "$0.50/min for 10 minutes is $5, inside the $10 left"

    burn_rate(2.0)
    decision = SpotGateService.evaluate
    refute decision.allowed?, "$20 of projected spend would eat $10 of the priority reserve"
    assert_equal "at_utilization_limit", decision.reason
    refute decision.five_hour.within_cap
    assert_match(/has spent \$790\.00 of its \$800\.00 spot budget/, decision.detail)
  end

  # The fleet's own burn counts, priority sessions included — they spend against
  # the same window the reserve is protecting.
  test "the projection counts every running session, not just the candidate" do
    calibrate(capacity_usd: 1000.0)
    burn_rate(1.0)
    seed(current_5h: 0.70, current_7d: 0.05)

    3.times { |i| running_session(i) }
    decision = SpotGateService.evaluate

    assert_in_delta 3.0, decision.fleet_burn_usd_per_minute, 0.0001
    assert_in_delta 1.0, decision.candidate_burn_usd_per_minute, 0.0001
    assert_in_delta 4.0, decision.projected_burn_usd_per_minute, 0.0001
  end

  # The pace in dollars: what is left over the time left to spend it in.
  test "the sustainable rate is the remaining budget over the remaining time" do
    calibrate(capacity_usd: 1000.0)
    burn_rate(0.5)
    seed(current_5h: 0.30, current_7d: 0.05, reset_5h: 100.minutes.from_now)
    running_session(0)

    decision = SpotGateService.evaluate
    # A hair over $5.00: `reset_5h` is read a fraction of a second before the gate
    # computes against it, so "100 minutes left" is 99.98 by the time it lands.
    assert_in_delta 5.0, decision.five_hour.window.sustainable_units_per_minute, 0.01,
      "$500 of budget left over 100 minutes"
    assert decision.allowed?, "a $1.00/min fleet is well inside $5.00/min"

    burn_rate(4.0)
    held = SpotGateService.evaluate
    refute held.allowed?, "$8.00/min is not"
    assert held.five_hour.within_cap, "the budget is not spent — the pace is what refuses"
    assert_match(%r{is burning \$8\.00/min against \$5\.00/min sustainable}, held.detail)
  end

  # A window with dollars but no sampled rate cannot project, so it falls back to
  # the cumulative curve rather than pretending the fleet is free.
  test "a calibrated window with no burn rate falls back to the cumulative curve" do
    calibrate(capacity_usd: 1000.0)
    seed(current_5h: 0.30, current_7d: 0.05)

    decision = SpotGateService.evaluate
    assert_nil decision.fleet_burn_usd_per_minute
    refute decision.five_hour.burn_known?
    assert decision.allowed?
    assert_nil decision.five_hour.to_h[:projected_burn_usd_per_minute],
      "an unknown burn must read as unknown, never as $0.00"
  end

  # --- what stops work already running ------------------------------------------

  # The ceiling sweep asks about the fleet AS IT STANDS. Projecting a
  # hypothetical extra session into that would pause running work about one
  # session's burn early, every sweep.
  test "the fleet decision projects no extra session" do
    calibrate(capacity_usd: 1000.0)
    burn_rate(1.0)
    seed(current_5h: 0.30, current_7d: 0.05)
    running_session(0)

    fleet = SpotGateService.fleet_decision
    assert_in_delta 1.0, fleet.fleet_burn_usd_per_minute, 0.0001
    assert_in_delta 0.0, fleet.candidate_burn_usd_per_minute, 0.0001
    assert_in_delta 1.0, fleet.projected_burn_usd_per_minute, 0.0001
  end

  # A fleet merely ahead of the curve is throttled at the door, never
  # interrupted: killing a running turn to enforce a curve spends a lost tool
  # call and protects nothing. Only a spent budget stops running work.
  test "being ahead of the pacing curve holds new work but does not stop running work" do
    running_session(0)
    seed(current_5h: 0.40, current_7d: 0.05, reset_5h: 4.hours.from_now)

    decision = SpotGateService.evaluate
    refute decision.allowed?, "ahead of the curve, so nothing new starts"
    refute decision.stops_running_work?, "…but what is running keeps running"
    refute decision.five_hour.stops_running_work?
  end

  test "a spent spot budget does stop running work" do
    running_session(0)
    seed(current_5h: 0.92, current_7d: 0.05, reset_5h: 4.hours.from_now)

    decision = SpotGateService.evaluate
    refute decision.allowed?
    assert decision.stops_running_work?, "the reserve is worth interrupting a turn for"
  end

  test "a fleet-cap hold never stops running work" do
    seed(current_5h: 0.02, current_7d: 0.05)
    @setting.update!(spot_max_concurrent_sessions: 1)
    running_session(0)

    decision = SpotGateService.evaluate
    assert_equal "fleet_at_cap", decision.reason
    refute decision.stops_running_work?
  end

  # --- the resume margin -------------------------------------------------------

  # The ceiling half of the policy needs a different line from the admission
  # half. Holding a session that has not started costs nothing; resuming one that
  # was interrupted mid-turn costs a lost tool call, so it waits for real
  # headroom rather than resuming the instant the window dips back inside the
  # budget and pushing it straight over again.
  test "the resume decision holds inside the margin, where a starting session would be admitted" do
    seed(current_5h: 0.78, current_7d: 0.10)

    assert SpotGateService.evaluate.allowed?, "78% is inside the 80% spot budget for a session starting now"

    resume = SpotGateService.resume_decision
    refute resume.allowed?
    assert_equal "at_utilization_limit", resume.reason
    assert_in_delta 75.0, resume.five_hour.spot_budget_pct, 0.001,
      "the resume decision reports the budget it actually decided on"
  end

  test "the resume decision allows once utilization clears the margin" do
    seed(current_5h: 0.74, current_7d: 0.10)

    decision = SpotGateService.resume_decision
    assert decision.allowed?
    assert_equal "within_limits", decision.reason
  end

  # The margin widens the reserve; it never inverts it. A 97% reserve with a
  # 5-point margin must not produce a negative spot budget that no reading can be
  # inside of.
  test "the margin cannot push the spot budget below zero" do
    @setting.update!(spot_reserve_five_hour_pct: 97)
    seed(current_5h: 0.0, current_7d: 0.10)

    decision = SpotGateService.resume_decision
    assert_in_delta 0.0, decision.five_hour.spot_budget_pct, 0.001
    refute decision.allowed?, "a zero spot budget has no room for anything, including zero"
  end

  test "the weekly window pauses spot work on its own" do
    seed(current_5h: 0.10, current_7d: 0.95)
    decision = SpotGateService.evaluate

    refute decision.allowed?
    assert_equal "at_utilization_limit", decision.reason
    assert decision.weekly.at_limit?
    assert_match(/weekly window is at 95% of the 80% spot budget/, decision.detail)
  end

  # The hold is not a cancellation and not a forecast: when the number comes back
  # down, the very next evaluation runs work again.
  test "spot work resumes as soon as utilization falls back inside the budget" do
    seed(current_5h: 0.85, current_7d: 0.10)
    assert SpotGateService.evaluate.held?

    seed(current_5h: 0.62, current_7d: 0.10)
    decision = SpotGateService.evaluate

    assert decision.allowed?, "the hold lasts exactly as long as the number does"
    assert_equal "within_limits", decision.reason
  end

  test "a smaller reserve lets the same reading through" do
    seed(current_5h: 0.85, current_7d: 0.10)
    assert SpotGateService.evaluate.held?

    @setting.update!(spot_reserve_five_hour_pct: 10)
    assert SpotGateService.evaluate.allowed?
  end

  test "a passed reset reads as zero utilization, matching effective_utilization" do
    seed(current_5h: 0.99, current_7d: 0.99, reset_5h: 1.minute.ago, reset_7d: 1.minute.ago)

    decision = SpotGateService.evaluate
    assert decision.allowed?, "a window whose reset has passed carries nothing"
    assert_equal 0.0, decision.five_hour.current
  end

  # --- the pool, not one account ----------------------------------------------

  # What Tadas asked for: one account at 95% used to hold the whole fleet while
  # the rest of the pool sat idle. Rotation moves work off a refused account onto
  # the ones with headroom, so the quota a deployment can spend is the pool's.
  test "one account at its cap does not hold the fleet while the pool has room" do
    seed(current_5h: 0.95, current_7d: 0.10)
    seed_spare(email: "spare@example.com", current_5h: 0.05, current_7d: 0.10)

    decision = SpotGateService.evaluate
    assert decision.allowed?, "the pool averages 50% — well under the 80% target"
    assert_in_delta 50.0, decision.five_hour.current_pct, 0.001
    assert_equal 2, decision.accounts_read
  end

  test "the pool holds once the average reaches the target" do
    seed(current_5h: 0.95, current_7d: 0.10)
    seed_spare(email: "spare@example.com", current_5h: 0.75, current_7d: 0.10)

    decision = SpotGateService.evaluate
    refute decision.allowed?, "85% averaged across the pool is past the 80% target"
    assert_equal "at_utilization_limit", decision.reason
    assert_in_delta 85.0, decision.five_hour.current_pct, 0.001
  end

  # The explicit half of the ask. An account waiting on a human to re-authenticate
  # is one Zimmer cannot serve from this minute, not one whose quota is spent —
  # its window keeps draining, and its headroom is real again on the next login.
  test "an account in needs_reauth counts toward the aggregate" do
    seed(current_5h: 0.95, current_7d: 0.10)
    seed_spare(email: "reauth@example.com", current_5h: 0.05, current_7d: 0.10,
               status: :needs_reauth)

    decision = SpotGateService.evaluate
    assert decision.allowed?, "a needs_reauth account's headroom counts in the average"
    assert_equal 2, decision.accounts_read
    assert_in_delta 50.0, decision.five_hour.current_pct, 0.001
  end

  test "a needs_reauth account with a spent window raises the average like any other" do
    seed(current_5h: 0.70, current_7d: 0.10)
    seed_spare(email: "reauth-spent@example.com", current_5h: 0.99, current_7d: 0.10,
               status: :needs_reauth)

    decision = SpotGateService.evaluate
    refute decision.allowed?, "counting it cuts both ways — 84.5% averaged is past the target"
    assert_equal "at_utilization_limit", decision.reason
    assert_equal 2, decision.accounts_read
  end

  # An account already marked quota_exceeded is in the pool too — its reading is
  # what says it has nothing left, and dropping it would flatter the average.
  test "a quota_exceeded account is averaged in rather than skipped" do
    seed(current_5h: 0.30, current_7d: 0.10)
    seed_spare(email: "pool-exceeded@example.com", current_5h: 0.99, current_7d: 0.10,
               status: :quota_exceeded)

    decision = SpotGateService.evaluate
    assert_equal 2, decision.accounts_read
    assert_in_delta 64.5, decision.five_hour.current_pct, 0.001
  end

  # The one correction the pool figure carries, and it is the page's rule, not a
  # second one invented for the gate: an account whose week is gone cannot serve
  # a request, so its empty 5-hour counter is not headroom.
  test "an account whose weekly window is spent counts as 100% in the 5-hour figure" do
    seed(current_5h: 0.60, current_7d: 0.10)
    seed_spare(email: "weekly-spent@example.com", current_5h: 0.01, current_7d: 1.0)

    decision = SpotGateService.evaluate
    assert_in_delta 80.0, decision.five_hour.current_pct, 0.001
    refute decision.allowed?, "the dead account's 1% is not room the pool can spend"
  end

  test "an account with no reading is left out of the average and named as such" do
    seed(current_5h: 0.85, current_7d: 0.10)
    ClaudeAccount.create!(email: "unread@example.com", runtime: "claude_code",
                          oauth_config: { "x" => 1 })

    decision = SpotGateService.evaluate
    refute decision.allowed?, "the accounts that HAVE readings are the ones that decide"
    assert_equal 1, decision.accounts_read
    assert_equal pool_size, decision.pool_size
    assert_match(/averaged across 1 of #{pool_size} accounts/, decision.detail)
  end

  # The decision names the aggregate rather than an account, on every surface that
  # renders it — /inference, get_spot_policy, and Decision#to_h all read these.
  test "the hold detail names the pool, not one account" do
    seed(current_5h: 0.95, current_7d: 0.10)
    seed_spare(email: "spare@example.com", current_5h: 0.95, current_7d: 0.10)

    decision = SpotGateService.evaluate
    refute decision.allowed?
    assert_match(/5-hour window is at 95% of the 80% spot budget, averaged across 2 of #{pool_size} accounts/,
                 decision.detail)
    refute_match(/@example\.com/, decision.detail, "no single account may be named as the reason")
    assert_equal 2, decision.to_h[:accounts_read]
    assert_equal pool_size, decision.to_h[:pool_size]
  end

  test "an allowed decision reports the pool it read, too" do
    seed(current_5h: 0.10, current_7d: 0.10)

    decision = SpotGateService.evaluate
    assert decision.allowed?
    assert_match(/averaged across 1 of #{pool_size} accounts/, decision.detail)
  end

  # The pool figure the gate decides on and the one /inference prints in its headline
  # are the same computation, so the page cannot show 42% beside a hold at 95%.
  test "the gate decides on the same average /inference renders" do
    seed(current_5h: 0.95, current_7d: 0.10)
    seed_spare(email: "spare@example.com", current_5h: 0.05, current_7d: 0.10)

    measure = ClaudeAccountPool.measure
    decision = SpotGateService.evaluate

    assert_in_delta measure.five_hour * 100, decision.five_hour.current_pct, 0.001
    assert_in_delta measure.weekly * 100, decision.weekly.current_pct, 0.001
  end

  # A snapshot whose two utilization columns are both nil says nothing. Reading it
  # as "no window at its target" would let an empty row run the deployment.
  test "a reading with neither window readable is not a reading" do
    ClaudeAccountQuotaSnapshot.create!(
      claude_account: @account, utilization_5h: nil, utilization_7d: nil,
      reset_5h: 2.hours.from_now, reset_7d: 2.days.from_now,
      active_session_count: 1, trigger: "usage_sample"
    )

    decision = SpotGateService.evaluate
    assert decision.allowed?
    assert_equal "no_snapshot", decision.reason
  end

  test "one unreadable window still decides on the other" do
    ClaudeAccountQuotaSnapshot.create!(
      claude_account: @account, utilization_5h: nil, utilization_7d: 0.85,
      reset_5h: 2.hours.from_now, reset_7d: 2.days.from_now,
      active_session_count: 1, trigger: "usage_sample"
    )

    decision = SpotGateService.evaluate
    refute decision.allowed?
    assert_nil decision.five_hour
    assert decision.weekly.at_limit?
  end

  # --- the fleet cap -----------------------------------------------------------

  test "sessions run in parallel up to the cap, then the next one waits" do
    seed(current_5h: 0.02, current_7d: 0.10)
    @setting.update!(spot_max_concurrent_sessions: 3)

    2.times { |i| running_session(i) }
    assert SpotGateService.evaluate.allowed?, "two of three slots taken — the third still starts"

    running_session(2)
    decision = SpotGateService.evaluate

    refute decision.allowed?, "every slot is taken"
    assert_equal "fleet_at_cap", decision.reason
    assert_equal 3, decision.fleet_cap
    assert_equal 3, decision.active_sessions
    assert_match(/3 of 3 session slots taken/, decision.detail)
  end

  # tadasant/zimmer#957. The fleet cap read 15 of 10 while eight agent processes
  # were alive: `running` is stamped when a turn is handed to a session, so the
  # column also held turns queued for a worker and rows that had gone back to
  # sleep on their own wake. The queued ones still count — they take the next
  # free slot — but a session no start path will run before its wake cannot hold
  # a slot against anything.
  test "a running row asleep on its own future wake does not hold the fleet at cap" do
    seed(current_5h: 0.02, current_7d: 0.10)
    @setting.update!(spot_max_concurrent_sessions: 2)
    2.times { |i| running_session(i) }
    assert SpotGateService.evaluate.held?, "two of two slots taken"

    arm_wake!(Session.where(status: :running).last, at: 20.minutes.from_now)
    decision = SpotGateService.evaluate

    assert decision.allowed?, "a session Zimmer refuses to start before its wake holds no slot"
    assert_equal 1, decision.active_sessions
  end

  # The detail string is what /inference and `get_spot_policy` print, and the
  # queue is the whole explanation for a slot count above the live agent-process
  # count. Without it the number reads as a broken counter.
  test "a fleet-cap hold names the worker pool when turns are queued behind it" do
    seed(current_5h: 0.02, current_7d: 0.10)
    @setting.update!(spot_max_concurrent_sessions: 2)
    working = running_session(0)
    working.update!(running_job_id: SecureRandom.uuid)
    GoodJob::Job.create!(active_job_id: working.running_job_id, queue_name: "agents",
                         job_class: "AgentSessionJob", serialized_params: {},
                         scheduled_at: 2.minutes.ago, performed_at: 1.minute.ago)
    running_session(1)

    decision = SpotGateService.evaluate

    assert_equal "fleet_at_cap", decision.reason
    assert_equal 2, decision.active_sessions
    assert_equal 1, decision.queued_sessions
    assert_match(/2 of 2 session slots taken/, decision.detail)
    assert_match(/1 on a worker, 1 queued for one/, decision.detail)
  end

  test "the cap is the operator's, and raising it runs work immediately" do
    seed(current_5h: 0.02, current_7d: 0.10)
    @setting.update!(spot_max_concurrent_sessions: 2)
    2.times { |i| running_session(i) }
    assert SpotGateService.evaluate.held?

    @setting.update!(spot_max_concurrent_sessions: 10)
    assert SpotGateService.evaluate.allowed?
  end

  # The asymmetry Tadas asked for, in one test: the cap gates spot work and does
  # not gate priority work.
  test "a full fleet holds a spot session and lets a priority session through" do
    seed(current_5h: 0.02, current_7d: 0.10)
    @setting.update!(spot_max_concurrent_sessions: 2)
    2.times { |i| running_session(i) }

    spot = Session.create!(git_root: "https://github.com/t/r.git", prompt: "s", genesis: SessionGenesis::GITHUB_ISSUE)
    priority = Session.create!(git_root: "https://github.com/t/r.git", prompt: "p", genesis: SessionGenesis::WEB_UI)

    refute SpotGateService.allow_start?(spot)
    assert SpotGateService.allow_start?(priority), "the cap must never gate priority work"
    assert_equal "priority", SpotGateService.start_decision(priority).reason
  end

  # And the consequence, as its own case because it is intended rather than
  # incidental: priority work crowds spot work out of the slots entirely.
  test "a fleet of priority sessions leaves zero spot slots" do
    seed(current_5h: 0.02, current_7d: 0.10)
    @setting.update!(spot_max_concurrent_sessions: 10)
    10.times { |i| running_session(i, genesis: SessionGenesis::WEB_UI) }

    decision = SpotGateService.evaluate
    refute decision.allowed?, "ten priority sessions leave nothing for spot work, by design"
    assert_equal "fleet_at_cap", decision.reason
    assert_equal 10, decision.active_sessions

    priority = Session.create!(git_root: "https://github.com/t/r.git", prompt: "p", genesis: SessionGenesis::WEB_UI)
    assert SpotGateService.allow_start?(priority), "an eleventh priority session still starts"
  end

  # The cap is a start-time check. A session already running is never reconsidered
  # — lowering the cap under a running fleet holds the next start, and touches
  # nothing that is already going.
  test "the cap is checked at start, so lowering it never stops running work" do
    seed(current_5h: 0.02, current_7d: 0.10)
    running = 3.times.map { |i| running_session(i) }

    @setting.update!(spot_max_concurrent_sessions: 1)
    assert SpotGateService.evaluate.held?
    assert running.all? { |s| s.reload.running? }, "the gate must not touch a session that is already running"
  end

  # Codex sessions spend nothing against a Claude account, so they do not take a
  # slot the Claude quota is being protected for.
  test "only Claude Code sessions count toward the cap" do
    seed(current_5h: 0.02, current_7d: 0.10)
    @setting.update!(spot_max_concurrent_sessions: 1)
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "codex", genesis: SessionGenesis::WEB_UI,
                    status: :running, agent_runtime: "codex")

    assert SpotGateService.evaluate.allowed?
    assert_equal 0, SpotGateService.evaluate.active_sessions
  end

  # --- classification ----------------------------------------------------------

  test "allow_start? never consults the gate for a priority session" do
    seed(current_5h: 0.99, current_7d: 0.99)
    priority = Session.create!(git_root: "https://github.com/t/r.git", prompt: "p", genesis: SessionGenesis::WEB_UI)
    spot = Session.create!(git_root: "https://github.com/t/r.git", prompt: "s", genesis: SessionGenesis::GITHUB_ISSUE)

    assert SpotGateService.allow_start?(priority)
    refute SpotGateService.allow_start?(spot)
  end

  test "a priority session is answered without consulting quota at all" do
    seed(current_5h: 0.99, current_7d: 0.99)
    priority = Session.create!(git_root: "https://github.com/t/r.git", prompt: "p", genesis: SessionGenesis::WEB_UI)

    decision = SpotGateService.start_decision(priority)
    assert decision.allowed?
    assert_equal "priority", decision.reason
  end

  test "promoting a genesis lets its sessions start immediately" do
    seed(current_5h: 0.99, current_7d: 0.99)
    spot = Session.create!(git_root: "https://github.com/t/r.git", prompt: "s", genesis: SessionGenesis::API)
    refute SpotGateService.allow_start?(spot)

    @setting.set_genesis_class(SessionGenesis::API, SessionGenesis::PRIORITY)
    @setting.save!

    assert SpotGateService.allow_start?(spot.reload),
      "the one-click promotion has to take effect for sessions that already exist"
  end

  test "a session that named its own class starts on that, not on its genesis" do
    seed(current_5h: 0.99, current_7d: 0.99)
    held = Session.create!(git_root: "https://github.com/t/r.git", prompt: "s", genesis: SessionGenesis::GITHUB_ISSUE)
    refute SpotGateService.allow_start?(held)

    held.update!(scheduling_class: SessionGenesis::PRIORITY)

    assert SpotGateService.allow_start?(held.reload),
      "this is the lever for one held session — no trigger and no policy is touched"
  end

  # --- the incident ------------------------------------------------------------

  # The state production was in at 2026-08-16T01:10Z: the serving account at 69%
  # weekly with the 5-hour window freshly reset to 1%, one session running — and
  # 25 spot sessions that had been waiting up to 23 hours behind a forecast that
  # projected 122%. Six days into the week, 69% is inside the curve, and the
  # queue has to run.
  test "the production incident runs the queue" do
    seed(current_5h: 0.01, current_7d: 0.69, reset_7d: 12.hours.from_now)
    running_session(0)

    decision = SpotGateService.evaluate
    assert decision.allowed?, "both windows are inside their budgets and their curves — the queue has to run"
    assert_equal "within_limits", decision.reason
    assert_equal 1, decision.active_sessions
    assert_equal 10, decision.fleet_cap

    # And it runs in parallel: nine more start before the limit binds.
    9.times { |i| running_session(i + 1) }
    assert SpotGateService.evaluate.held?
    assert_equal "fleet_at_cap", SpotGateService.evaluate.reason
  end

  # The counterpart, and the reason the curve exists: the SAME 69% early in the
  # week is ahead of pace. The old gate saw one number and answered "under the
  # target, run flat out" whichever day it was, which is how a week's allowance
  # got spent by Wednesday.
  test "the same weekly reading is throttled early in the week" do
    seed(current_5h: 0.01, current_7d: 0.69, reset_7d: 5.days.from_now)
    running_session(0)

    decision = SpotGateService.evaluate
    refute decision.allowed?, "69% spent with five days of the week left is ahead of the curve"
    assert_equal "at_utilization_limit", decision.reason
    assert decision.weekly.within_cap, "the budget is not spent — the pace is what refuses"
    refute decision.weekly.within_pace
  end

  # Both brakes engaged at once: the target is the one reported, because a window
  # at its target is the more specific fact and the one that outlasts the fleet.
  test "a window at its target outranks a full fleet in the reason" do
    seed(current_5h: 0.85, current_7d: 0.10)
    @setting.update!(spot_max_concurrent_sessions: 1)
    running_session(0)

    decision = SpotGateService.evaluate
    refute decision.allowed?
    assert_equal "at_utilization_limit", decision.reason
  end

  # --- which ceiling is holding ------------------------------------------------

  # `at_utilization_limit` covers two ceilings that behave differently, and
  # before #ceiling existed there was no way for a surface to tell them apart —
  # which is how /inference came to announce that running sessions were being paused
  # during holds that pause nothing.
  test "a spent budget and a fleet ahead of the curve are different ceilings" do
    calibrate(capacity_usd: 1000.0)
    seed(current_5h: 0.30, reset_5h: 100.minutes.from_now)
    burn_rate(4.0)
    running_session(0)

    pacing = SpotGateService.evaluate
    assert_equal SpotGateService::UTILIZATION_REASON, pacing.reason
    assert_equal :pacing_curve, pacing.ceiling
    refute pacing.stops_running_work?, "the pace never interrupts a running turn"

    seed(current_5h: 0.85, reset_5h: 100.minutes.from_now)
    budget = SpotGateService.evaluate
    assert_equal SpotGateService::UTILIZATION_REASON, budget.reason
    assert_equal :spot_budget, budget.ceiling
    assert budget.stops_running_work?
  end

  # CEILINGS is the documented set every surface branches over, so a fourth
  # ceiling added without updating it would be a silent gap in the copy.
  test "every ceiling a decision can report is one of the documented CEILINGS" do
    seed(current_5h: 0.10)
    assert_nil SpotGateService.evaluate.ceiling

    @setting.update!(spot_max_concurrent_sessions: 1)
    running_session(0)
    assert_includes SpotGateService::CEILINGS, SpotGateService.evaluate.ceiling

    @setting.update!(spot_max_concurrent_sessions: 10)
    seed(current_5h: 0.95)
    assert_includes SpotGateService::CEILINGS, SpotGateService.evaluate.ceiling
  end

  test "the fleet cap is its own ceiling, and an allowed decision has none" do
    @setting.update!(spot_max_concurrent_sessions: 1)
    seed(current_5h: 0.10)
    running_session(0)

    assert_equal :fleet_cap, SpotGateService.evaluate.ceiling

    @setting.update!(spot_max_concurrent_sessions: 10)
    assert_nil SpotGateService.evaluate.ceiling
  end

  # --- what the surfaces need to explain the hold ------------------------------

  test "held_windows names only the windows that actually refused" do
    calibrate(capacity_usd: 1000.0)
    seed(current_5h: 0.85, current_7d: 0.05, reset_5h: 100.minutes.from_now)
    burn_rate(2.0)

    decision = SpotGateService.evaluate
    assert_equal [ "5-hour" ], decision.held_windows.keys,
      "the weekly window has no dollar estimate and is nowhere near its curve"
  end

  # The rate the copy tells a reader to get under. It has to come from the window
  # that refused, not from whichever window happens to be first.
  test "sustainable_usd_per_minute is the tightest rate among the holding windows" do
    calibrate(capacity_usd: 1000.0)
    seed(current_5h: 0.30, current_7d: 0.05, reset_5h: 100.minutes.from_now)
    burn_rate(4.0)
    running_session(0)

    decision = SpotGateService.evaluate
    assert_equal [ "5-hour" ], decision.held_windows.keys
    assert_in_delta 5.0, decision.sustainable_usd_per_minute, 0.05,
      "$500 of spot budget left over 100 minutes"
  end

  # `held_windows` is every window that refused; `budget_spent_windows` is the
  # subset whose money is actually gone. Copy that conflates them says a window
  # with budget left is spent, and bounds the wait on a rollover that window
  # does not have to reach.
  test "budget_spent_windows is narrower than held_windows on a mixed hold" do
    calibrate(capacity_usd: 1000.0)
    calibrate(capacity_usd: 1000.0, window: QuotaCapacityEstimate::WEEKLY)
    seed(current_5h: 0.85, current_7d: 0.30,
         reset_5h: 100.minutes.from_now, reset_7d: 5.days.from_now)
    burn_rate(2.0)
    running_session(0)

    decision = SpotGateService.evaluate
    assert_equal :spot_budget, decision.ceiling
    assert_equal %w[5-hour weekly], decision.held_windows.keys
    assert_equal [ "5-hour" ], decision.budget_spent_windows.keys

    kind, seconds = decision.resume_outlook
    assert_equal :spot_budget, kind
    assert_in_delta 100.minutes.to_i, seconds, 60,
      "the bound comes from the spent window, not the one merely ahead of its curve"
  end

  # Both windows holding means both have to clear, so the LATEST rollover is the
  # binding one — an outlook built from the earliest would promise release while
  # the other window still refused.
  test "resume_outlook takes the latest rollover of the holding windows" do
    calibrate(capacity_usd: 1000.0)
    calibrate(capacity_usd: 1000.0, window: QuotaCapacityEstimate::WEEKLY)
    seed(current_5h: 0.85, current_7d: 0.85,
         reset_5h: 100.minutes.from_now, reset_7d: 20.hours.from_now)
    burn_rate(2.0)

    decision = SpotGateService.evaluate
    assert_equal %w[5-hour weekly], decision.held_windows.keys
    kind, seconds = decision.resume_outlook
    assert_equal :spot_budget, kind
    assert_in_delta 20.hours.to_i, seconds, 60
  end

  # There is no honest ETA for either of these, and resume_outlook says so with a
  # nil rather than reaching for the nearest number.
  test "resume_outlook offers no time for the fleet cap" do
    @setting.update!(spot_max_concurrent_sessions: 1)
    seed(current_5h: 0.10)
    running_session(0)

    assert_equal [ :fleet_cap, nil ], SpotGateService.evaluate.resume_outlook
  end

  test "resume_outlook offers no time when nothing is held" do
    seed(current_5h: 0.10)

    assert_equal [ nil, nil ], SpotGateService.evaluate.resume_outlook
  end

  # --- pool capacity ------------------------------------------------------------
  #
  # The pool's answer to "when does this stop being true", carried through to
  # every surface that reports on the gate. The property under test throughout is
  # that the Decision carries what ClaudeAccountPool::Measure measured — a second
  # computation on the reporting side is exactly what these forbid.

  test "the decision carries the pool's capacity answer, measured not recomputed" do
    # Both windows spent, so every one of the four fields carries a real value —
    # a pool where they all happened to be nil would prove nothing about drift.
    seed(current_5h: 1.0, current_7d: 1.0,
         reset_5h: 90.minutes.from_now, reset_7d: 3.days.from_now)

    measure = ClaudeAccountPool.measure
    capacity = SpotGateService.evaluate.pool_capacity

    refute_nil capacity
    refute_nil measure.next_capacity_at
    refute_nil measure.next_weekly_reset
    assert_equal measure.next_capacity_at, capacity.next_capacity_at
    assert_equal measure.next_weekly_reset, capacity.next_weekly_reset
    assert_equal measure.capacity_now?, capacity.capacity_now?
    assert_equal measure.weekly_spent_count, capacity.weekly_spent_count
    assert_equal measure.read_count, capacity.read_count
    assert_equal measure.servable_count, capacity.servable_count
  end

  # A measure over nothing would report "nobody has capacity and nobody knows
  # when", which is a claim about a pool that was never probed. The page guards
  # the same way before it renders a banner.
  test "a measure with no readings produces no capacity answer at all" do
    assert_nil SpotGateService::PoolCapacity.from(ClaudeAccountPool.measure)
  end

  test "a pool with room reports capacity now and no time to wait for" do
    seed(current_5h: 0.10, current_7d: 0.10)

    capacity = SpotGateService.evaluate.pool_capacity

    assert capacity.capacity_now?
    assert_nil capacity.next_capacity_at, "there is nothing to wait for while the pool is serving"
    assert_equal 0, capacity.weekly_spent_count
    assert_nil capacity.next_weekly_reset
    assert_equal 1, capacity.read_count
    assert_equal 1, capacity.servable_count
  end

  # The two nil cases for `next_capacity_at`, which a caller cannot tell apart
  # from the timestamp alone: nothing to wait for, and nothing that knows.
  test "a blocked pool with a recorded reset carries the moment it comes back" do
    seed(current_5h: 1.0, current_7d: 0.10, reset_5h: 45.minutes.from_now)

    capacity = SpotGateService.evaluate.pool_capacity

    refute capacity.capacity_now?
    assert_in_delta 45.minutes.from_now.to_f, capacity.next_capacity_at.to_f, 5
    assert_equal 0, capacity.servable_count
  end

  test "a blocked pool that recorded no reset carries a nil the counts explain" do
    ClaudeAccountQuotaSnapshot.create!(
      claude_account: @account, utilization_5h: 1.0, utilization_7d: 0.10,
      reset_5h: nil, reset_7d: nil, active_session_count: 1, trigger: "usage_sample"
    )

    capacity = SpotGateService.evaluate.pool_capacity

    refute capacity.capacity_now?, "no capacity now, and no timestamp either"
    assert_nil capacity.next_capacity_at
  end

  # The weekly reset is measured over the accounts whose week IS spent, so the
  # count is what says whether a nil means "nothing is waiting on a week" or
  # "the accounts waiting on one cannot say when".
  test "a spent week carries its soonest recorded rollover and the count behind it" do
    seed(current_5h: 0.10, current_7d: 1.0, reset_7d: 3.days.from_now)

    capacity = SpotGateService.evaluate.pool_capacity

    assert_equal 1, capacity.weekly_spent_count
    assert_in_delta 3.days.from_now.to_f, capacity.next_weekly_reset.to_f, 5
  end

  test "a spent week with no recorded rollover keeps the count and nils the time" do
    ClaudeAccountQuotaSnapshot.create!(
      claude_account: @account, utilization_5h: 0.10, utilization_7d: 1.0,
      reset_5h: 2.hours.from_now, reset_7d: nil, active_session_count: 1, trigger: "usage_sample"
    )

    capacity = SpotGateService.evaluate.pool_capacity

    assert_equal 1, capacity.weekly_spent_count
    assert_nil capacity.next_weekly_reset
  end

  # A decision reached without reading the pool has no pool answer to give, and
  # says nil rather than inventing "capacity now".
  test "a decision made without a pool reading carries no capacity answer" do
    @setting.update!(spot_gating_enabled: false)
    assert_nil SpotGateService.evaluate.pool_capacity

    @setting.update!(spot_gating_enabled: true)
    assert_nil SpotGateService.evaluate.pool_capacity, "no snapshot, no pool answer"

    assert_nil SpotGateService::ALWAYS_ALLOWED.pool_capacity
  end

  test "to_h serializes the capacity answer alongside the windows" do
    seed(current_5h: 1.0, current_7d: 0.10, reset_5h: 30.minutes.from_now)

    serialized = SpotGateService.evaluate.to_h[:pool_capacity]

    refute_nil serialized
    assert_equal false, serialized[:capacity_now]
    assert_in_delta 30.minutes.from_now.to_f, serialized[:next_capacity_at].to_f, 5
  end

  private

  def running_session(index, genesis: SessionGenesis::WEB_UI)
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "running #{index}",
                    genesis: genesis, status: :running, agent_runtime: "claude_code")
  end

  # Arms a one-time wake against `session` for a time that has not come, without
  # the after_create hooks that would sleep or immediately fire it.
  def arm_wake!(session, at:)
    Trigger.new(
      name: "Wake session ##{session.id}",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "wake up",
      reuse_session: true,
      last_session_id: session.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule",
          configuration: { "scheduled_at" => at.utc.strftime("%Y-%m-%dT%H:%M:%S"), "timezone" => "UTC" } }
      ]
    ).save!(validate: true)
  end
end
