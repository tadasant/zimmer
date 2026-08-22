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
    @setting.update!(spot_gating_enabled: true,
                     spot_gate_five_hour_threshold_pct: 80,
                     spot_gate_weekly_threshold_pct: 80,
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
      Session.stub(:running_claude_code_count, ->(*) { raise klass, "boom" }) do
        decision = SpotGateService.evaluate
        assert decision.allowed?, "#{klass} must not be able to hold a session"
        assert_equal "unavailable", decision.reason
      end
    end
  end

  # --- the targets -------------------------------------------------------------

  test "a window under its target runs spot sessions" do
    seed(current_5h: 0.42, current_7d: 0.10)

    decision = SpotGateService.evaluate
    assert decision.allowed?
    assert_equal "within_limits", decision.reason
    assert_in_delta 42.0, decision.five_hour.current_pct, 0.001
    assert_equal 80.0, decision.five_hour.threshold_pct
  end

  # The whole point of the rewrite: work runs right up to the target rather than
  # backing off from a projection of where it might land. 79% still runs.
  test "spot work runs at 79% and pauses at exactly the target" do
    seed(current_5h: 0.79, current_7d: 0.10)
    assert SpotGateService.evaluate.allowed?, "under the target is under the target"

    seed(current_5h: 0.80, current_7d: 0.10)
    decision = SpotGateService.evaluate

    refute decision.allowed?
    assert_equal "at_utilization_limit", decision.reason
    assert decision.five_hour.at_limit?
    refute decision.weekly.at_limit?
    assert_match(/5-hour window at 80% of its 80% target/, decision.detail)
  end

  # --- the resume margin -------------------------------------------------------

  # The ceiling half of the policy needs a different line from the admission
  # half. Holding a session that has not started costs nothing; resuming one that
  # was interrupted mid-turn costs a lost tool call, so it waits for real
  # headroom rather than resuming the instant the window dips under the target
  # and pushing it straight back over.
  test "the resume decision holds inside the margin, where a starting session would be admitted" do
    seed(current_5h: 0.78, current_7d: 0.10)

    assert SpotGateService.evaluate.allowed?, "78% is under the 80% target for a session starting now"

    resume = SpotGateService.resume_decision
    refute resume.allowed?
    assert_equal "at_utilization_limit", resume.reason
    assert_in_delta 75.0, resume.five_hour.threshold_pct, 0.001,
      "the resume decision reports the target it actually decided on"
  end

  test "the resume decision allows once utilization clears the margin" do
    seed(current_5h: 0.74, current_7d: 0.10)

    decision = SpotGateService.resume_decision
    assert decision.allowed?
    assert_equal "within_limits", decision.reason
  end

  # The margin lowers the target; it never inverts it. A 3% target with a 5-point
  # margin must not become a negative threshold that no reading can clear.
  test "the margin cannot push a target below zero" do
    @setting.update!(spot_gate_five_hour_threshold_pct: 3)
    seed(current_5h: 0.0, current_7d: 0.10)

    decision = SpotGateService.resume_decision
    assert_in_delta 0.0, decision.five_hour.threshold_pct, 0.001
    refute decision.allowed?, "a zero target is reached by any reading, including zero"
  end

  test "the weekly window pauses spot work on its own" do
    seed(current_5h: 0.10, current_7d: 0.95)
    decision = SpotGateService.evaluate

    refute decision.allowed?
    assert_equal "at_utilization_limit", decision.reason
    assert decision.weekly.at_limit?
    assert_match(/weekly window at 95% of its 80% target/, decision.detail)
  end

  # The pause is not a cancellation and not a forecast: when the number comes back
  # down, the very next evaluation runs work again.
  test "spot work resumes as soon as utilization falls back under the target" do
    seed(current_5h: 0.85, current_7d: 0.10)
    assert SpotGateService.evaluate.held?

    seed(current_5h: 0.62, current_7d: 0.10)
    decision = SpotGateService.evaluate

    assert decision.allowed?, "the hold lasts exactly as long as the number does"
    assert_equal "within_limits", decision.reason
  end

  test "a higher target lets the same reading through" do
    seed(current_5h: 0.85, current_7d: 0.10)
    assert SpotGateService.evaluate.held?

    @setting.update!(spot_gate_five_hour_threshold_pct: 90)
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
  # renders it — /quotas, get_spot_policy, and Decision#to_h all read these.
  test "the hold detail names the pool, not one account" do
    seed(current_5h: 0.95, current_7d: 0.10)
    seed_spare(email: "spare@example.com", current_5h: 0.95, current_7d: 0.10)

    decision = SpotGateService.evaluate
    refute decision.allowed?
    assert_match(/5-hour window at 95% of its 80% target, averaged across 2 of #{pool_size} accounts/,
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

  # The pool figure the gate decides on and the one /quotas prints in its headline
  # are the same computation, so the page cannot show 42% beside a hold at 95%.
  test "the gate decides on the same average /quotas renders" do
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
  # projected 122%.
  test "the production incident runs the queue" do
    seed(current_5h: 0.01, current_7d: 0.69)
    running_session(0)

    decision = SpotGateService.evaluate
    assert decision.allowed?, "both windows are under their targets — the queue has to run"
    assert_equal "within_limits", decision.reason
    assert_equal 1, decision.active_sessions
    assert_equal 10, decision.fleet_cap

    # And it runs in parallel: nine more start before the limit binds.
    9.times { |i| running_session(i + 1) }
    assert SpotGateService.evaluate.held?
    assert_equal "fleet_at_cap", SpotGateService.evaluate.reason
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

  private

  def running_session(index, genesis: SessionGenesis::WEB_UI)
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "running #{index}",
                    genesis: genesis, status: :running, agent_runtime: "claude_code")
  end
end
