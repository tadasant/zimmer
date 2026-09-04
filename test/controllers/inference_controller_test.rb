# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "support/fake_parameter_store"

class InferenceControllerTest < ActionDispatch::IntegrationTest
  setup do
    # switch_account now always probes Anthropic's OAuth endpoint via
    # refresh_token! before allowing the switch. Stub a generic success
    # response so tests that don't explicitly exercise refresh failure get
    # a passing probe.
    successful_refresh = Net::HTTPSuccess.new("1.1", "200", "OK")
    successful_refresh.stubs(:code).returns("200")
    successful_refresh.stubs(:body).returns({
      access_token: "stubbed-access-token",
      refresh_token: "stubbed-refresh-token",
      expires_in: 3600
    }.to_json)
    Net::HTTP.any_instance.stubs(:request).returns(successful_refresh)

    # switch_account now routes through AccountRotationService#activate!,
    # which writes ~/.claude.json + ~/.claude/.credentials.json and takes a
    # quota snapshot. Redirect filesystem writes to a tmp dir and stub the
    # snapshot probe so tests don't touch real credentials or call the API.
    @switch_tmpdir = Dir.mktmpdir
    @original_claude_json = ClaudeAuthProvider::CLAUDE_JSON_PATH
    @original_credentials_json = ClaudeAuthProvider::CREDENTIALS_JSON_PATH
    ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
    ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, File.join(@switch_tmpdir, "claude.json"))
    ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
    ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, File.join(@switch_tmpdir, ".credentials.json"))

    QuotaCheckService.stubs(:check_with_token).returns(
      QuotaCheckService::Result.new(
        success: true,
        subscription_type: "claude_max",
        rate_limit_tier: "tier_4",
        utilization_5h: 0.5,
        utilization_7d: 0.3,
        status_5h: "allowed",
        status_7d: "allowed",
        reset_5h: 3.hours.from_now,
        reset_7d: 5.days.from_now
      )
    )

    # Codex activate! writes ~/.codex/auth.json. Redirect it to a tmp dir so
    # codex switch/delete tests don't clobber the real worker auth file.
    @codex_tmpdir = Dir.mktmpdir
    @original_codex_auth_json = CodexAuthProvider::AUTH_JSON_PATH
    CodexAuthProvider.send(:remove_const, :AUTH_JSON_PATH)
    CodexAuthProvider.const_set(:AUTH_JSON_PATH, File.join(@codex_tmpdir, "auth.json"))
  end

  teardown do
    FileUtils.rm_rf(@switch_tmpdir) if @switch_tmpdir
    FileUtils.rm_rf(@codex_tmpdir) if @codex_tmpdir
    if @original_claude_json
      ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
      ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, @original_claude_json)
    end
    if @original_credentials_json
      ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
      ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, @original_credentials_json)
    end
    if @original_codex_auth_json
      CodexAuthProvider.send(:remove_const, :AUTH_JSON_PATH)
      CodexAuthProvider.const_set(:AUTH_JSON_PATH, @original_codex_auth_json)
    end
  end

  # ── show (renders immediately with cached data) ───────────────────

  test "show renders page with cached snapshots" do
    get inference_url

    assert_response :success
    assert_select "h1", "Inference"
    assert_select "#aggregate_stats"
    assert_select "h2", "Accounts"
  end

  # ── the account-level badge tracks the reading, not the sticky column ──
  #
  # Production shape: two accounts wearing "Quota Exceeded" beside windows their
  # own snapshots reported as Allowed at 35%/12%, hours after the sweep that was
  # supposed to clear them. The column is only ever cleared by a background job,
  # so anything that stops that job — a rotation stamping an account with no
  # quota evidence, or a deploy that froze every queue for ten hours (#426) —
  # leaves the page lying until someone notices.

  test "show does not present an exceeded account whose windows have cleared" do
    account = exceeded_account_with_cleared_windows

    get inference_url

    assert_response :success
    assert_equal "Active", account_badge_text(account)
  end

  test "show heals the status column of an exceeded account whose windows have cleared" do
    # Not cosmetic: `available` and AccountRotationService read the column, so a
    # page that only fixed the badge would still leave the account out of the pool.
    account = exceeded_account_with_cleared_windows

    get inference_url

    assert_response :success
    assert account.reload.active?
  end

  test "show keeps the exceeded label for an account the API is still rejecting" do
    account = claude_accounts(:exceeded)
    ClaudeAccountQuotaSnapshot.delete_all
    ClaudeAccountQuotaSnapshot.create!(
      claude_account: account, trigger: "scheduled",
      utilization_5h: 0.0, status_5h: "allowed", reset_5h: 2.hours.from_now,
      utilization_7d: 1.0, status_7d: "rejected", reset_7d: 3.days.from_now
    )

    get inference_url

    assert_response :success
    assert_equal "Quota Exceeded", account_badge_text(account)
    assert account.reload.quota_exceeded?, "an account that cannot serve must stay out of the pool"
  end

  test "show never softens needs_reauth, which only a human clears" do
    account = claude_accounts(:exceeded)
    account.update!(status: :needs_reauth)
    ClaudeAccountQuotaSnapshot.delete_all
    ClaudeAccountQuotaSnapshot.create!(
      claude_account: account, trigger: "scheduled",
      utilization_5h: 0.35, status_5h: "allowed", reset_5h: 26.minutes.from_now,
      utilization_7d: 0.12, status_7d: "allowed", reset_7d: 6.days.from_now
    )

    get inference_url

    assert_response :success
    assert_equal "Needs Reauth", account_badge_text(account)
    assert account.reload.needs_reauth?
  end

  test "show counts a cleared account as active in the pool totals" do
    exceeded_account_with_cleared_windows

    get inference_url

    assert_response :success
    # Every fixture account is healthy except :exceeded, which has just cleared.
    pool_size = ClaudeAccount.for_runtime(ClaudeAuthProvider::RUNTIME).count
    assert_match(/#{pool_size} Total #{pool_size} Active 0 Quota Exceeded/, aggregate_stats_text)
  end

  # ── aggregate 5-hour figure reflects availability, not the raw counter ──

  test "show counts a 7d-blocked account as fully utilized in the 5-hour aggregate" do
    # The shape that motivated this: plenty of 5-hour headroom on paper, but the
    # 7-day window turns every request away. Averaging the raw 29% would report
    # pool headroom that cannot be served.
    seed_aggregate_snapshots(
      { utilization_5h: 0.29, status_5h: "allowed", reset_5h: 72.minutes.from_now,
        utilization_7d: 1.0, status_7d: "rejected", reset_7d: 1.day.from_now },
      { utilization_5h: 0.20, status_5h: "allowed", reset_5h: 2.hours.from_now,
        utilization_7d: 0.30, status_7d: "allowed", reset_7d: 5.days.from_now }
    )

    get inference_url

    assert_response :success
    stats = aggregate_stats_text
    # (100% + 20%) / 2, not the raw (29% + 20%) / 2 = 24.5%.
    assert_match(/Avg 5-Hour Utilization \(effective\) 60\.0% Worst: 100\.0%/, stats)
    assert_match(/1 account counted that way now/, stats)
    assert_match(/Avg 7-Day Utilization 65\.0%/, stats)
  end

  # ── the pool's reset notes ──

  # The reported bug, through the page. The account that unblocks the pool
  # soonest is the one whose 5-hour window is *already* free and whose week is
  # spent — and the old headline could not name it, because it was measured only
  # over accounts with weekly allowance left. It advertised the other account's
  # 5-hour rollover, hours later.
  test "show counts down to the weekly reset that frees an already-free 5-hour window" do
    weekly_back = 22.minutes.from_now
    five_hour_back = 232.minutes.from_now

    seed_aggregate_snapshots(
      { utilization_5h: 0.0, status_5h: "allowed", reset_5h: 40.minutes.from_now,
        utilization_7d: 1.0, status_7d: "rejected", reset_7d: weekly_back },
      { utilization_5h: 1.03, status_5h: "rejected", reset_5h: five_hour_back,
        utilization_7d: 0.79, status_7d: "allowed", reset_7d: 5.days.from_now }
    )

    get inference_url

    assert_response :success
    stats = aggregate_stats_text
    assert_match "Work unblocked in", stats
    assert_match "room on both its 5-hour and 7-day windows: #{utc_reset_text(weekly_back)}", stats
    # The other account's 5-hour rollover, which is not when work resumes.
    assert_no_match(/#{Regexp.escape(utc_reset_text(five_hour_back))}/, stats)
    assert_match "All 2 accounts with a reading are out of capacity.", stats
    # The 7-day note below still describes its own window, over the accounts
    # whose week is spent.
    assert_match "Next 7-day reset: #{utc_reset_text(weekly_back)}", stats
  end

  # The tick is driven off an absolute instant in the markup, so a page left
  # open counts down to the right moment instead of freezing on the server's
  # string.
  test "show hands the countdown an absolute deadline to tick from" do
    weekly_back = 35.minutes.from_now

    seed_aggregate_snapshots(
      { utilization_5h: 0.0, status_5h: "allowed", reset_5h: 40.minutes.from_now,
        utilization_7d: 1.0, status_7d: "rejected", reset_7d: weekly_back },
      { utilization_5h: 1.0, status_5h: "rejected", reset_5h: 4.hours.from_now,
        utilization_7d: 0.20, status_7d: "allowed", reset_7d: 5.days.from_now }
    )

    get inference_url

    assert_response :success
    assert_select "[data-controller=?]", "unblock-countdown"
    assert_select "[data-unblock-countdown-deadline-value^=?]",
      weekly_back.utc.strftime("%Y-%m-%dT%H:%M")
  end

  test "show says work is not blocked while an account has room on both windows" do
    seed_aggregate_snapshots(
      { utilization_5h: 0.20, status_5h: "allowed", reset_5h: 40.minutes.from_now,
        utilization_7d: 0.30, status_7d: "allowed", reset_7d: 5.days.from_now },
      { utilization_5h: 1.0, status_5h: "rejected", reset_5h: 2.hours.from_now,
        utilization_7d: 0.20, status_7d: "allowed", reset_7d: 5.days.from_now }
    )

    get inference_url

    assert_response :success
    stats = aggregate_stats_text
    assert_match "Work is not blocked", stats
    assert_match "1 account of 2 with a reading has room on both windows", stats
    # Nothing to count down to, so no clock.
    assert_select "[data-controller='unblock-countdown']", count: 0
  end

  test "show says nothing is waiting on a 7-day reset when no week is spent" do
    seed_aggregate_snapshots(
      { utilization_5h: 0.45, status_5h: "allowed", reset_5h: 3.hours.from_now,
        utilization_7d: 0.30, status_7d: "allowed", reset_7d: 5.days.from_now },
      { utilization_5h: 0.25, status_5h: "allowed", reset_5h: 2.hours.from_now,
        utilization_7d: 0.10, status_7d: "allowed", reset_7d: 4.days.from_now }
    )

    get inference_url

    assert_response :success
    assert_match "No account's 7-day window is spent", aggregate_stats_text
  end

  test "show averages the raw 5-hour counters when both windows are healthy" do
    seed_aggregate_snapshots(
      { utilization_5h: 0.45, status_5h: "allowed", reset_5h: 3.hours.from_now,
        utilization_7d: 0.30, status_7d: "allowed", reset_7d: 5.days.from_now },
      { utilization_5h: 0.25, status_5h: "allowed", reset_5h: 2.hours.from_now,
        utilization_7d: 0.10, status_7d: "allowed", reset_7d: 4.days.from_now }
    )

    get inference_url

    assert_response :success
    stats = aggregate_stats_text
    assert_match(/Avg 5-Hour Utilization \(effective\) 35\.0%/, stats)
    assert_match(/None right now/, stats)
  end

  test "show counts every weekly-spent account in the explanatory line" do
    # The line claims to count accounts whose 7-day window is spent, so it must
    # include one that is also at its 5-hour cap — where the correction changes
    # nothing, but the claim still holds.
    seed_aggregate_snapshots(
      { utilization_5h: 0.29, status_5h: "allowed", reset_5h: 72.minutes.from_now,
        utilization_7d: 1.0, status_7d: "rejected", reset_7d: 1.day.from_now },
      { utilization_5h: 1.0, status_5h: "rejected", reset_5h: 1.hour.from_now,
        utilization_7d: 1.0, status_7d: "rejected", reset_7d: 2.days.from_now }
    )

    get inference_url

    assert_response :success
    assert_match(/2 accounts counted that way now/, aggregate_stats_text)
  end

  test "show leaves the 7-day aggregate untouched when the 5-hour window is spent" do
    # The correction is one-directional: a spent 5-hour window says nothing
    # about the week, so the 7-day average must not inherit it.
    seed_aggregate_snapshots(
      { utilization_5h: 1.0, status_5h: "rejected", reset_5h: 1.hour.from_now,
        utilization_7d: 0.30, status_7d: "allowed", reset_7d: 5.days.from_now },
      { utilization_5h: 1.0, status_5h: "rejected", reset_5h: 2.hours.from_now,
        utilization_7d: 0.10, status_7d: "allowed", reset_7d: 4.days.from_now }
    )

    get inference_url

    assert_response :success
    stats = aggregate_stats_text
    assert_match(/Avg 5-Hour Utilization \(effective\) 100\.0%/, stats)
    assert_match(/Avg 7-Day Utilization 20\.0%/, stats)
  end

  test "show flags a 7d-blocked account's unusable 5-hour headroom on its card" do
    accounts = seed_aggregate_snapshots(
      { utilization_5h: 0.29, status_5h: "allowed", reset_5h: 72.minutes.from_now,
        utilization_7d: 1.0, status_7d: "rejected", reset_7d: 1.day.from_now },
      { utilization_5h: 0.20, status_5h: "allowed", reset_5h: 2.hours.from_now,
        utilization_7d: 0.30, status_7d: "allowed", reset_7d: 5.days.from_now }
    )

    get inference_url

    assert_response :success
    assert_select "#account_card_#{accounts.first.id}" do
      assert_select "p", text: /Counted as 100% in the pool figure — the 7-day window is spent/
    end
    assert_select "#account_card_#{accounts.second.id}" do
      assert_select "p", text: /Counted as 100% in the pool figure/, count: 0
    end
  end

  test "show has back link to sessions index" do
    get inference_url

    assert_select "a[href=?]", root_path
  end

  test "show has Refresh All button" do
    get inference_url

    assert_response :success
    assert_select "form[action=?]", refresh_all_inference_path
  end

  test "show renders account cards with per-account refresh buttons" do
    get inference_url

    assert_response :success
    # The Inference page is scoped to the Claude Code pool; Codex accounts (a
    # different runtime in the shared table) are not rendered here.
    cards = ClaudeAccount.for_runtime(ClaudeAuthProvider::RUNTIME).order(:priority)
    assert cards.exists?
    cards.each do |account|
      assert_select "#account_card_#{account.id}"
      assert_select "form[action=?]", refresh_account_inference_path(account)
    end
    # Codex accounts must NOT appear on the Claude Inference page.
    ClaudeAccount.for_runtime(CodexAuthProvider::RUNTIME).each do |account|
      assert_select "#account_card_#{account.id}", count: 0
    end
  end

  # The spot gate card lives here, beside the windows it reads: the policy
  # form, the live reading, and one button per settable genesis kind.
  test "show renders the spot gate with its policy form and genesis controls" do
    get inference_url

    assert_response :success
    assert_select "#spot-gate"
    assert_select "h2", "Spot vs priority"
    assert_select "form[action=?]", spot_policy_path
    assert_select "input[name='app_setting[spot_reserve_five_hour_pct]']"
    assert_select "input[name='app_setting[spot_reserve_weekly_pct]']"
    assert_select "input[name='app_setting[spot_max_concurrent_sessions]']"
    assert_select "#spot-gate-status"
    assert_select "form[action=?]", reset_genesis_classes_path

    kind = SessionGenesis::SETTABLE_KINDS.first
    assert_select "#genesis-row-#{kind.key}"
    assert_select "form[action=?]",
      genesis_class_path(genesis: kind.key, priority_class: SessionGenesis::SPOT)
  end

  # The regression this whole change exists for. With the fleet ahead of the
  # pacing curve the page used to print "running spot sessions are being paused
  # too", which is false: only a spent budget ever pauses a running turn.
  test "show explains a pacing hold without claiming running sessions are being paused" do
    hold_spot_work(utilization_5h: 0.30, burn: 4.0, running: 1)
    paused_spot_session

    get inference_url

    assert_response :success
    assert_select "#spot-gate-hold-explainer" do
      assert_select "dt", text: "Why it's held:"
      assert_select "dt", text: "Held until:"
    end
    body = response.body
    assert_match(/spot budget still has \$500 left/, body)
    assert_match(/already running are not paused for this/, body)
    assert_match(/When the fleet&#39;s burn falls to or below/, body)
    refute_match(/running spot sessions are being paused too/, body)

    assert_select "#spot-paused-count", "1"
    assert_match(/Spot sessions asleep in the queue/, body)
    assert_match(/It was paused mid-run when a window&#39;s spot budget ran out/, body)
    assert_match(/The ceiling is not pausing anything right now/, body)
    # The old label read as a count of running sessions, which is what made "17"
    # look like it contradicted "Sessions running 4 of 5".
    refute_match(/Running spot sessions paused for the ceiling/, body)
  end

  test "show says the ceiling IS pausing running work when the budget is spent" do
    hold_spot_work(utilization_5h: 0.85, burn: 2.0, running: 0)

    get inference_url

    assert_response :success
    assert_match(/spot budget is spent/, response.body)
    assert_match(/No sooner than the 5-hour window&#39;s rollover/, response.body)
  end

  # Puts the pool in a state where SpotGateService holds spot work, with a
  # calibrated window so the decision is taken in dollars — the production path.
  def hold_spot_work(utilization_5h:, burn:, running:)
    ClaudeAccountQuotaSnapshot.delete_all
    HarnessModelBurnRate.delete_all
    Session.where(status: :running).update_all(status: Session.statuses[:needs_input])
    ClaudeAccount.for_runtime("claude_code").update_all(is_current: false)
    account = ClaudeAccount.create!(email: "gate-copy@example.com", runtime: "claude_code",
                                    oauth_config: { "x" => 1 }, is_current: true)
    ClaudeAccountQuotaSnapshot.create!(claude_account: account,
      utilization_5h: utilization_5h, utilization_7d: 0.05,
      reset_5h: 100.minutes.from_now, reset_7d: 2.days.from_now,
      active_session_count: 1, trigger: "usage_sample")
    QuotaCapacityEstimate.create!(window_key: QuotaCapacityEstimate::FIVE_HOUR, capacity_usd: 1000.0,
      sample_cost_usd: 500.0, sample_utilization: 0.5, observation_count: 5, computed_at: Time.current)
    HarnessModelBurnRate.create!(harness: "zimmer", model: "claude-opus-5", usd_per_minute: burn,
      sample_cost_usd: burn * 100, sample_minutes: 100.0, sample_session_count: 25,
      computed_at: Time.current)
    running.times do |i|
      Session.create!(git_root: "https://github.com/t/r.git", prompt: "running #{i}",
                      genesis: SessionGenesis::WEB_UI, status: :running, agent_runtime: "claude_code")
    end
    AppSetting.editable.update!(spot_gating_enabled: true, spot_max_concurrent_sessions: 10,
                                spot_reserve_five_hour_pct: 20, spot_reserve_weekly_pct: 20)
  end

  def held_spot_session(retry_at:)
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "held", status: :waiting,
                    genesis: SessionGenesis::GITHUB_ISSUE,
                    metadata: {
                      SpotSessionHold::HELD_AT => 11.hours.ago.utc.iso8601,
                      SpotSessionHold::HELD_REASON => "fleet_at_cap",
                      SpotSessionHold::HELD_DETAIL => "Holding spot sessions: 5 of 5 session slots taken.",
                      SpotSessionHold::HELD_RETRY_AT => retry_at.utc.iso8601,
                      SpotSessionHold::HELD_COUNT => 145,
                      SpotSessionHold::HELD_TURN => SpotSessionHold::TURN_RESUME
                    })
  end

  def paused_spot_session
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "paused", status: :waiting,
                    genesis: SessionGenesis::GITHUB_ISSUE,
                    metadata: {
                      SpotSessionPause::PAUSED_AT => 1.hour.ago.utc.iso8601,
                      SpotSessionPause::PAUSED_REASON => SpotGateService::UTILIZATION_REASON,
                      SpotSessionPause::PAUSED_DETAIL => "Holding spot sessions."
                    })
  end

  # The card reported ONE dormant population — the sessions the ceiling paused
  # mid-run — under a label that reads like every dormant spot session. Sessions
  # the gate HELD before a turn are a second, disjoint population with a
  # different resume owner, and they were invisible: on 2026-08-31 the surfaces
  # said "asleep in the spot queue: 0" while session 7507 sat held.
  test "show counts held sessions as well as paused ones" do
    hold_spot_work(utilization_5h: 0.30, burn: 4.0, running: 1)
    paused_spot_session
    held_spot_session(retry_at: 20.minutes.from_now)

    get inference_url

    assert_response :success
    assert_select "#spot-paused-count", "1"
    assert_select "#spot-held-count", "1"
    assert_select "#spot-overdue-hold-count", count: 0
    assert_match(/Spot sessions held before a turn/, response.body)
  end

  # A hold past its own re-check time is a ladder that has stopped, and until
  # SpotHoldSweepJob existed nothing surfaced it anywhere.
  test "show names held sessions whose re-check is overdue" do
    hold_spot_work(utilization_5h: 0.30, burn: 4.0, running: 1)
    held_spot_session(retry_at: 10.hours.ago)

    get inference_url

    assert_response :success
    assert_select "#spot-held-count", "1"
    assert_select "#spot-overdue-hold-count", "1"
    assert_match(/Its own re-check time has already passed/, response.body)
    assert_match(/SpotHoldSweepJob/, response.body)
  end

  # The gate reads the Claude Code quota windows, so it has nothing to say on
  # the Codex tab — the same reason the aggregate stats are Claude-only.
  test "show omits the spot gate on the Codex tab" do
    get inference_url(runtime: CodexAuthProvider::RUNTIME)

    assert_response :success
    assert_select "#spot-gate", count: 0
  end

  test "show does not make API calls" do
    QuotaCheckService.expects(:check_with_token).never

    get inference_url

    assert_response :success
  end

  test "show does NOT adopt a filesystem identity — a GET must not change which account runs" do
    # The inverse of what this test used to assert. Reconciliation on every page
    # load meant an operator refreshing /inference to WATCH an incident could
    # silently switch the pool, driven by a container-local file a container
    # replacement leaves stale. The five-minute sweep still reconciles; opening a
    # diagnostic page no longer does. See issue #618, hole 12.
    primary = claude_accounts(:primary)
    secondary = claude_accounts(:secondary)

    primary.update!(last_rotated_to_at: 1.hour.ago)
    ClaudeAccount.write_credentials_owner_marker!(primary.email)
    past = 2.hours.ago.to_time
    File.utime(past, past, ClaudeAuthProvider.credentials_owner_path)
    File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH,
      JSON.pretty_generate(secondary.oauth_config["claude_json"]))
    File.write(ClaudeAuthProvider::CREDENTIALS_JSON_PATH,
      JSON.pretty_generate(secondary.oauth_config["credentials_json"]))

    get inference_url

    assert_response :success
    assert primary.reload.is_current?, "a GET must leave the DB-current account exactly where it was"
    assert_not secondary.reload.is_current?
  end

  test "should route GET /inference to inference#show" do
    assert_routing(
      { method: :get, path: "/inference" },
      { controller: "inference", action: "show" }
    )
  end

  # ── refresh_all ────────────────────────────────────────────────────

  test "refresh_all probes each account and streams updates" do
    result = QuotaCheckService::Result.new(
      success: true,
      subscription_type: "max",
      rate_limit_tier: "default_claude_max_20x",
      email: "test@example.com",
      utilization_5h: 0.42,
      utilization_7d: 0.15,
      status_5h: "allowed",
      status_7d: "allowed",
      reset_5h: 2.hours.from_now,
      reset_7d: 3.days.from_now
    )
    QuotaCheckService.stubs(:check_with_token).returns(result)

    post refresh_all_inference_url, headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_includes response.content_type, "text/vnd.turbo-stream.html"
  end

  # The decision on the spot gate is read from the very snapshots a refresh
  # replaces, so a refresh that left it alone would show a stale reading beside
  # fresh utilization bars.
  test "refresh_all re-renders the spot gate alongside the aggregate stats" do
    post refresh_all_inference_url, headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_match(/target="aggregate_stats"/, response.body)
    assert_match(/target="spot-gate"/, response.body)
    assert_match(/Spot vs priority/, response.body)
  end

  test "refresh_account re-renders the spot gate for a Claude account" do
    account = claude_accounts(:primary)

    post refresh_account_inference_url(account), headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_match(/target="spot-gate"/, response.body)
  end

  test "refresh_all auto-heals quota_exceeded account with low utilization" do
    exceeded = claude_accounts(:exceeded)
    assert exceeded.quota_exceeded?

    exceeded.quota_snapshots.destroy_all
    exceeded.quota_snapshots.create!(
      utilization_5h: 0.0,
      utilization_7d: 0.72,
      status_5h: "allowed",
      status_7d: "allowed",
      reset_5h: 3.hours.from_now,
      reset_7d: 5.days.from_now,
      trigger: "rotation"
    )

    QuotaCheckService.stubs(:check_with_token).returns(
      QuotaCheckService::Result.new(success: false, error_message: "test")
    )

    post refresh_all_inference_url, headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert exceeded.reload.active?, "Account should be auto-healed to active"
  end

  test "should route POST /inference/refresh_all" do
    assert_routing(
      { method: :post, path: "/inference/refresh_all" },
      { controller: "inference", action: "refresh_all" }
    )
  end

  # ── refresh_account ────────────────────────────────────────────────

  test "refresh_account probes single account and returns turbo stream" do
    account = claude_accounts(:primary)
    result = QuotaCheckService::Result.new(
      success: true,
      subscription_type: "max",
      rate_limit_tier: "default_claude_max_20x",
      email: account.email,
      utilization_5h: 0.55,
      utilization_7d: 0.30,
      status_5h: "allowed",
      status_7d: "allowed",
      reset_5h: 2.hours.from_now,
      reset_7d: 3.days.from_now
    )
    QuotaCheckService.stubs(:check_with_token).returns(result)

    post refresh_account_inference_url(account), headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_includes response.content_type, "text/vnd.turbo-stream.html"
  end

  test "should route POST /inference/refresh_account/:id" do
    assert_routing(
      { method: :post, path: "/inference/refresh_account/1" },
      { controller: "inference", action: "refresh_account", id: "1" }
    )
  end

  # ── switch_account ─────────────────────────────────────────────────

  test "switch_account switches to account with valid config" do
    secondary = claude_accounts(:secondary)

    post switch_account_path(secondary)

    assert_redirected_to inference_path(runtime: "claude_code")
    assert secondary.reload.is_current?
    assert_not claude_accounts(:primary).reload.is_current?
    assert_equal "Switched to sam@tadasant.com", flash[:notice]
  end

  test "switch_account creates a manual rotation event" do
    secondary = claude_accounts(:secondary)

    assert_difference "AccountRotationEvent.count", 1 do
      post switch_account_path(secondary)
    end

    event = AccountRotationEvent.last
    assert_equal claude_accounts(:primary), event.rotated_from
    assert_equal secondary, event.rotated_to
    assert_equal "manual_switch", event.reason
    assert_equal "manual", event.source
  end

  test "switch_account writes the new account's config to the filesystem" do
    # The bug: previously, manual switch only updated the DB and skipped the
    # filesystem write that auto-rotation performs. Subsequent session spawns
    # would still use the previous account's credentials until reconciliation
    # eventually caught up. The fix routes both paths through
    # AccountRotationService#activate!.
    secondary = claude_accounts(:secondary)

    post switch_account_path(secondary)

    assert_redirected_to inference_path(runtime: "claude_code")
    assert File.exist?(ClaudeAuthProvider::CLAUDE_JSON_PATH),
      "switch_account must write ~/.claude.json"
    assert File.exist?(ClaudeAuthProvider::CREDENTIALS_JSON_PATH),
      "switch_account must write ~/.claude/.credentials.json"

    claude_json = JSON.parse(File.read(ClaudeAuthProvider::CLAUDE_JSON_PATH))
    assert_equal secondary.email, claude_json["oauthAccount"],
      "~/.claude.json must reflect the newly-current account's identity"
  end

  test "switch_account takes a quota snapshot for the newly-current account" do
    secondary = claude_accounts(:secondary)

    initial_count = secondary.quota_snapshots.count
    post switch_account_path(secondary)

    assert_redirected_to inference_path(runtime: "claude_code")
    assert_equal initial_count + 1, secondary.quota_snapshots.count,
      "switch_account must take a snapshot for the newly-current account"
    assert_equal "manual_switch", secondary.quota_snapshots.order(created_at: :desc).first.trigger
  end

  test "switch_account rejects account without oauth tokens" do
    unconfigured = claude_accounts(:unconfigured)

    post switch_account_path(unconfigured)

    assert_redirected_to inference_path(runtime: "claude_code")
    assert_match "no credentials stored", flash[:alert]
    assert claude_accounts(:primary).reload.is_current?
    assert_not unconfigured.reload.is_current?
  end

  # ── issue #618: holes 3, 4 and 12 ──────────────────────────────────

  test "the current account offers Re-activate, so the one live credential set can be rewritten from the UI" do
    get inference_path
    assert_response :success
    assert_select "form[action=?]", switch_account_path(claude_accounts(:primary)) do
      assert_select "button", text: "Re-activate"
    end
  end

  test "re-activating the current account rewrites its credentials without recording a rotation" do
    primary = claude_accounts(:primary)

    assert_no_difference "AccountRotationEvent.count" do
      post switch_account_path(primary)
    end

    assert_redirected_to inference_path(runtime: "claude_code")
    assert_match "Re-activated", flash[:notice]
    assert primary.reload.is_current?
    assert File.exist?(ClaudeAuthProvider::CREDENTIALS_JSON_PATH),
      "re-activation must reach the filesystem — that is the whole point of the control"
  end

  test "switch_account admits an account on a working access token without spending its refresh token" do
    secondary = claude_accounts(:secondary)

    # Any refresh attempt would be a bug: the access token already answered the
    # question, and refresh tokens are single-use.
    ClaudeAccount.any_instance.expects(:refresh_token!).never

    post switch_account_path(secondary)

    assert_redirected_to inference_path(runtime: "claude_code")
    assert secondary.reload.is_current?
  end

  # Issue #618's acceptance criterion, stated as a test: with the DB as the sole
  # owner there is no second store to disagree with, so nothing on this page may
  # ask an operator to reconcile, adopt, sync, or choose between stores.
  test "the page offers no affordance to reconcile between credential stores" do
    AppSetting.stubs(:session_scoped_credentials_enabled?).returns(true)

    get inference_path

    assert_response :success
    assert_no_match(/Sync from filesystem/i, response.body)
    assert_no_match(/Filesystem identity mismatch/i, response.body)
    assert_no_match(/adopt the filesystem identity/i, response.body)
  end

  # The same, with the setting off — the reconciliation surface is gone in both
  # worlds, because the rollback restores the credential mechanism, not the UI.
  test "the reconciliation surface is gone with session-scoped credentials off too" do
    AppSetting.stubs(:session_scoped_credentials_enabled?).returns(false)

    get inference_path

    assert_response :success
    assert_no_match(/Sync from filesystem/i, response.body)
    assert_no_match(/Filesystem identity mismatch/i, response.body)
  end

  # No copy on this page may tell an operator to open a shell on the worker.
  # Production invariant 11: Zimmer is operated without box access.
  test "the page never instructs a production shell command" do
    get inference_path

    assert_response :success
    assert_no_match(%r{bin/rails}, response.body)
  end

  test "an account card offers exactly Authenticate and Switch under session-scoped credentials" do
    primary = claude_accounts(:primary)
    primary.update!(is_current: true)
    AppSetting.stubs(:session_scoped_credentials_enabled?).returns(true)

    get inference_path

    assert_response :success
    # The current account's "Re-activate" only ever re-wrote the shared file.
    # With no file to re-write it would be a control that does nothing.
    assert_no_match(/Re-activate/, response.body)
    assert_match(/Authenticate/, response.body)
  end

  test "Re-activate survives with the setting off, because the file it repairs still exists" do
    primary = claude_accounts(:primary)
    primary.update!(is_current: true)
    AppSetting.stubs(:session_scoped_credentials_enabled?).returns(false)

    get inference_path

    assert_response :success
    assert_match(/Re-activate/, response.body)
  end

  # A GET on a diagnostic page must not change which account production runs
  # under (#618, hole 12). Claude no longer implements the reconciliation hook at
  # all, so this asserts the stronger thing: the page writes no account state.
  test "loading /inference does not change which account is current" do
    primary = claude_accounts(:primary)
    primary.update!(is_current: true)
    secondary = claude_accounts(:secondary)
    secondary.update!(is_current: false)

    get inference_path

    assert_response :success
    assert primary.reload.is_current?
    assert_not secondary.reload.is_current?
  end

  test "should route POST /inference/switch_account/:id" do
    assert_routing(
      { method: :post, path: "/inference/switch_account/1" },
      { controller: "inference", action: "switch_account", id: "1" }
    )
  end

  test "switch_account refreshes expired tokens before switching" do
    secondary = claude_accounts(:secondary)
    config = secondary.oauth_config.deep_dup
    config["credentials_json"]["claudeAiOauth"]["expiresAt"] = 1000000000000
    secondary.update!(oauth_config: config)

    successful_response = Net::HTTPSuccess.new("1.1", "200", "OK")
    successful_response.stubs(:code).returns("200")
    successful_response.stubs(:body).returns({
      access_token: "refreshed-token",
      refresh_token: "refreshed-refresh",
      expires_in: 3600
    }.to_json)

    Net::HTTP.any_instance.stubs(:request).returns(successful_response)

    post switch_account_path(secondary)

    assert_redirected_to inference_path(runtime: "claude_code")
    assert_equal "Switched to sam@tadasant.com", flash[:notice]
    secondary.reload
    assert secondary.is_current?
    assert_equal "refreshed-token", secondary.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
  end

  test "switch_account rejects account when token refresh fails" do
    secondary = claude_accounts(:secondary)

    # The admission check now asks the cheap question first: does Anthropic still
    # honour this account's stored ACCESS token? A dead account fails both probes,
    # so make the access-token probe fail too — otherwise the setup's blanket
    # success stub would answer "this account works right now", which for a real
    # dead credential it would not. See issue #618, hole 4.
    QuotaCheckService.stubs(:check_with_token).returns(
      QuotaCheckService::Result.new(success: false, error_message: "Unauthorized", unreachable: false)
    )

    failed_response = Net::HTTPUnauthorized.new("1.1", "401", "Unauthorized")
    failed_response.stubs(:code).returns("401")
    failed_response.stubs(:body).returns({ error: "invalid_grant" }.to_json)

    Net::HTTP.any_instance.stubs(:request).returns(failed_response)

    post switch_account_path(secondary)

    assert_redirected_to inference_path(runtime: "claude_code")
    assert_match "token validation failed", flash[:alert]
    assert claude_accounts(:primary).reload.is_current?
  end

  test "switch_account validates tokens via OAuth probe even when expiresAt looks fresh by date" do
    # Bug fix: secondary has fixture sentinel expiresAt: 9999999999999 (year 2286)
    # but a refresh_token that Anthropic rejects. Without the probe, the date
    # check would skip validation and switch to a bogus account, eventually
    # writing garbage to ~/.claude/.credentials.json on next session.
    secondary = claude_accounts(:secondary)

    # The admission check now asks the cheap question first: does Anthropic still
    # honour this account's stored ACCESS token? A dead account fails both probes,
    # so make the access-token probe fail too — otherwise the setup's blanket
    # success stub would answer "this account works right now", which for a real
    # dead credential it would not. See issue #618, hole 4.
    QuotaCheckService.stubs(:check_with_token).returns(
      QuotaCheckService::Result.new(success: false, error_message: "Unauthorized", unreachable: false)
    )

    failed_response = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
    failed_response.stubs(:code).returns("400")
    failed_response.stubs(:body).returns({ error: "invalid_grant" }.to_json)

    Net::HTTP.any_instance.stubs(:request).returns(failed_response)

    post switch_account_path(secondary)

    assert_redirected_to inference_path(runtime: "claude_code")
    # The probe rejected the stored value without proving the credential is dead,
    # so the account is still active and the message says so rather than sending
    # the human off to re-authenticate something that probably works (#530).
    assert_match "rejected as out of date", flash[:alert]
    assert_not secondary.reload.is_current?, "Switch must not succeed when probe rejects the tokens"
    assert claude_accounts(:primary).reload.is_current?
  end

  test "switch_account rejects account without refresh token" do
    secondary = claude_accounts(:secondary)
    config = secondary.oauth_config.deep_dup
    config["credentials_json"]["claudeAiOauth"].delete("refreshToken")
    secondary.update!(oauth_config: config)

    post switch_account_path(secondary)

    assert_redirected_to inference_path(runtime: "claude_code")
    assert_match "no refresh token", flash[:alert]
    assert claude_accounts(:primary).reload.is_current?
  end

  # ── runtime sub-tabs ───────────────────────────────────────────────

  test "show renders a sub-tab link for each runtime" do
    get inference_url

    assert_response :success
    assert_select "a[href=?]", inference_path(runtime: "claude_code"), text: "Claude Code"
    assert_select "a[href=?]", inference_path(runtime: "codex"), text: "Codex"
  end

  test "show defaults to the Claude Code runtime" do
    get inference_url

    assert_response :success
    ClaudeAccount.for_runtime("claude_code").each do |account|
      assert_select "#account_card_#{account.id}"
    end
    ClaudeAccount.for_runtime("codex").each do |account|
      assert_select "#account_card_#{account.id}", count: 0
    end
  end

  test "show with runtime=codex renders only codex accounts" do
    get inference_url(runtime: "codex")

    assert_response :success
    ClaudeAccount.for_runtime("codex").each do |account|
      assert_select "#account_card_#{account.id}"
    end
    ClaudeAccount.for_runtime("claude_code").each do |account|
      assert_select "#account_card_#{account.id}", count: 0
    end
  end

  test "show with an unknown runtime falls back to Claude Code" do
    get inference_url(runtime: "bogus")

    assert_response :success
    assert_select "#account_card_#{claude_accounts(:primary).id}"
  end

  test "show codex tab does not render the Claude-only Refresh All button" do
    get inference_url(runtime: "codex")

    assert_response :success
    assert_select "form[action=?]", refresh_all_inference_path, count: 0
  end

  test "show codex card body shows auth note, not the Claude refresh-button prompt" do
    get inference_url(runtime: "codex")

    assert_response :success
    # Codex accounts have no quota probe and no per-card refresh button, so the
    # Claude-only "Click the refresh button to fetch live data" prompt must not
    # appear — it would point at an affordance that does not exist on this tab.
    assert_select "body" do
      assert_select "*", text: /Click the refresh button/, count: 0
    end
    # API-key codex accounts explain the static auth; OAuth codex accounts note
    # OAuth. The fixture pool has both, so both notes should render.
    assert_match "no usage quota tracked", response.body
    assert_match "stored OpenAI API key", response.body
  end

  # ── add_account ────────────────────────────────────────────────────

  test "add_account creates an empty Claude OAuth account row" do
    assert_difference "ClaudeAccount.count", 1 do
      post add_account_inference_path, params: { runtime: "claude_code", email: "new-claude@example.com", priority: 7 }
    end

    account = ClaudeAccount.find_by(email: "new-claude@example.com")
    assert_equal "claude_code", account.runtime
    assert_equal 7, account.priority
    assert_not account.has_valid_config?, "OAuth account is created without credentials"
    assert_equal "needs_reauth", account.status,
      "a credential-less account must not be seeded as :active — it isn't servable and shouldn't wear an Active badge"
    assert_redirected_to inference_path(runtime: "claude_code")
    assert_match "Authenticate it", flash[:notice]
  end

  test "add_account with a codex api key creates a usable account" do
    assert_difference "ClaudeAccount.count", 1 do
      post add_account_inference_path, params: { runtime: "codex", email: "new-codex@example.com", api_key: "sk-codex-123" }
    end

    account = ClaudeAccount.find_by(email: "new-codex@example.com")
    assert_equal "codex", account.runtime
    assert_equal "sk-codex-123", account.oauth_config["api_key"]
    assert account.has_valid_config?, "API-key account is usable immediately"
    assert_equal "active", account.status, "a config-carrying account stays :active on create"
    assert_redirected_to inference_path(runtime: "codex")
  end

  test "add_account rejects a blank email" do
    assert_no_difference "ClaudeAccount.count" do
      post add_account_inference_path, params: { runtime: "claude_code", email: "  " }
    end

    assert_redirected_to inference_path(runtime: "claude_code")
    assert_match "Email is required", flash[:alert]
  end

  test "add_account rejects a duplicate email in the same runtime" do
    assert_no_difference "ClaudeAccount.count" do
      post add_account_inference_path, params: { runtime: "claude_code", email: claude_accounts(:primary).email }
    end

    assert_match "already exists", flash[:alert]
  end

  test "add_account allows the same email on a different runtime" do
    # claude_accounts(:primary) is a claude_code account; adding a codex account
    # for the same email must succeed because email uniqueness is per-runtime.
    email = claude_accounts(:primary).email

    assert_difference "ClaudeAccount.count", 1 do
      post add_account_inference_path, params: { runtime: "codex", email: email, api_key: "sk-codex-coexist" }
    end

    codex_account = ClaudeAccount.for_runtime("codex").find_by(email: email)
    assert codex_account, "expected a codex account to be created for #{email}"
    assert_equal "sk-codex-coexist", codex_account.oauth_config["api_key"]
    assert_redirected_to inference_path(runtime: "codex")
  end

  # ── destroy_account ────────────────────────────────────────────────

  test "destroy_account deletes a non-current account" do
    secondary = claude_accounts(:secondary)

    assert_difference "ClaudeAccount.count", -1 do
      delete destroy_account_inference_path(secondary)
    end

    assert_nil ClaudeAccount.find_by(id: secondary.id)
    assert_redirected_to inference_path(runtime: "claude_code")
    assert_match "Deleted #{secondary.email}", flash[:notice]
  end

  test "destroy_account deleting the current account activates the next available one" do
    primary = claude_accounts(:primary)
    assert primary.is_current?

    assert_difference "AccountRotationEvent.count", 1 do
      delete destroy_account_inference_path(primary)
    end

    assert_nil ClaudeAccount.find_by(id: primary.id)
    new_current = ClaudeAccount.current_account("claude_code")
    assert_not_nil new_current, "a replacement account should be activated"
    assert_not_equal primary.id, new_current.id

    event = AccountRotationEvent.last
    assert_nil event.rotated_from
    assert_equal new_current, event.rotated_to
    assert_equal "deleted_current_account", event.reason
    assert_match "Activated #{new_current.email}", flash[:notice]
  end

  test "destroy_account deleting the only account leaves the runtime with no current" do
    ClaudeAccount.for_runtime("codex").where.not(id: claude_accounts(:codex_primary).id).delete_all
    codex_primary = claude_accounts(:codex_primary)
    assert codex_primary.is_current?

    delete destroy_account_inference_path(codex_primary)

    assert_nil ClaudeAccount.current_account("codex")
    assert_redirected_to inference_path(runtime: "codex")
    assert_match "no active account", flash[:notice]
  end

  test "destroy_account preserves the account's quota snapshots, login attempts, and rotation events" do
    # Regression guard for #241: "delete it and re-authenticate" used to destroy
    # the only evidence of whether the account had ever been healthy.
    secondary = claude_accounts(:secondary)
    email = secondary.email
    snapshot = secondary.quota_snapshots.create!(trigger: "page_view", utilization_7d: 0.4)
    attempt = secondary.runtime_login_attempts.create!(runtime: "claude_code", status: "succeeded")
    event = AccountRotationEvent.create!(rotated_to: secondary, reason: "quota_exceeded", source: "automatic")

    delete destroy_account_inference_path(secondary)

    assert_equal email, snapshot.reload.account_email
    assert_nil snapshot.claude_account_id
    assert_equal email, attempt.reload.account_email
    assert_nil attempt.claude_account_id
    assert_equal email, event.reload.to_email
    assert_nil event.rotated_to_id
  end

  test "destroy_account records the deleted account as the source of the replacement rotation" do
    primary = claude_accounts(:primary)
    email = primary.email

    delete destroy_account_inference_path(primary)

    event = AccountRotationEvent.last
    assert_equal "deleted_current_account", event.reason
    assert_equal email, event.from_email
    assert event.from_deleted?, "the pool moved off a deleted account, not off nothing"
  end

  test "the rotation log renders events whose accounts have been deleted" do
    secondary = claude_accounts(:secondary)
    AccountRotationEvent.create!(
      rotated_from: claude_accounts(:primary),
      rotated_to: secondary,
      reason: "deleted_account_event",
      source: "automatic"
    )
    secondary.destroy!

    get inference_url(runtime: "claude_code")

    assert_response :success
    assert_select "td", text: "deleted_account_event"
    assert_select "td", text: /#{Regexp.escape(secondary.email)}/
    assert_select "span", text: "deleted"
  end

  test "should route DELETE /inference/account/:id" do
    assert_routing(
      { method: :delete, path: "/inference/account/1" },
      { controller: "inference", action: "destroy_account", id: "1" }
    )
  end

  test "should route POST /inference/add_account" do
    assert_routing(
      { method: :post, path: "/inference/add_account" },
      { controller: "inference", action: "add_account" }
    )
  end

  # ── switch_account (codex) ─────────────────────────────────────────

  test "switch_account switches to a codex api-key account without a refresh probe" do
    api_key_account = claude_accounts(:codex_api_key)

    assert_difference "AccountRotationEvent.count", 1 do
      post switch_account_path(api_key_account)
    end

    assert api_key_account.reload.is_current?
    assert_not claude_accounts(:codex_primary).reload.is_current?
    assert_redirected_to inference_path(runtime: "codex")

    event = AccountRotationEvent.last
    assert_equal api_key_account, event.rotated_to
    assert_equal "manual_switch", event.reason
  end

  test "switch_account switches to a codex OAuth account after a successful refresh probe" do
    # codex_secondary holds OAuth tokens (not an api-key account), so it must
    # pass the refresh probe before activation — the dual-runtime equivalent of
    # the Claude OAuth switch path. Stub the probe so no real token endpoint is hit.
    ClaudeAccount.any_instance.stubs(:refresh_token!).returns(true)
    oauth_account = claude_accounts(:codex_secondary)

    assert_difference "AccountRotationEvent.count", 1 do
      post switch_account_path(oauth_account)
    end

    assert oauth_account.reload.is_current?
    assert_not claude_accounts(:codex_primary).reload.is_current?
    assert_redirected_to inference_path(runtime: "codex")
    assert File.exist?(CodexAuthProvider::AUTH_JSON_PATH),
      "codex switch must write ~/.codex/auth.json"

    event = AccountRotationEvent.last
    assert_equal oauth_account, event.rotated_to
    assert_equal "manual_switch", event.reason
  end

  test "switch_account rejects a codex OAuth account when the refresh probe fails" do
    ClaudeAccount.any_instance.stubs(:refresh_token!).returns(false)
    oauth_account = claude_accounts(:codex_secondary)

    post switch_account_path(oauth_account)

    assert_redirected_to inference_path(runtime: "codex")
    assert_match "rejected as out of date", flash[:alert]
    assert_not oauth_account.reload.is_current?
    assert claude_accounts(:codex_primary).reload.is_current?
  end

  test "destroy_account deleting the current codex account activates a codex OAuth fallback" do
    # Remove the api-key account so the only remaining candidate is OAuth, forcing
    # the safe-delete fallback through the refresh-probe branch of
    # next_activatable_account. Stub the probe so no real token endpoint is hit.
    ClaudeAccount.any_instance.stubs(:refresh_token!).returns(true)
    claude_accounts(:codex_api_key).destroy!
    codex_primary = claude_accounts(:codex_primary)
    assert codex_primary.is_current?

    assert_difference "AccountRotationEvent.count", 1 do
      delete destroy_account_inference_path(codex_primary)
    end

    new_current = ClaudeAccount.current_account("codex")
    assert_equal claude_accounts(:codex_secondary), new_current
    assert_redirected_to inference_path(runtime: "codex")

    event = AccountRotationEvent.last
    assert_equal "deleted_current_account", event.reason
    assert_equal new_current, event.rotated_to
  end

  # ── rotation log (runtime isolation) ───────────────────────────────

  test "rotation log shows a runtime's own events even when the other runtime's are more recent" do
    # Regression guard: the runtime filter must be applied in SQL before the
    # LIMIT, otherwise a flood of recent Claude events could crowd Codex events
    # off the page and the Codex tab's rotation log would render empty.
    AccountRotationEvent.create!(rotated_to: claude_accounts(:codex_secondary), reason: "older_codex_event", source: "manual", created_at: 2.hours.ago)
    60.times do |i|
      AccountRotationEvent.create!(rotated_to: claude_accounts(:secondary), reason: "claude_event_#{i}", source: "manual", created_at: (i + 1).minutes.ago)
    end

    get inference_url(runtime: "codex")

    assert_response :success
    assert_select "td", text: "older_codex_event"
    assert_select "td", text: "claude_event_0", count: 0
  end

  # ── add_account (runtime guard) ────────────────────────────────────

  test "add_account ignores an api_key passed for the Claude Code runtime" do
    post add_account_inference_path, params: { runtime: "claude_code", email: "claude-no-key@example.com", api_key: "sk-should-be-ignored" }

    account = ClaudeAccount.find_by(email: "claude-no-key@example.com")
    assert_equal "claude_code", account.runtime
    assert_equal({}, account.oauth_config, "api_key must not be stored for Claude Code accounts")
    assert_not account.has_valid_config?
  end

  # ── start_login / login_status / submit_login_code / cancel_login ──

  test "start_login creates an attempt, enqueues the job, and renders the panel" do
    account = claude_accounts(:unconfigured)
    RuntimeLoginJob.expects(:perform_later).once

    assert_difference -> { account.runtime_login_attempts.count }, 1 do
      post start_login_inference_path(account), headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :success
    assert_includes response.content_type, "text/vnd.turbo-stream.html"
    assert_select "turbo-stream[target=?]", "login_panel_#{account.id}"

    attempt = account.runtime_login_attempts.order(:created_at).last
    assert_equal "starting", attempt.status
    assert_equal account.runtime, attempt.runtime
  end

  test "start_login supersedes any in-flight attempt for the account" do
    account = claude_accounts(:unconfigured)
    stale = account.runtime_login_attempts.create!(runtime: account.runtime, status: "awaiting_user")
    RuntimeLoginJob.expects(:perform_later).once

    post start_login_inference_path(account), headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "canceled", stale.reload.status, "the prior live attempt must be superseded"
    assert_equal 1, account.runtime_login_attempts.active.count
  end

  test "start_login rejects a codex api-key account" do
    account = claude_accounts(:codex_api_key)
    RuntimeLoginJob.expects(:perform_later).never

    assert_no_difference -> { account.runtime_login_attempts.count } do
      post start_login_inference_path(account), headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :success
    assert_match "don't use the login flow", flash[:alert]
  end

  test "login_status renders the login panel while the attempt is in flight" do
    account = claude_accounts(:unconfigured)
    attempt = account.runtime_login_attempts.create!(runtime: account.runtime, status: "awaiting_user")

    get login_status_inference_path(attempt), headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_select "turbo-stream[target=?]", "login_panel_#{account.id}"
  end

  test "login_status replaces the whole account card once the attempt succeeds" do
    account = claude_accounts(:unconfigured)
    attempt = account.runtime_login_attempts.create!(runtime: account.runtime, status: "succeeded")

    get login_status_inference_path(attempt), headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_select "turbo-stream[target=?]", "account_card_#{account.id}"
  end

  # Regression for the production hang: the Authenticate panel sat on "Finishing
  # sign-in and capturing credentials…" indefinitely. The attempt was left in
  # `completing` by a RuntimeLoginJob whose worker died without running Ruby, so
  # no ensure/rescue ever marked the row terminal — and with its verification
  # window still open, neither the reaper nor login_status's window check would
  # touch it. The poller therefore re-rendered the same spinner forever.
  #
  # A stale heartbeat is the signal that nothing is driving the login any more,
  # and it must resolve the attempt on the very next poll.
  test "login_status fails an attempt stuck in completing whose worker stopped heartbeating" do
    account = claude_accounts(:unconfigured)
    attempt = account.runtime_login_attempts.create!(
      runtime: account.runtime, status: "completing",
      expires_at: 10.minutes.from_now, pasted_code: "secret-auth-code",
      heartbeat_at: (RuntimeLoginAttempt::HEARTBEAT_TIMEOUT + 1.minute).ago
    )

    get login_status_inference_path(attempt), headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    attempt.reload
    assert_equal "failed", attempt.status, "a stranded attempt must reach a terminal state"
    assert_match(/stopped responding/, attempt.error_message)
    assert_nil attempt.pasted_code

    # And the panel must now carry the reason instead of the spinner, with no
    # poller left running.
    assert_select "turbo-stream[target=?]", "login_panel_#{account.id}" do
      assert_select "div[data-controller=?]", "inference-login-poller", count: 0
      assert_no_match(/Finishing sign-in/, response.body)
      assert_match(/stopped responding/, response.body)
    end
  end

  test "login_status answers a poll for an attempt whose row is gone instead of 404ing" do
    # A 404 here reads to the Stimulus poller as a transient network error, so it
    # silently gives up a few ticks later and freezes the panel on its last frame.
    account = claude_accounts(:unconfigured)
    attempt = account.runtime_login_attempts.create!(runtime: account.runtime, status: "completing")
    attempt_id = attempt.id
    attempt.destroy!

    get login_status_inference_path(attempt_id), headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_select "turbo-stream[target=?]", "login_attempt_#{attempt_id}" do
      assert_select "div[data-controller=?]", "inference-login-poller", count: 0
      assert_match(/no longer being tracked/, response.body)
    end
  end

  test "login_status answers a poll for an attempt whose account was deleted" do
    # #241: the attempt row now survives the account it was made against, so this
    # poll finds a row with no account to render a panel for. It must resolve the
    # poller rather than raising on nil.
    account = ClaudeAccount.create!(email: "detached-login@example.com", runtime: "claude_code", priority: 99)
    attempt = account.runtime_login_attempts.create!(runtime: account.runtime, status: "completing")
    account.destroy!

    get login_status_inference_path(attempt), headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_select "turbo-stream[target=?]", "login_attempt_#{attempt.id}"
    assert_match(/no longer being tracked/, response.body)
  end

  test "cancel_login resolves an attempt whose account was deleted without overwriting its outcome" do
    account = ClaudeAccount.create!(email: "detached-cancel@example.com", runtime: "claude_code", priority: 99)
    attempt = account.runtime_login_attempts.create!(
      runtime: account.runtime, status: "failed",
      error_message: "The account this login was for was deleted before the login completed."
    )
    account.destroy!

    post cancel_login_inference_path(attempt), headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_select "turbo-stream[target=?]", "login_attempt_#{attempt.id}"
    attempt.reload
    assert_equal "failed", attempt.status
    assert_match(/deleted/, attempt.error_message, "the reason the login died must survive a stray cancel")
  end

  # The pasted code is single-use and credential-adjacent. It used to be left for
  # RuntimeLoginJob to clear, but the whole premise of the orphan handling is that
  # the job may not be running, so every terminal write drops it itself.
  test "cancel_login drops the pasted authorization code" do
    account = claude_accounts(:unconfigured)
    attempt = account.runtime_login_attempts.create!(
      runtime: account.runtime, status: "awaiting_code", pasted_code: "secret-auth-code"
    )

    post cancel_login_inference_path(attempt), headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    attempt.reload
    assert_equal "canceled", attempt.status
    assert_nil attempt.pasted_code
  end

  test "start_login drops the pasted code of the attempt it supersedes" do
    account = claude_accounts(:unconfigured)
    stale = account.runtime_login_attempts.create!(
      runtime: account.runtime, status: "awaiting_code", pasted_code: "secret-auth-code"
    )
    RuntimeLoginJob.expects(:perform_later).once

    post start_login_inference_path(account), headers: { "Accept" => "text/vnd.turbo-stream.html" }

    stale.reload
    assert_equal "canceled", stale.status
    assert_nil stale.pasted_code
  end

  test "login_status lazily expires an attempt past its window" do
    account = claude_accounts(:unconfigured)
    attempt = account.runtime_login_attempts.create!(runtime: account.runtime, status: "awaiting_user")
    attempt.update_column(:expires_at, 1.minute.ago)

    get login_status_inference_path(attempt), headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "expired", attempt.reload.status
  end

  test "login_status keeps the verification URL visible while awaiting the pasted code" do
    # Regression: the awaiting_code state used to render only the paste-code form,
    # leaving the user asked for a code with no way to obtain it. The Claude
    # --claudeai flow prints the URL and blocks on its paste prompt nearly at
    # once, so the awaiting_user state that first surfaced the URL is usually
    # skipped between 2s polls — the URL must stay visible in awaiting_code.
    account = claude_accounts(:unconfigured)
    url = "https://claude.com/cai/oauth/authorize?code=abc123"
    attempt = account.runtime_login_attempts.create!(
      runtime: account.runtime,
      status: "awaiting_code",
      verification_url: url
    )

    get login_status_inference_path(attempt), headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_includes response.body, url, "awaiting_code must render the OAuth authorization URL"
    assert_includes response.body, submit_login_code_inference_path(attempt),
      "the paste-code form must still render alongside the URL"
  end

  test "submit_login_code stores the pasted code on a live attempt" do
    account = claude_accounts(:unconfigured)
    attempt = account.runtime_login_attempts.create!(runtime: account.runtime, status: "awaiting_code")

    post submit_login_code_inference_path(attempt),
      params: { code: "  auth-code-123  " },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "auth-code-123", attempt.reload.pasted_code
  end

  test "submit_login_code ignores a blank code" do
    account = claude_accounts(:unconfigured)
    attempt = account.runtime_login_attempts.create!(runtime: account.runtime, status: "awaiting_code")

    post submit_login_code_inference_path(attempt),
      params: { code: "   " },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_nil attempt.reload.pasted_code
  end

  test "cancel_login marks a live attempt canceled" do
    account = claude_accounts(:unconfigured)
    attempt = account.runtime_login_attempts.create!(runtime: account.runtime, status: "awaiting_user")

    post cancel_login_inference_path(attempt), headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "canceled", attempt.reload.status
  end

  test "cancel_login leaves an already-terminal attempt untouched" do
    account = claude_accounts(:unconfigured)
    attempt = account.runtime_login_attempts.create!(runtime: account.runtime, status: "succeeded")

    post cancel_login_inference_path(attempt), headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "succeeded", attempt.reload.status
  end

  test "should route POST /inference/accounts/:id/login" do
    assert_routing(
      { method: :post, path: "/inference/accounts/1/login" },
      { controller: "inference", action: "start_login", id: "1" }
    )
  end

  test "should route GET /inference/login/:attempt_id" do
    assert_routing(
      { method: :get, path: "/inference/login/5" },
      { controller: "inference", action: "login_status", attempt_id: "5" }
    )
  end

  private

  # Give the pool exactly two accounts with quota data, so the aggregate
  # averages are arithmetic the test can state exactly. Returns the accounts in
  # the order their snapshots were given.
  def seed_aggregate_snapshots(*snapshot_attributes)
    ClaudeAccountQuotaSnapshot.delete_all

    accounts = [ claude_accounts(:primary), claude_accounts(:secondary) ]
    accounts.zip(snapshot_attributes).each do |account, attributes|
      ClaudeAccountQuotaSnapshot.create!(
        claude_account: account, trigger: "page_view", **attributes
      )
    end
    accounts
  end

  # The :exceeded fixture as production found it: still carrying the sticky
  # column, with a fresh reading that says both its windows have headroom.
  def exceeded_account_with_cleared_windows
    account = claude_accounts(:exceeded)
    ClaudeAccountQuotaSnapshot.delete_all
    ClaudeAccountQuotaSnapshot.create!(
      claude_account: account, trigger: "scheduled",
      utilization_5h: 0.35, status_5h: "allowed", reset_5h: 26.minutes.from_now,
      utilization_7d: 0.12, status_7d: "allowed", reset_7d: 6.days.from_now
    )
    account
  end

  # The account-level status badge on a card — the first pill after the email
  # that is not the "Current" marker.
  def account_badge_text(account)
    css_select("#account_card_#{account.id} span.rounded-full")
      .map { |el| el.text.strip }
      .find { |text| text != "Current" }
  end

  # The pool's reset notes render UTC on the server, whatever the reader's clock
  # rewrites them to.
  def utc_reset_text(time)
    time.utc.strftime("%b %-d, %H:%M UTC")
  end

  def aggregate_stats_text
    css_select("#aggregate_stats").first.text.squish
  end

  # --- Quotas -> Inference -------------------------------------------------
  #
  # The old address is not a deprecation window. It is in seeded trigger
  # prompts, alert bodies and Slack history that this repo has already shipped,
  # so it has to keep landing on the page.

  test "the old /quotas address still reaches the page" do
    get "/quotas"

    assert_redirected_to "/inference"
    follow_redirect!
    assert_response :success
    assert_select "h1", "Inference"
  end

  test "the old address carries its tab across" do
    get "/quotas?runtime=codex"

    assert_redirected_to "/inference?runtime=codex"
    follow_redirect!
    assert_select "a[href=?]", inference_path(runtime: "codex"), text: "Codex"
  end

  test "the old anchor-bearing links people hold still work" do
    # `?runtime=` is what rides along; the fragment never reaches the server, so
    # the browser reapplies it to the redirect target on its own.
    get "/quotas", params: { runtime: "claude_code" }

    assert_redirected_to "/inference?runtime=claude_code"
  end

  # --- The Pi tab -----------------------------------------------------------

  test "Pi is a tab beside Claude Code and Codex" do
    get inference_url

    assert_select "a[href=?]", inference_path(runtime: "claude_code"), text: "Claude Code"
    assert_select "a[href=?]", inference_path(runtime: "codex"), text: "Codex"
    assert_select "a[href=?]", inference_path(runtime: "pi"), text: "Pi"
  end

  test "the Pi tab renders with the key absent" do
    ManagedSecret.stub(:openrouter_key, unwritable_secret) do
      get inference_url(runtime: "pi")
    end

    assert_response :success
    assert_select "[data-openrouter-key-state=unset]"
    assert_select "[data-openrouter-key-state=set]", count: 0
    assert_match "OPENROUTER_API_KEY", response.body
  end

  test "the Pi tab renders with the key set, showing a digest and never the key" do
    ManagedSecret.stub(:openrouter_key, writable_secret(value: PI_KEY)) do
      get inference_url(runtime: "pi")
    end

    assert_response :success
    assert_select "[data-openrouter-key-state=set]"
    assert_select "[data-openrouter-fingerprint]", text: Digest::SHA256.hexdigest(PI_KEY)[0, 12]
    assert_no_match(/#{Regexp.escape(PI_KEY)}/, response.body)
  end

  test "the Pi tab has no account-pool machinery on it" do
    ManagedSecret.stub(:openrouter_key, unwritable_secret) do
      get inference_url(runtime: "pi")
    end

    assert_select "form[action=?]", add_account_inference_path, count: 0
    assert_select "form[action=?]", refresh_all_inference_path, count: 0
  end

  test "the Pi tab lists only OpenRouter-routed models as the ones this deployment feeds" do
    ManagedSecret.stub(:openrouter_key, unwritable_secret) do
      get inference_url(runtime: "pi")
    end

    assert_match "openrouter/anthropic/claude-opus-4.6", response.body
  end

  test "a closed write path names the missing permissions rather than offering a form" do
    ManagedSecret.stub(:openrouter_key, unwritable_secret) do
      get inference_url(runtime: "pi")
    end

    assert_select "[data-openrouter-write-blocked]"
    assert_select "form[action=?]", openrouter_key_inference_path, count: 0
    assert_match ParameterStore::Capabilities::CREATE_SECRET, response.body
    assert_match "ZIMMER_PARAMS_WRITER_SERVICE_ACCOUNT_KEY_JSON", response.body
  end

  # --- The property: the key cannot be read back out -------------------------

  test "no HTTP surface returns the stored key" do
    secret = writable_secret
    ManagedSecret.stub(:openrouter_key, secret) do
      put openrouter_key_inference_path, params: { openrouter_api_key: PI_KEY }
      assert_redirected_to inference_path(runtime: "pi")
      assert_equal PI_KEY, pi_chain.get(ManagedSecret::OPENROUTER_API_KEY),
        "precondition: the key really is in the store, so the assertions below mean something"

      # The redirect response, the flash it carries, and the page it lands on.
      assert_no_match(/#{Regexp.escape(PI_KEY)}/, response.body)
      assert_no_match(/#{Regexp.escape(PI_KEY)}/, flash.to_hash.values.join(" "))

      follow_redirect!
      assert_response :success
      assert_no_match(/#{Regexp.escape(PI_KEY)}/, response.body)

      # And a fresh render, which is the state a later visitor sees.
      get inference_url(runtime: "pi")
      assert_no_match(/#{Regexp.escape(PI_KEY)}/, response.body)
    end
  end

  test "no route reads the key back" do
    # There is deliberately no GET on the key. If one is ever added, this fails.
    key_routes = Rails.application.routes.routes.select do |route|
      route.path.spec.to_s.include?("openrouter_key")
    end

    assert key_routes.any?, "precondition: the key routes exist"
    assert_equal [ "DELETE", "PUT" ], key_routes.map(&:verb).sort,
      "the key is create/update/delete only — a GET here would be a read-back surface"
  end

  test "the key is filtered out of the parameter log" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

    assert_equal "[FILTERED]", filter.filter("openrouter_api_key" => PI_KEY)["openrouter_api_key"]
  end

  test "a successful save reports a digest and not the key" do
    secret = writable_secret
    ManagedSecret.stub(:openrouter_key, secret) do
      put openrouter_key_inference_path, params: { openrouter_api_key: PI_KEY }
    end

    assert_match Digest::SHA256.hexdigest(PI_KEY)[0, 12], flash[:notice]
    assert_no_match(/#{Regexp.escape(PI_KEY)}/, flash[:notice])
  end

  test "a blank save is refused and nothing reaches the store" do
    secret = writable_secret
    ManagedSecret.stub(:openrouter_key, secret) do
      put openrouter_key_inference_path, params: { openrouter_api_key: "" }
    end

    assert_redirected_to inference_path(runtime: "pi")
    assert_match(/Paste a key first/, flash[:alert])
    assert_empty pi_fake.secrets
  end

  test "a refused write says so instead of claiming a save" do
    ManagedSecret.stub(:openrouter_key, unwritable_secret) do
      put openrouter_key_inference_path, params: { openrouter_api_key: PI_KEY }
    end

    assert_nil flash[:notice]
    assert_match(/cannot write/, flash[:alert])
  end

  test "delete removes the key" do
    secret = writable_secret(value: PI_KEY)
    ManagedSecret.stub(:openrouter_key, secret) do
      delete destroy_openrouter_key_inference_path
    end

    assert_redirected_to inference_path(runtime: "pi")
    assert_match(/deleted/, flash[:notice])
    assert_nil pi_chain.get(ManagedSecret::OPENROUTER_API_KEY)
  end

  private

  PI_KEY = "sk-or-v1-controller-fixture-value"

  def pi_fake
    @pi_fake ||= FakeParameterStore.new
  end

  def pi_chain
    @pi_chain ||= pi_fake.chain
  end

  def writable_secret(value: nil)
    pi_fake.held_permissions = ParameterStore::Capabilities::PROBED_PERMISSIONS
    pi_fake.seed_secret(ManagedSecret::OPENROUTER_API_KEY, value) if value
    ManagedSecret.new(ManagedSecret::OPENROUTER_API_KEY, chain: pi_chain,
      writer: ParameterStore::Writer::Configuration.new(
        client: pi_fake.write_client, identity: :writer, reason: nil
      ))
  end

  # The shape every deployment is in until the IAM grant lands: a store Zimmer
  # can read and cannot write.
  def unwritable_secret
    pi_fake.held_permissions = [
      ParameterStore::Capabilities::RENDER_PARAMETER,
      ParameterStore::Capabilities::READ_SECRET_VALUE
    ]
    ManagedSecret.new(ManagedSecret::OPENROUTER_API_KEY, chain: pi_chain,
      writer: ParameterStore::Writer::Configuration.new(
        client: pi_fake.write_client, identity: :resolver, reason: nil
      ))
  end
end
