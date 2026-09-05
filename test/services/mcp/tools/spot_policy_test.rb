# frozen_string_literal: true

require "test_helper"

# MCP parity for the spot/priority surface: everything the /settings card shows
# and does must be reachable over MCP.
class Mcp::Tools::SpotPolicyTest < ActiveSupport::TestCase
  setup do
    @context = Mcp::Context.new(base_url: "http://test.host")
    AppSetting.editable.update!(spot_gating_enabled: false, genesis_class_overrides: {})
  end

  def get_policy
    Mcp::Tools::GetSpotPolicy.new(context: @context).call({})
  end

  def action(args)
    Mcp::Tools::ActionSpotPolicy.new(context: @context).call(args.stringify_keys)
  end

  # --- registry ---------------------------------------------------------------

  test "both tools are registered in the health group" do
    names = Mcp::Registry.tools_for(%w[health]).map(&:tool_name)
    assert_includes names, "get_spot_policy"
    assert_includes names, "action_spot_policy"
  end

  test "the write tool is absent from the readonly health group" do
    names = Mcp::Registry.tools_for(%w[health_readonly]).map(&:tool_name)
    assert_includes names, "get_spot_policy"
    refute_includes names, "action_spot_policy"
  end

  # --- read -------------------------------------------------------------------

  test "get_spot_policy reports the setting, the decision and every genesis" do
    output = get_policy

    assert_match(/Gating enabled:\*\* no/, output)
    assert_match(/5-hour priority reserve:\*\* 20%/, output)
    assert_match(/Current decision/, output)
    SessionGenesis::KEYS.each { |key| assert_match(/`#{key}`/, output) }
  end

  # The page and the tool render the same decision, which is the property that
  # keeps the card's badge and the tool's answer from disagreeing.
  test "get_spot_policy reports the live decision and both windows" do
    # The gate averages every account with a reading. Leave only this one with
    # anything to say.
    ClaudeAccountQuotaSnapshot.delete_all
    account = ClaudeAccount.create!(email: "mcp-window@example.com", runtime: "claude_code",
                                    oauth_config: { "x" => 1 }, is_current: true)
    ClaudeAccountQuotaSnapshot.create!(claude_account: account, utilization_5h: 0.42, utilization_7d: 0.10,
      reset_5h: 2.hours.from_now, reset_7d: 2.days.from_now, active_session_count: 1,
      trigger: "usage_sample")
    AppSetting.editable.update!(spot_gating_enabled: true,
                                spot_reserve_five_hour_pct: 20, spot_reserve_weekly_pct: 20)

    output = get_policy
    decision = SpotGateService.evaluate

    assert_match(/Windows averaged across:\*\* 1 of \d+ accounts in the pool/, output)
    assert_match(/needs_reauth included/, output)
    refute_match(/mcp-window@example\.com/, output,
                 "the decision is the pool's, so no single account is named as the one that decides")
    assert_match(/Utilization now:\*\* 42\.0%/, output)
    assert_match(/Has room for a spot session:\*\* yes/, output)
    assert_match(/Spot budget:\*\* 80\.0% of the window/, output)
    assert_match(/Pacing curve says:\*\* 48\.0%/, output)
    assert_equal decision.allowed?, output.include?("**Spot sessions:** running"),
      "the tool must report the same decision the page renders"
  end

  test "get_spot_policy says when a window has no room for a spot session" do
    ClaudeAccountQuotaSnapshot.delete_all
    account = ClaudeAccount.create!(email: "mcp-at-limit@example.com", runtime: "claude_code",
                                    oauth_config: { "x" => 1 }, is_current: true)
    ClaudeAccountQuotaSnapshot.create!(claude_account: account, utilization_5h: 0.85, utilization_7d: 0.10,
      reset_5h: 2.hours.from_now, reset_7d: 2.days.from_now, active_session_count: 1,
      trigger: "usage_sample")
    AppSetting.editable.update!(spot_gating_enabled: true,
                                spot_reserve_five_hour_pct: 20, spot_reserve_weekly_pct: 20)

    output = get_policy
    assert_match(/Spot sessions:\*\* HELD/, output)
    assert_match(/Reason:\*\* `at_utilization_limit`/, output)
    assert_match(/Has room for a spot session:\*\* no — spot budget spent/, output)
    # `at_utilization_limit` covers two ceilings. An agent reading this tool has
    # to be able to tell which, because only one of them pauses running work.
    assert_match(/Ceiling holding spot work:\*\* `spot_budget`/, output)
    assert_match(/Why it's held:\*\* The 5-hour window's spot budget is spent/, output)
    assert_match(/Held until:\*\* No sooner than the 5-hour window's rollover/, output)
  end

  # The other half of the same reason string: ahead of the curve, budget intact.
  # The tool must not describe this as a spent budget, and must not offer a
  # rollover as if it were an ETA.
  test "get_spot_policy tells a pacing hold apart from a spent budget" do
    ClaudeAccountQuotaSnapshot.delete_all
    HarnessModelBurnRate.delete_all
    account = ClaudeAccount.create!(email: "mcp-pacing@example.com", runtime: "claude_code",
                                    oauth_config: { "x" => 1 }, is_current: true)
    ClaudeAccountQuotaSnapshot.create!(claude_account: account, utilization_5h: 0.30, utilization_7d: 0.05,
      reset_5h: 100.minutes.from_now, reset_7d: 2.days.from_now, active_session_count: 1,
      trigger: "usage_sample")
    QuotaCapacityEstimate.create!(window_key: QuotaCapacityEstimate::FIVE_HOUR, capacity_usd: 1000.0,
      sample_cost_usd: 500.0, sample_utilization: 0.5, observation_count: 5, computed_at: Time.current)
    HarnessModelBurnRate.create!(harness: "zimmer", model: "claude-opus-5", usd_per_minute: 4.0,
      sample_cost_usd: 400.0, sample_minutes: 100.0, sample_session_count: 25, computed_at: Time.current)
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "running", status: :running,
                    genesis: SessionGenesis::WEB_UI, agent_runtime: "claude_code")
    AppSetting.editable.update!(spot_gating_enabled: true, spot_max_concurrent_sessions: 10,
                                spot_reserve_five_hour_pct: 20, spot_reserve_weekly_pct: 20)

    output = get_policy
    assert_match(/Reason:\*\* `at_utilization_limit`/, output)
    assert_match(/Ceiling holding spot work:\*\* `pacing_curve`/, output)
    assert_match(/Why it's held:\*\* The 5-hour window's spot budget still has \$500 left/, output)
    assert_match(/already running are not paused for this/, output)
    assert_match(/Held until:\*\* When the fleet's burn falls to or below/, output)
    assert_match(/upper bound on the wait, not a forecast/, output)
  end

  # --- when the pool comes back -----------------------------------------------
  #
  # The parity gap this closed (tadasant/zimmer#568): /inference answered "when does
  # the account pool come back" and the tool could only say "it is down". An agent
  # deciding between sleeping on a wake and escalating needs the duration.

  # One account with a reading, and nothing else in the pool with anything to say.
  # Defaults to a spent 5-hour window, which is the state the new lines are about;
  # every case below varies one field off that.
  def seed_pool(reset_5h:, utilization_5h: 1.0, utilization_7d: 0.10, reset_7d: 2.days.from_now)
    ClaudeAccountQuotaSnapshot.delete_all
    account = ClaudeAccount.create!(email: "mcp-pool-#{SecureRandom.hex(4)}@example.com",
                                    runtime: "claude_code", oauth_config: { "x" => 1 })
    ClaudeAccountQuotaSnapshot.create!(claude_account: account, utilization_5h: utilization_5h,
      utilization_7d: utilization_7d, reset_5h: reset_5h, reset_7d: reset_7d,
      active_session_count: 1, trigger: "usage_sample")
    AppSetting.editable.update!(spot_gating_enabled: true,
                                spot_reserve_five_hour_pct: 20, spot_reserve_weekly_pct: 20)
    account
  end

  # travel_to, because the countdown is floored to the minute: a wall-clock
  # `90.minutes.from_now` becomes "1 hour and 29 minutes" the moment setup takes a
  # second, and a test that flips on timing is worse than no test.
  test "get_spot_policy says when the account pool comes back, as a countdown and a wall clock" do
    travel_to Time.utc(2026, 9, 3, 12, 0, 0) do
      reset = 90.minutes.from_now
      seed_pool(reset_5h: reset)

      output = get_policy

      assert_match(/Account pool capacity:\*\* The one account with a reading is out of capacity\./, output)
      assert_match(/The first one has room on both windows again in 1 hour and 30 minutes/, output)
      assert_match(/\(Sep 3, 13:30 UTC\)/, output)
    end
  end

  test "get_spot_policy counts down in minutes, and says so when there is less than one" do
    seed_pool(reset_5h: Time.current + 30.seconds)

    assert_match(/room on both windows again in under a minute/, get_policy)
  end

  # The branch for a deadline that crosses between the measurement and the render.
  # ClaudeAccountPool never records a reset already in the past, and an account
  # whose window has rolled is no longer blocked, so this is only reachable from a
  # decision built before the deadline passed — which is exactly the race it is
  # for. It is the tool's half of the page's "That moment has passed — refresh for
  # a fresh reading", so it is worth pinning rather than leaving to a live race.
  #
  # It also pins the shape of the 7-day sentence, whose own clause follows this
  # phrase: two stacked em-dashes there read as a sentence that lost its way.
  test "get_spot_policy calls a reset that has just passed stale rather than counting to zero" do
    passed = 2.minutes.ago
    capacity = SpotGateService::PoolCapacity.new(
      next_capacity_at: passed, next_weekly_reset: passed,
      capacity_now: false, weekly_spent_count: 1, read_count: 1, servable_count: 0
    )
    stamp = Regexp.escape(passed.utc.strftime(ClaudeAccountPool::RESET_TIME_FORMAT))

    SpotGateService.stub(:evaluate, decision_carrying(capacity)) do
      output = get_policy

      assert_match(/again now \(#{stamp}\); that moment has passed, so this reading is stale/, output)
      assert_match(/Next 7-day reset:\*\* now \(#{stamp}\); that moment has passed, so this reading is stale — the soonest recorded among 1 account/,
                   output)
    end
  end

  # ALWAYS_ALLOWED and the `unavailable` decision both carry a nil count, and the
  # split line has to survive one — the same guard the /inference card relies on.
  test "get_spot_policy renders a decision that carries no session counts" do
    SpotGateService.stub(:evaluate, SpotGateService::ALWAYS_ALLOWED) do
      output = get_policy

      # The line renders with an empty count and, crucially, no split clause —
      # `nil - nil` would have raised.
      assert_match(/- \*\*Claude Code sessions with a turn in flight:\*\* *\n/, output)
    end
  end

  def decision_carrying(capacity)
    SpotGateService::Decision.new(
      allowed: true, reason: "within_limits", detail: "within limits",
      five_hour: nil, weekly: nil, active_sessions: 0, awaiting_sessions: 0, fleet_cap: 10,
      accounts_read: 1, pool_size: 1,
      fleet_burn_usd_per_minute: 0.0, candidate_burn_usd_per_minute: 0.0,
      pool_capacity: capacity
    )
  end

  # Gating off is not the same emptiness as an unprobed pool, and only the second
  # one is empty on /inference too. The page measures the pool whatever the gate
  # setting is; with gating off (the default) the tool used to say nothing at all.
  test "get_spot_policy reports the pool even when spot gating is turned off" do
    seed_pool(reset_5h: 90.minutes.from_now)
    AppSetting.editable.update!(spot_gating_enabled: false)

    output = get_policy

    assert_match(/Gating enabled:\*\* no/, output)
    assert_match(/Spot sessions:\*\* running/, output)
    assert_match(/Account pool capacity:\*\* The one account with a reading is out of capacity\./, output)
    assert_match(/The first one has room on both windows again in 1 hour/, output)
  end

  # The property the change exists for: the tool reports what the Measure
  # measured. A second computation on the reporting side is what would let the
  # page and the tool drift.
  test "get_spot_policy reports the same moment ClaudeAccountPool measured" do
    seed_pool(reset_5h: 4.hours.from_now)

    measured = ClaudeAccountPool.measure.next_capacity_at
    refute_nil measured

    assert_match(/#{Regexp.escape(measured.utc.strftime("%b %-d, %H:%M UTC"))}/, get_policy,
                 "the tool and /inference must render one measurement, not two")
  end

  test "get_spot_policy says the pool has capacity now rather than printing a blank time" do
    seed_pool(reset_5h: 2.hours.from_now, utilization_5h: 0.10)

    output = get_policy

    assert_match(/Account pool capacity:\*\* available now — 1 account of 1 with a reading has room on both windows right now/, output)
    refute_match(/Account pool capacity:\*\*\s*\n/, output, "a nil timestamp must never render as an empty answer")
  end

  # The other nil: everything is out, and nothing recorded a way back. Saying
  # "unknown" out loud beats a blank, which reads as "no problem".
  test "get_spot_policy names the absence when nothing recorded a reset time" do
    seed_pool(reset_5h: nil, reset_7d: nil)

    assert_match(/No reset time is recorded for the blocked windows, so nothing here says when the pool comes back/,
                 get_policy)
  end

  test "get_spot_policy reports the 7-day rollover under the weekly window" do
    travel_to Time.utc(2026, 9, 3, 12, 0, 0) do
      seed_pool(reset_5h: 2.hours.from_now, utilization_5h: 0.10,
                utilization_7d: 1.0, reset_7d: 3.days.from_now)

      output = get_policy

      assert_match(/Next 7-day reset:\*\* in 3 days \(Sep 6, 12:00 UTC\)/, output)
      assert_match(/the soonest recorded among 1 account whose 7-day window is spent/, output)
      assert_operator output.index("### Weekly window"), :<, output.index("Next 7-day reset"),
                      "the 7-day rollover belongs under the window it is about"
    end
  end

  test "get_spot_policy says nothing is waiting on a 7-day reset when no week is spent" do
    seed_pool(reset_5h: 90.minutes.from_now)

    assert_match(/Next 7-day reset:\*\* no account's 7-day window is spent/, get_policy)
  end

  test "get_spot_policy names a spent week that recorded no rollover" do
    seed_pool(reset_5h: 2.hours.from_now, utilization_5h: 0.10, utilization_7d: 1.0, reset_7d: nil)

    assert_match(/Next 7-day reset:\*\* unknown — 1 account with a spent 7-day window, and no reset time recorded for it/,
                 get_policy)
  end

  # No pool reading at all is a third state, and the tool must not answer it by
  # implying the pool is fine.
  test "get_spot_policy omits the pool capacity line when there is no reading" do
    ClaudeAccountQuotaSnapshot.delete_all
    AppSetting.editable.update!(spot_gating_enabled: true)

    output = get_policy

    refute_match(/Account pool capacity/, output)
    refute_match(/Next 7-day reset/, output)
  end

  # A weekly window with no reading renders a sentence rather than a list, so the
  # 7-day line has to be separated from it or the two run together as one
  # paragraph that reads like a contradiction.
  test "get_spot_policy keeps the 7-day line off a weekly window with no reading" do
    seed_pool(reset_5h: 90.minutes.from_now, utilization_7d: nil, reset_7d: nil)

    section = get_policy[/### Weekly window.*?(?=\n### )/m]

    assert_includes section, "No reading available.\n\n- **Next 7-day reset:**"
  end

  # The readonly group serves the same tool object, so the reset information is
  # not something the readonly variant can be missing — asserted rather than
  # assumed, because a divergent readonly surface is the parity bug one level up.
  test "the readonly health group serves the same reset information" do
    seed_pool(reset_5h: 90.minutes.from_now)

    readonly = Mcp::Registry.tools_for(%w[health_readonly]).find { |t| t.tool_name == "get_spot_policy" }
    assert_equal Mcp::Tools::GetSpotPolicy, readonly

    assert_match(/Account pool capacity:\*\*/, readonly.new(context: @context).call({}))
  end

  # Parity with /inference, which renders the same count: the decision above answers
  # "would a session STARTING now be held", and this answers "did anything that
  # was already running get stopped" — an agent whose own turn was cut short has
  # to be able to read that second answer.
  test "get_spot_policy reports how many spot sessions are asleep in the queue" do
    output = get_policy
    assert_match(/Spot sessions paused mid-run by the ceiling:\*\* 0/, output)
    assert_match(/by the ceiling:\*\* 0\. The ceiling has stopped nothing/, output)

    Session.create!(
      git_root: "https://github.com/t/r.git", prompt: "work", status: :waiting,
      genesis: SessionGenesis::GITHUB_ISSUE,
      metadata: {
        SpotSessionPause::PAUSED_AT => 1.hour.ago.utc.iso8601,
        SpotSessionPause::PAUSED_REASON => "at_utilization_limit",
        SpotSessionPause::PAUSED_DETAIL => "Holding spot sessions: 5-hour window is at 89% of the 80% spot budget."
      }
    )

    output = get_policy
    assert_match(/Spot sessions paused mid-run by the ceiling:\*\* 1/, output)
    # The count is of DORMANT sessions, and the sentence has to say so — reading
    # it as running sessions is what made the figure look like a contradiction
    # beside the concurrency limit.
    assert_match(/It was paused mid-run when a window's spot budget ran out/, output)
    assert_match(/asleep rather than running/, output)
  end

  # The defect Tadas hit from the reporting side. This tool printed
  # SpotSessionPause.paused_count under "asleep in the spot queue" — a heading
  # that reads like every dormant spot session — so on 2026-08-31 it asserted
  # "asleep in the spot queue: 0" while session 7507, spot and `waiting` and held
  # 145 times, was demonstrably asleep on a hold (tadasant/zimmer#648). The two
  # populations are disjoint and resume by different mechanisms, so both are
  # reported, in the same words the /inference card uses.
  test "get_spot_policy counts spot sessions held before a turn, not just paused ones" do
    output = get_policy
    assert_match(/Spot sessions held before a turn:\*\* 0/, output)
    assert_match(/Nothing is waiting at the door/, output)

    held_session(retry_at: 20.minutes.from_now)

    output = get_policy
    assert_match(/Spot sessions held before a turn:\*\* 1/, output)
    assert_match(/dormant in waiting before a turn the gate refused/, output)
    # It is a hold, not a pause: the pause figure must not move.
    assert_match(/Spot sessions paused mid-run by the ceiling:\*\* 0/, output)
  end

  test "get_spot_policy reports a held session whose re-check is overdue as overdue" do
    held_session(retry_at: 10.hours.ago)

    output = get_policy

    assert_match(/Spot sessions held before a turn:\*\* 1, 1 of them overdue for a re-check/, output)
    assert_match(/Its own re-check time has already passed/, output)
    assert_match(/SpotHoldSweepJob/, output)
  end

  def held_session(retry_at:)
    Session.create!(
      git_root: "https://github.com/t/r.git", prompt: "work", status: :waiting,
      genesis: SessionGenesis::GITHUB_ISSUE,
      metadata: {
        SpotSessionHold::HELD_AT => 11.hours.ago.utc.iso8601,
        SpotSessionHold::HELD_REASON => "fleet_at_cap",
        SpotSessionHold::HELD_DETAIL => "Holding spot sessions: 5 of 5 session slots taken.",
        SpotSessionHold::HELD_RETRY_AT => retry_at.utc.iso8601,
        SpotSessionHold::HELD_COUNT => 145,
        SpotSessionHold::HELD_TURN => SpotSessionHold::TURN_RESUME
      }
    )
  end

  # Parity with /inference: an agent asking why it is held has to see the same
  # aggregate the page shows, including the accounts a human cannot serve from.
  test "get_spot_policy averages every account, needs_reauth included" do
    ClaudeAccountQuotaSnapshot.delete_all
    ClaudeAccount.for_runtime("claude_code").destroy_all
    serving = ClaudeAccount.create!(email: "mcp-serving@example.com", runtime: "claude_code",
                                    oauth_config: { "x" => 1 }, is_current: true)
    reauth = ClaudeAccount.create!(email: "mcp-reauth@example.com", runtime: "claude_code",
                                   oauth_config: { "x" => 1 }, status: :needs_reauth)
    ClaudeAccountQuotaSnapshot.create!(claude_account: serving, utilization_5h: 0.95, utilization_7d: 0.10,
      reset_5h: 2.hours.from_now, reset_7d: 2.days.from_now, active_session_count: 1, trigger: "usage_sample")
    ClaudeAccountQuotaSnapshot.create!(claude_account: reauth, utilization_5h: 0.05, utilization_7d: 0.10,
      reset_5h: 2.hours.from_now, reset_7d: 2.days.from_now, active_session_count: 1, trigger: "usage_sample")
    AppSetting.editable.update!(spot_gating_enabled: true,
                                spot_reserve_five_hour_pct: 20, spot_reserve_weekly_pct: 20)

    output = get_policy

    assert_match(/Windows averaged across:\*\* all 2 accounts in the pool/, output)
    assert_match(/Utilization now:\*\* 50\.0%/, output,
                 "the serving account alone reads 95% — the pool average is what the tool reports")
  end

  test "get_spot_policy reflects a demotion" do
    action(action: "demote_genesis", genesis: SessionGenesis::WEB_UI)
    output = get_policy

    assert_match(/`web_ui` \| Zimmer web app \| \*\*spot\*\* \(changed from priority\)/, output)
  end

  test "get_spot_policy says where each kind's class is set" do
    output = get_policy

    assert_match(/`web_ui`.*`action_spot_policy`/, output)
    assert_match(/`slack`.*the trigger/, output)
  end

  test "get_spot_policy lists the triggers that carry a class of their own" do
    assert_match(/None — every trigger derives its class/, get_policy)

    trigger = triggers(:enabled_schedule_trigger)
    trigger.update!(scheduling_class: SessionGenesis::PRIORITY)

    output = get_policy
    assert_match(/Triggers with their own class/, output)
    assert_match(/#{Regexp.escape(trigger.name)}/, output)
    assert_match(/\*\*priority\*\*/, output)
  end

  # --- write ------------------------------------------------------------------

  test "set_gating turns the gate on and sets both reserves" do
    action(action: "set_gating", enabled: true, five_hour_reserve_pct: 70, weekly_reserve_pct: 60)

    setting = AppSetting.current
    assert setting.spot_gating_enabled
    assert_equal 70, setting.spot_reserve_five_hour_pct
    assert_equal 60, setting.spot_reserve_weekly_pct
  end

  test "set_gating leaves omitted fields alone" do
    action(action: "set_gating", enabled: true, five_hour_reserve_pct: 55)
    action(action: "set_gating", weekly_reserve_pct: 45)

    setting = AppSetting.current
    assert setting.spot_gating_enabled, "an omitted enabled flag must not turn the gate off"
    assert_equal 55, setting.spot_reserve_five_hour_pct
    assert_equal 45, setting.spot_reserve_weekly_pct
  end

  # Parity: the cap is on the /inference form, so an agent has to be able to set it
  # and read it back without a human at the page.
  test "set_gating sets the max concurrent sessions cap, and get reports it" do
    action(action: "set_gating", enabled: true, max_concurrent_sessions: 4)

    assert_equal 4, AppSetting.current.spot_max_concurrent_sessions
    assert_match(/Max sessions at once:\*\* 4/, get_policy)
  end

  test "an out-of-range cap comes back as a message rather than an internal error" do
    AppSetting.editable.update!(spot_max_concurrent_sessions: 10)

    error = assert_raises(Mcp::ToolError) { action(action: "set_gating", max_concurrent_sessions: 0) }
    assert_match(/Invalid spot policy/, error.message)
    assert_equal 10, AppSetting.current.spot_max_concurrent_sessions
  end

  test "set_gating with nothing to change is an error rather than a silent no-op" do
    assert_raises(Mcp::ToolError) { action(action: "set_gating") }
  end

  # --- backlog top-up ---------------------------------------------------------
  #
  # Parity: the three knobs are on the /inference card, so an agent has to be
  # able to set them and read them back without a human at the page.

  test "set_top_up writes all three knobs, and get reports them" do
    action(action: "set_top_up", max_running_sessions: 5, idle_minutes: 10,
           min_fire_interval_minutes: 30)

    setting = AppSetting.current
    assert_equal 5, setting.fleet_idle_max_sessions
    assert_equal 10, setting.fleet_idle_threshold_minutes
    assert_equal 30, setting.fleet_idle_min_fire_interval_minutes

    policy = get_policy
    assert_match(/Fires while the fleet has fewer turns in flight than:\*\* 5 sessions/, policy)
    assert_match(/For at least:\*\* 10 minutes/, policy)
    assert_match(/At most once every:\*\* 30 minutes \(at most 48 top-ups a day/, policy)
  end

  test "set_top_up leaves omitted knobs alone" do
    AppSetting.editable.update!(fleet_idle_max_sessions: 4, fleet_idle_threshold_minutes: 7,
                                fleet_idle_min_fire_interval_minutes: 90)

    action(action: "set_top_up", max_running_sessions: 6)

    setting = AppSetting.current
    assert_equal 6, setting.fleet_idle_max_sessions
    assert_equal 7, setting.fleet_idle_threshold_minutes
    assert_equal 90, setting.fleet_idle_min_fire_interval_minutes
  end

  test "an out-of-range top-up value comes back as a message rather than an internal error" do
    AppSetting.editable.update!(fleet_idle_max_sessions: 3)

    error = assert_raises(Mcp::ToolError) { action(action: "set_top_up", max_running_sessions: 0) }
    assert_match(/Invalid top-up policy/, error.message)
    assert_equal 3, AppSetting.current.fleet_idle_max_sessions
  end

  test "set_top_up with nothing to change is an error rather than a silent no-op" do
    assert_raises(Mcp::ToolError) { action(action: "set_top_up") }
  end

  # The echo exists so a caller does not have to make a second call to learn what
  # its change did to the cadence.
  test "set_top_up echoes back how often top-up can now fire" do
    result = action(action: "set_top_up", min_fire_interval_minutes: 15)

    assert_match(/at most 96 top-ups a day/, result)
  end

  # A cooldown over a day is legal, and the per-day figure floors to 0 there.
  # "0 times a day" reads as "never", which is wrong.
  test "a cooldown longer than a day is reported as an interval, not as zero a day" do
    result = action(action: "set_top_up", min_fire_interval_minutes: 2880)

    assert_match(/at most once every 2 days/, result)
    assert_no_match(/0 top-ups a day/, result)
    assert_match(/at most once every 2 days/, get_policy)
  end

  # An explicit null is skipped rather than assigned to a NOT NULL column, and a
  # call carrying nothing else is an error rather than an empty save.
  test "set_top_up skips explicit nulls" do
    AppSetting.editable.update!(fleet_idle_max_sessions: 4)

    action(action: "set_top_up", max_running_sessions: nil, idle_minutes: 8)

    setting = AppSetting.current
    assert_equal 4, setting.fleet_idle_max_sessions
    assert_equal 8, setting.fleet_idle_threshold_minutes

    assert_raises(Mcp::ToolError) { action(action: "set_top_up", max_running_sessions: nil) }
  end

  test "get_spot_policy names which of the not-fired-yet states the fleet is in" do
    # Above the fixtures' running population, so the fleet is genuinely under its
    # ceiling and the clocks are what decide.
    AppSetting.editable.update!(fleet_idle_since: nil, fleet_idle_event_fired_at: nil,
                                fleet_idle_max_sessions: 100)

    assert_match(/State:\*\* `clock_not_started`/, get_policy)

    AppSetting.editable.update!(fleet_idle_since: 30.minutes.ago, fleet_idle_event_fired_at: 25.minutes.ago)
    policy = get_policy
    assert_match(/State:\*\* `latched`/, policy)
    assert_match(/no clock running toward one/, policy)
  end

  test "promote_genesis reclassifies existing sessions" do
    session = Session.create!(git_root: "https://github.com/t/r.git", prompt: "x", genesis: SessionGenesis::API)
    assert session.spot?

    output = action(action: "promote_genesis", genesis: SessionGenesis::API)

    assert_match(/is now \*\*priority\*\*/, output)
    assert session.reload.priority?, "the promotion must apply to sessions that already exist"
  end

  test "a trigger-backed genesis is refused, and says where to set it instead" do
    error = assert_raises(Mcp::ToolError) do
      action(action: "demote_genesis", genesis: SessionGenesis::SLACK)
    end

    assert_match(/takes its class from the trigger/, error.message)
    assert_match(/action_trigger/, error.message)
    assert_equal({}, AppSetting.current.genesis_class_overrides)
  end

  test "every trigger-backed kind is refused" do
    SessionGenesis::TRIGGER_BACKED_KEYS.each do |key|
      assert_raises(Mcp::ToolError, "#{key} should not be settable here") do
        action(action: "promote_genesis", genesis: key)
      end
    end
  end

  test "demote_genesis moves a kind to spot" do
    action(action: "demote_genesis", genesis: SessionGenesis::WEB_UI)
    assert_equal SessionGenesis::SPOT, SessionGenesis.effective_class(SessionGenesis::WEB_UI)
  end

  test "reset_genesis_classes drops every override" do
    action(action: "promote_genesis", genesis: SessionGenesis::API)
    action(action: "demote_genesis", genesis: SessionGenesis::WEB_UI)
    action(action: "reset_genesis_classes")

    assert_equal({}, AppSetting.current.genesis_class_overrides)
    assert_equal SessionGenesis::SPOT, SessionGenesis.effective_class(SessionGenesis::API)
    assert_equal SessionGenesis::PRIORITY, SessionGenesis.effective_class(SessionGenesis::WEB_UI)
  end

  test "the tool only advertises the settable kinds" do
    enum = Mcp::Tools::ActionSpotPolicy.input_schema.to_h.dig(:properties, :genesis, :enum)
    assert_equal SessionGenesis::SETTABLE_KEYS, enum
  end

  test "an unknown action is rejected" do
    assert_raises(Mcp::ToolError) { action(action: "delete_everything") }
  end

  test "an unknown genesis is rejected" do
    assert_raises(Mcp::ToolError) { action(action: "promote_genesis", genesis: "carrier_pigeon") }
  end

  test "an out-of-range reserve comes back as a readable tool error" do
    error = assert_raises(Mcp::ToolError) do
      action(action: "set_gating", five_hour_reserve_pct: 150)
    end
    assert_match(/Invalid spot policy/, error.message)
  end
end
