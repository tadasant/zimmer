require "test_helper"
require "mocha/minitest"
require "automated_prompts"

class AuthOutageParkServiceTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    # Every assertion here is about the shape of the account pool, and the
    # fixtures ship active accounts. Start from an empty pool so each test
    # states its own.
    ClaudeAccountQuotaSnapshot.delete_all
    ClaudeAccount.delete_all

    @session = Session.create!(
      prompt: "Test prompt",
      agent_runtime: "claude_code",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      metadata: { "clone_path" => "/tmp/test-clone", "working_directory" => "/tmp/test-clone" }
    )
  end

  def park!(reason: AuthOutageParkService::QUOTA_EXHAUSTED, detail: nil)
    AuthOutageParkService.new(@session).park!(reason: reason, detail: detail)
  end

  # Another session caught by the same outage. `needs_input` so parking it lands
  # it straight in `waiting` rather than deferring the sleep to its next pause.
  def parked_peer(runtime: "claude_code")
    Session.create!(
      prompt: "Peer",
      agent_runtime: runtime,
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      metadata: { "clone_path" => "/tmp/test-clone", "working_directory" => "/tmp/test-clone" }
    )
  end

  def create_account(email:, status:, reset_5h: nil, reset_7d: nil,
    utilization_5h: 1.0, utilization_7d: 1.0, snapshot: nil, runtime: "claude_code")
    account = ClaudeAccount.create!(
      email: email,
      status: status,
      runtime: runtime,
      oauth_config: { "credentials_json" => { "claudeAiOauth" => { "accessToken" => "tok" } } }
    )
    # A snapshot with no reset stamps at all is a real reading, and the one this
    # service used to misread, so it has to be constructible here.
    snapshot = reset_5h.present? || reset_7d.present? if snapshot.nil?
    if snapshot
      account.quota_snapshots.create!(reset_5h: reset_5h, reset_7d: reset_7d,
        utilization_5h: utilization_5h, utilization_7d: utilization_7d)
    end
    account
  end

  # ===========================================================================
  # park!
  # ===========================================================================

  test "records the outage and logs it, without scheduling anything" do
    assert park!

    @session.reload
    assert_equal AuthOutageParkService::QUOTA_EXHAUSTED, @session.metadata["auth_outage_reason"]
    assert_not_nil @session.metadata["auth_outage_parked_at"]

    log = @session.logs.where(level: "error").last
    assert_includes log.content, "Quota exceeded across all Claude Code accounts"
    assert_includes log.content, "parked (waiting)"

    assert_empty Trigger.where(last_session_id: @session.id),
      "a park must not create a per-session wake-up trigger — the quota_available " \
      "fleet wake replaced them"
  end

  # The banner shows when the pool is expected back. It is an estimate read off
  # the accounts' own reset stamps, not a schedule: nothing fires at it.
  test "records the pool's expected recovery time when the snapshots know it" do
    account = create_account(email: "spent@example.com", status: :quota_exceeded)
    reset = 3.hours.from_now
    ClaudeAccountQuotaSnapshot.create!(claude_account: account, reset_5h: 1.hour.from_now,
      reset_7d: reset, utilization_5h: 1.0, utilization_7d: 1.0)

    park!

    recorded = Time.iso8601(@session.reload.metadata["auth_outage_pool_recovers_at"])
    assert_in_delta reset.to_i, recorded.to_i, 5
  end

  test "records no recovery estimate for an auth outage, which has no published clock" do
    park!(reason: AuthOutageParkService::AUTH_UNRECOVERABLE)

    assert_nil @session.reload.metadata["auth_outage_pool_recovers_at"]
  end

  # The fingerprint is the record of which identities failed this session — the
  # only thing wake_parked_sessions! can compare a recovered pool against.
  test "records a fingerprint of the pool that failed the session" do
    create_account(email: "present@example.com", status: :active)

    park!(reason: AuthOutageParkService::AUTH_UNRECOVERABLE)

    assert_equal AuthOutageParkService.pool_fingerprint("claude_code"),
      @session.reload.metadata[AuthOutageParkService::POOL_FINGERPRINT_KEY]
  end

  # Creating the trigger while the session is still running is what makes the
  # session dormant: Trigger#sleep_target_session_if_applicable sets
  # pending_sleep, and the pause callback then transitions needs_input → waiting.
  # A waiting session is not nudged by HeartbeatSweepJob, which is what breaks
  # the re-nudge loop.
  test "parking a running session marks it for deferred sleep, and pausing lands it in waiting" do
    park!

    @session.reload
    assert_equal true, @session.metadata["pending_sleep"]

    @session.pause!
    assert_equal "waiting", @session.reload.status
  end

  test "parking a needs_input session puts it straight to sleep" do
    @session.update!(status: :needs_input)

    park!

    assert_equal "waiting", @session.reload.status
  end

  test "sends a push notification naming the outage" do
    assert_enqueued_with(job: SendPushNotificationJob) do
      park!(reason: AuthOutageParkService::AUTH_UNRECOVERABLE)
    end
  end

  test "rejects an unknown reason" do
    assert_raises(ArgumentError) do
      AuthOutageParkService.new(@session).park!(reason: "nonsense")
    end
  end

  # ===========================================================================
  # wake_parked_sessions!
  # ===========================================================================

  test "wakes a parked session once the pool has an available account" do
    create_account(email: "restored@example.com", status: :active)
    @session.update!(status: :needs_input)
    park!
    assert_equal "waiting", @session.reload.status

    resumed = nil
    assert_enqueued_with(job: AgentSessionJob) do
      resumed = AuthOutageParkService.wake_parked_sessions!
    end

    assert_equal 1, resumed
    @session.reload
    assert_equal "running", @session.status
    AuthOutageParkService::OUTAGE_METADATA_KEYS.each do |key|
      assert_nil @session.metadata[key], "#{key} must be cleared when the session resumes"
    end
  end

  # The whole point of the refactor: the sweep has no notion of order, so it must
  # not be what starts spot work. Those sessions wait for the quota_available
  # fleet wake, which reads precedence.
  test "leaves a parked spot session for the ranked fleet wake" do
    create_account(email: "restored@example.com", status: :active)
    @session.update!(status: :needs_input, scheduling_class: SessionGenesis::SPOT)
    park!
    assert_equal "waiting", @session.reload.status

    assert_equal 0, AuthOutageParkService.wake_parked_sessions!
    assert_equal "waiting", @session.reload.status
    assert_equal AuthOutageParkService::QUOTA_EXHAUSTED, @session.metadata["auth_outage_reason"],
      "it stays parked, so the fleet wake can still find it"
  end

  # Priority work is never gated on quota, so it recovers with the pool rather
  # than waiting for a fleet session to be spawned and take its first turn.
  test "wakes a parked priority session directly" do
    create_account(email: "restored@example.com", status: :active)
    @session.update!(status: :needs_input, scheduling_class: SessionGenesis::PRIORITY)
    park!

    assert_equal 1, AuthOutageParkService.wake_parked_sessions!
    assert_equal "running", @session.reload.status
  end

  # A quota-parked spot session is woken by the POOL's own rising edge, which
  # QuotaAvailabilityMonitor fires. The sweep asking again would be a second
  # request for a wake already on its way — and, since the sweep runs in the same
  # pass as the check, the interplay is what made every later pass re-fire.
  test "an eligible parked spot QUOTA session leaves the pool edge to fire" do
    create_account(email: "restored@example.com", status: :active)
    @session.update!(status: :needs_input, scheduling_class: SessionGenesis::SPOT)
    park!
    AppSetting.current.update!(quota_pool_available: false)

    assert_no_enqueued_jobs(only: SystemEventTriggerJob) do
      assert_equal 0, AuthOutageParkService.wake_parked_sessions!
    end
    assert_equal "waiting", @session.reload.status
  end

  # The reason an auth park needs it: `accounts.available` never goes false→true
  # for a credentials problem, so the pool's own edge never fires for it.
  test "a spot auth-outage park asks for the wake once its pool credentials change" do
    account = create_account(email: "present@example.com", status: :active)
    @session.update!(status: :needs_input, scheduling_class: SessionGenesis::SPOT)
    park!(reason: AuthOutageParkService::AUTH_UNRECOVERABLE)
    AppSetting.current.update!(quota_pool_available: false)
    create_account(email: "new-identity@example.com", status: :active)

    assert_enqueued_with(job: SystemEventTriggerJob, args: [ "quota_available" ]) do
      AuthOutageParkService.wake_parked_sessions!
    end
    assert account.present?
  end

  test "an ineligible parked spot session asks for nothing" do
    create_account(email: "still-out@example.com", status: :quota_exceeded)
    @session.update!(status: :needs_input, scheduling_class: SessionGenesis::SPOT)
    park!

    assert_no_enqueued_jobs(only: SystemEventTriggerJob) do
      assert_equal 0, AuthOutageParkService.wake_parked_sessions!
    end
  end

  # A quota park is the earliest positive evidence the pool is empty. Without it
  # an outage shorter than the 15-minute sweep is never seen as unavailable, so
  # the recovery is not an edge and nothing wakes.
  test "a quota park records the pool as unavailable" do
    AppSetting.current.update!(quota_pool_available: true)

    park!

    assert_equal false, AppSetting.current.reload.quota_pool_available
  end

  test "leaves a parked session alone while the pool is still exhausted" do
    create_account(email: "still-out@example.com", status: :quota_exceeded)
    @session.update!(status: :needs_input)
    park!

    assert_equal 0, AuthOutageParkService.wake_parked_sessions!
    assert_equal "waiting", @session.reload.status
  end

  # One restored account makes "the pool has an account again" true for every
  # parked session at once. Resuming all of them in one sweep is what spends the
  # recovered window in seconds and re-parks the whole cohort minutes later.
  test "one sweep wakes at most MAX_WAKES_PER_SWEEP parked sessions" do
    create_account(email: "restored@example.com", status: :active)
    cohort = Array.new(AuthOutageParkService::MAX_WAKES_PER_SWEEP + 3) do |i|
      session = parked_peer
      AuthOutageParkService.new(session).park!(reason: AuthOutageParkService::QUOTA_EXHAUSTED)
      # Second-resolution stamps would otherwise tie, leaving the order the cap
      # depends on up to the database.
      session.reload.update!(metadata: session.metadata.merge(
        "auth_outage_parked_at" => (30 - i).minutes.ago.utc.iso8601
      ))
      session
    end

    assert_equal AuthOutageParkService::MAX_WAKES_PER_SWEEP,
      AuthOutageParkService.wake_parked_sessions!
    assert_equal 3, AuthOutageParkService.parked_sessions.count,
      "the rest keep their timer and their place in the queue"

    # Oldest park first, so the sessions held back are the ones parked most
    # recently — nothing starves across sweeps.
    assert_equal cohort.first(AuthOutageParkService::MAX_WAKES_PER_SWEEP).map(&:id).sort,
      cohort.select { |s| s.reload.running? }.map(&:id).sort

    assert_equal 3, AuthOutageParkService.wake_parked_sessions!,
      "the next sweep takes the ones that were held"
  end

  # The cap guards one POOL against being re-drained by everything parked on it,
  # so it is counted per runtime. A fleet of claude_code parks must not hold back
  # the codex sessions whose own pool just recovered.
  test "the per-sweep cap is counted per runtime" do
    create_account(email: "claude@example.com", status: :active)
    create_account(email: "codex@example.com", status: :active, runtime: "codex")

    Array.new(AuthOutageParkService::MAX_WAKES_PER_SWEEP + 2) do |i|
      session = parked_peer
      AuthOutageParkService.new(session).park!(reason: AuthOutageParkService::QUOTA_EXHAUSTED)
      # Older than the codex park below, so a global cap would spend itself here.
      session.reload.update!(metadata: session.metadata.merge(
        "auth_outage_parked_at" => (60 - i).minutes.ago.utc.iso8601
      ))
    end

    codex = parked_peer(runtime: "codex")
    AuthOutageParkService.new(codex).park!(reason: AuthOutageParkService::QUOTA_EXHAUSTED)

    AuthOutageParkService.wake_parked_sessions!

    assert codex.reload.running?,
      "a codex park must not be held by a claude_code pool's batch"
  end

  test "the park stamp is recorded in UTC" do
    park!

    assert_match(/Z\z/, @session.reload.metadata["auth_outage_parked_at"])
  end

  test "does not touch sessions that were never parked" do
    create_account(email: "fine@example.com", status: :active)
    @session.update!(status: :needs_input)

    assert_equal 0, AuthOutageParkService.wake_parked_sessions!
    assert_equal "needs_input", @session.reload.status
  end

  # ===========================================================================
  # wake_parked_sessions! — auth parks
  #
  # An auth park is reached precisely when an account WAS available and the
  # runtime rejected its credentials anyway (AuthRecoveryCoordinator picks
  # AUTH_UNRECOVERABLE when `pool.available.exists?`), so "an account is
  # available" is true by construction at park time and cannot be the whole
  # guard. What it needs on top is evidence the pool's identities have moved.
  # ===========================================================================

  # The 2026-07-31 incident, in miniature: sessions parked against a dead
  # identity, the pool restored 25 minutes later, and every one of them sat out
  # its ~1h timer because the sweep never looked at them.
  test "an auth-outage park is woken once the pool gains an identity it has not tried" do
    create_account(email: "dead-token@example.com", status: :active)
    @session.update!(status: :needs_input)
    park!(reason: AuthOutageParkService::AUTH_UNRECOVERABLE)
    assert_equal "waiting", @session.reload.status

    create_account(email: "freshly-added@example.com", status: :active)

    resumed = nil
    assert_enqueued_with(job: AgentSessionJob) do
      resumed = AuthOutageParkService.wake_parked_sessions!
    end

    assert_equal 1, resumed
    assert_equal "running", @session.reload.status
    assert_includes @session.logs.where(level: "warning").last.content, "The login pool changed"
  end

  # The same fix the old comment said the timer was buying time for — the
  # token-refresh cron repairing the identity in place — now wakes the session
  # instead of being waited out.
  test "an auth-outage park is woken when the failing account's credentials are replaced" do
    account = create_account(email: "reauthed@example.com", status: :active)
    @session.update!(status: :needs_input)
    park!(reason: AuthOutageParkService::AUTH_UNRECOVERABLE)

    account.update!(oauth_config: { "credentials_json" => { "claudeAiOauth" => { "accessToken" => "fresh" } } })

    assert_equal 1, AuthOutageParkService.wake_parked_sessions!
    assert_equal "running", @session.reload.status
  end

  # A restored quota_exceeded account changes the set of identities that can
  # serve the runtime, which is the exact signal QuotaResetCheckerJob produces
  # immediately before it calls this sweep.
  test "an auth-outage park is woken when a quota-exceeded account is restored to active" do
    account = create_account(email: "restorable@example.com", status: :quota_exceeded)
    create_account(email: "dead-token@example.com", status: :active)
    @session.update!(status: :needs_input)
    park!(reason: AuthOutageParkService::AUTH_UNRECOVERABLE)

    account.update!(status: :active)

    assert_equal 1, AuthOutageParkService.wake_parked_sessions!
    assert_equal "running", @session.reload.status
  end

  # The loop the old `reason:` scoping existed to prevent: nothing about the
  # pool has changed, so resuming would walk into the identical rejection every
  # 15 minutes, forever.
  test "an auth-outage park is not woken while the pool is the one that rejected it" do
    create_account(email: "present@example.com", status: :active)
    @session.update!(status: :needs_input)
    park!(reason: AuthOutageParkService::AUTH_UNRECOVERABLE)

    assert_equal 0, AuthOutageParkService.wake_parked_sessions!
    assert_equal "waiting", @session.reload.status,
      "An unchanged pool is no evidence the credentials work now"
    assert_equal 0, AuthOutageParkService.wake_parked_sessions!,
      "and it stays that way on every subsequent sweep"
  end

  # Churn that is not an identity change — a rotation stamp, a quota-hit
  # counter, the 5-minute filesystem token sync rewriting an unchanged config —
  # moves updated_at and must not read as "the pool recovered".
  test "an auth-outage park is not woken by account churn that leaves the credentials alone" do
    account = create_account(email: "busy@example.com", status: :active)
    @session.update!(status: :needs_input)
    park!(reason: AuthOutageParkService::AUTH_UNRECOVERABLE)

    account.update!(last_rotated_to_at: Time.current, quota_hit_count: 3, is_current: true)
    account.update!(oauth_config: account.oauth_config)

    assert_equal 0, AuthOutageParkService.wake_parked_sessions!
    assert_equal "waiting", @session.reload.status
  end

  # An account that appears but cannot serve anything is not a recovery.
  test "an auth-outage park is not woken by a new account that is not available" do
    create_account(email: "dead-token@example.com", status: :active)
    @session.update!(status: :needs_input)
    park!(reason: AuthOutageParkService::AUTH_UNRECOVERABLE)

    create_account(email: "locked-out@example.com", status: :needs_reauth)

    assert_equal 0, AuthOutageParkService.wake_parked_sessions!
    assert_equal "waiting", @session.reload.status
  end

  # Parked before the fingerprint existed (or by a park whose pool read failed):
  # there is nothing to compare against, and "wake anyway" is the resume loop.
  # There is nothing to compare against, so there is no evidence either way — and
  # nothing else would ever pick the session up, since the timer that used to be
  # its way back no longer exists. The early-wake budget is what keeps "no
  # evidence" from becoming a resume loop.
  test "an auth-outage park with no recorded fingerprint is woken anyway" do
    create_account(email: "present@example.com", status: :active)
    @session.update!(status: :needs_input)
    park!(reason: AuthOutageParkService::AUTH_UNRECOVERABLE)
    @session.update!(metadata: @session.metadata.except(AuthOutageParkService::POOL_FINGERPRINT_KEY))

    assert_equal 1, AuthOutageParkService.wake_parked_sessions!
    assert_equal "running", @session.reload.status
  end

  test "a fingerprintless auth park still spends its early-wake budget" do
    create_account(email: "present@example.com", status: :active)
    @session.update!(status: :needs_input)
    park!(reason: AuthOutageParkService::AUTH_UNRECOVERABLE)
    @session.update!(metadata: @session.metadata
      .except(AuthOutageParkService::POOL_FINGERPRINT_KEY)
      .merge(AuthOutageParkService::EARLY_WAKE_LOG_KEY =>
        Array.new(AuthOutageParkService::MAX_EARLY_WAKES) { 1.minute.ago.utc.iso8601 }))

    assert_equal 0, AuthOutageParkService.wake_parked_sessions!
    assert_equal "waiting", @session.reload.status
  end

  # The pool the session failed against can be empty — park_reason_for_pool
  # answers AUTH_UNRECOVERABLE for a pool with nothing available and nothing
  # merely throttled, which is what a fleet of needs_reauth accounts looks like.
  test "an auth-outage park against an empty pool is woken by the first account added" do
    @session.update!(status: :needs_input)
    park!(reason: AuthOutageParkService::AUTH_UNRECOVERABLE)
    assert @session.reload.metadata[AuthOutageParkService::POOL_FINGERPRINT_KEY].present?,
      "An empty pool still has a fingerprint to compare against"

    create_account(email: "first-login@example.com", status: :active)

    assert_equal 1, AuthOutageParkService.wake_parked_sessions!
    assert_equal "running", @session.reload.status
  end

  # A park that could not read the pool records no fingerprint, and the sweep
  # will not wake on an absent one.
  test "a park whose pool could not be read records no fingerprint" do
    AuthOutageParkService.stubs(:pool_fingerprint).returns(nil)
    @session.update!(status: :needs_input)

    park!(reason: AuthOutageParkService::AUTH_UNRECOVERABLE)

    assert_nil @session.reload.metadata[AuthOutageParkService::POOL_FINGERPRINT_KEY]
  end

  # ===========================================================================
  # The early-wake budget
  #
  # A session whose auth is broken for a reason of its own rather than the
  # pool's clears the fingerprint guard every time the pool's credentials move —
  # including the 5-minute sync adopting a token the CLI rotated on disk. The
  # budget is what keeps that a bounded multiple of the spawn rate the timer
  # alone would have produced, rather than an open loop.
  # ===========================================================================

  test "an auth-outage park spends a bounded number of early wakes across re-parks" do
    create_account(email: "dead-token@example.com", status: :active)
    @session.update!(status: :needs_input)

    AuthOutageParkService::MAX_EARLY_WAKES.times do |i|
      park!(reason: AuthOutageParkService::AUTH_UNRECOVERABLE)
      create_account(email: "churn-#{i}@example.com", status: :active)

      assert_equal 1, AuthOutageParkService.wake_parked_sessions!, "wake #{i + 1} should be granted"
      assert_equal i + 1, @session.reload.metadata[AuthOutageParkService::EARLY_WAKE_LOG_KEY].size,
        "the wake must be charged, and survive the resume that spent it"

      @session.update!(status: :needs_input)
    end

    park!(reason: AuthOutageParkService::AUTH_UNRECOVERABLE)
    create_account(email: "churn-again@example.com", status: :active)

    assert_equal 0, AuthOutageParkService.wake_parked_sessions!,
      "Past the budget the session falls back to its timer instead of spinning"
    assert_equal "waiting", @session.reload.status
  end

  # A lifetime counter would punish a session for recovering: the budget is
  # spent by successful wakes too, so three good recoveries over three days
  # would leave it on the hourly timer for good.
  test "early wakes outside the window do not count against the budget" do
    create_account(email: "dead-token@example.com", status: :active)
    @session.update!(status: :needs_input)
    park!(reason: AuthOutageParkService::AUTH_UNRECOVERABLE)
    @session.update!(metadata: @session.metadata.merge(
      AuthOutageParkService::EARLY_WAKE_LOG_KEY => Array.new(AuthOutageParkService::MAX_EARLY_WAKES) do
        (AuthOutageParkService::EARLY_WAKE_WINDOW + 1.hour).ago.utc.iso8601
      end
    ))

    create_account(email: "freshly-added@example.com", status: :active)

    assert_equal 1, AuthOutageParkService.wake_parked_sessions!
    assert_equal 1, @session.reload.metadata[AuthOutageParkService::EARLY_WAKE_LOG_KEY].size,
      "Lapsed entries are pruned rather than accumulating forever"
  end

  # The budget is auth-only: a quota park wakes on unambiguous evidence and has
  # no loop to bound.
  test "quota parks are not charged against the early-wake budget" do
    create_account(email: "restored@example.com", status: :active)
    @session.update!(status: :needs_input)
    park!

    assert_equal 1, AuthOutageParkService.wake_parked_sessions!
    assert_nil @session.reload.metadata[AuthOutageParkService::EARLY_WAKE_LOG_KEY]
  end

  # The log is the one auth_outage_* key that must outlive the resume it paid
  # for — every other resume path clears the rest through STALE_RETRY_METADATA_KEYS.
  test "the early-wake budget survives an ordinary resume" do
    create_account(email: "dead-token@example.com", status: :active)
    @session.update!(status: :needs_input)
    park!(reason: AuthOutageParkService::AUTH_UNRECOVERABLE)
    create_account(email: "freshly-added@example.com", status: :active)
    assert_equal 1, AuthOutageParkService.wake_parked_sessions!

    # Stand in for a user follow-up / trigger fire: the shared clear-then-resume
    # shape every caller uses.
    @session.reload.update!(metadata: @session.metadata.except(*Session::STALE_RETRY_METADATA_KEYS))

    assert_equal 1, @session.reload.metadata[AuthOutageParkService::EARLY_WAKE_LOG_KEY].size
  end

  test "waking is idempotent under a repeated sweep" do
    create_account(email: "restored@example.com", status: :active)
    @session.update!(status: :needs_input)
    park!

    assert_equal 1, AuthOutageParkService.wake_parked_sessions!
    assert_equal 0, AuthOutageParkService.wake_parked_sessions!,
      "An already-resumed session no longer matches the parked scope"
  end

  # ===========================================================================
  # Metadata lifecycle
  # ===========================================================================

  # Cleared centrally rather than by the one path that knows about them: a timer
  # -fired retry, a user follow-up, and deployment recovery all end the parked
  # state, and a leftover marker would render a banner promising a retry that
  # already happened — and would keep matching #parked_sessions, so a later
  # ordinary sleep could be force-resumed as if it were still parked.
  test "outage metadata is stale on resume so no other resume path strands it" do
    AuthOutageParkService::OUTAGE_METADATA_KEYS.each do |key|
      assert_includes Session::STALE_RETRY_METADATA_KEYS, key
    end
  end

  test "any resume clears the outage metadata, not just the quota sweep" do
    @session.update!(status: :needs_input)
    park!
    assert_equal "waiting", @session.reload.status

    # Stand in for a user follow-up / trigger fire: the shared clear-then-resume
    # shape every caller uses.
    @session.update!(metadata: @session.metadata.except(*Session::STALE_RETRY_METADATA_KEYS))
    @session.resume!

    AuthOutageParkService::OUTAGE_METADATA_KEYS.each do |key|
      assert_nil @session.reload.metadata[key]
    end
    assert_equal 0, AuthOutageParkService.parked_sessions.count
  end

  # ===========================================================================
  # park_undelivered_turn! — the escape path from zimmer#6597
  #
  # 6597 was resumed from a quota park, its recovery turn was killed before it
  # reached the runtime, and the exit path answered "the process is gone" with
  # pause! — landing it in needs_input, on the human's action queue, with the
  # undelivered prompt still sitting in metadata and the pool still empty.
  # ===========================================================================

  # The regression: an undelivered turn plus an empty pool must land in `waiting`,
  # never needs_input.
  test "parks a stop whose turn was never delivered while the pool is empty" do
    create_account(email: "out@example.com", status: :quota_exceeded,
      reset_5h: 40.minutes.from_now)
    @session.merge_metadata!("active_follow_up_prompt" => "continue where you left off")

    assert AuthOutageParkService.park_undelivered_turn!(@session),
      "An undelivered turn against an empty pool is the outage, not a finished turn"

    # park! marks the running session pending_sleep; the caller's pause is what
    # carries it through to waiting, exactly as the monitoring loop does.
    @session.reload
    assert @session.metadata["pending_sleep"], "The session must be marked for sleep"
    @session.pause!

    assert_equal "waiting", @session.reload.status
    assert_equal AuthOutageParkService::QUOTA_EXHAUSTED, @session.metadata["auth_outage_reason"]
    assert_empty Trigger.where(last_session_id: @session.id),
      "the session waits for the quota_available fleet wake, not for a timer of its own"
  end

  # The other half of the guard. A session that finished its work in the same
  # minute the pool ran dry has nothing to resume; parking it would sleep it and
  # then nudge an agent that is already done.
  test "leaves a stop alone when the turn was delivered" do
    create_account(email: "out@example.com", status: :quota_exceeded)

    assert_not AuthOutageParkService.park_undelivered_turn!(@session)

    @session.pause!
    assert_equal "needs_input", @session.reload.status
    assert_nil @session.metadata["auth_outage_reason"]
  end

  # An undelivered turn with a usable pool is some other failure, and parking it
  # would hide that behind a quota banner.
  test "leaves an undelivered turn alone while the pool can still serve it" do
    create_account(email: "fine@example.com", status: :active)
    @session.merge_metadata!("active_follow_up_prompt" => "continue where you left off")

    assert_not AuthOutageParkService.park_undelivered_turn!(@session)

    @session.pause!
    assert_equal "needs_input", @session.reload.status
  end

  # The finding that mattered most in review: `active_follow_up_prompt` is cleared by only
  # ONE exit path, and these guards sit on the others — so its mere presence is not evidence
  # the turn failed. A turn whose prompt is in the transcript ran, whatever the pool says.
  test "leaves a stop alone when the prompt reached the runtime's transcript" do
    create_account(email: "out@example.com", status: :quota_exceeded)
    prompt = "continue where you left off"
    @session.update!(transcript: [
      { "type" => "user", "message" => { "role" => "user", "content" => prompt } }.to_json,
      { "type" => "assistant", "message" => { "role" => "assistant", "content" => "done",
                                              "stop_reason" => "end_turn" } }.to_json
    ].join("\n") + "\n")
    @session.merge_metadata!("active_follow_up_prompt" => prompt)

    assert_not AuthOutageParkService.turn_undelivered?(@session)
    assert_not AuthOutageParkService.park_undelivered_turn!(@session),
      "A turn the runtime recorded is a turn that ran, however empty the pool is"

    @session.pause!
    assert_equal "needs_input", @session.reload.status
  end

  # A user pause terminates the process BEFORE transitioning, so these exits can be reached
  # for a session the human has already stopped. Re-arming it with a wake trigger would undo
  # their decision.
  test "leaves a user-paused session alone" do
    create_account(email: "out@example.com", status: :quota_exceeded)
    @session.merge_metadata!("active_follow_up_prompt" => "continue",
      "paused_by" => "user")

    assert_not AuthOutageParkService.park_undelivered_turn!(@session)
  end

  # Two of the three call sites can be reached in one pass through the monitoring loop.
  # Parking twice would send two push notifications for one stop.
  test "does not park a session that is already parked" do
    create_account(email: "out@example.com", status: :quota_exceeded)
    @session.merge_metadata!("active_follow_up_prompt" => "continue")
    assert AuthOutageParkService.park_undelivered_turn!(@session)
    parked_at = @session.reload.metadata["auth_outage_parked_at"]

    assert_not AuthOutageParkService.park_undelivered_turn!(@session.reload),
      "A parked session must not be parked again by the next exit path in the same pass"
    assert_equal parked_at, @session.reload.metadata["auth_outage_parked_at"]
  end

  # An unreadable pool is not evidence of an outage. The sibling predicate
  # .runtime_has_available_account? rescues to false meaning "do not wake", which is
  # conservative; the same false here would mean "park", which is not.
  test "does not park when the pool cannot be read" do
    @session.merge_metadata!("active_follow_up_prompt" => "continue")
    RuntimeAuthProvider.stubs(:for).raises(StandardError.new("pool unreadable"))

    assert_not AuthOutageParkService.pool_confirmed_empty?("claude_code")
    assert_not AuthOutageParkService.park_undelivered_turn!(@session)
  end

  # A session parked this way is woken by the pool recovering, not by its timer.
  test "a turn parked as undelivered is resumed by the reset sweep" do
    create_account(email: "out@example.com", status: :quota_exceeded)
    @session.merge_metadata!("active_follow_up_prompt" => "continue where you left off")
    AuthOutageParkService.park_undelivered_turn!(@session)
    @session.pause!
    assert_equal "waiting", @session.reload.status

    ClaudeAccount.find_by(email: "out@example.com").update!(status: :active)

    assert_equal 1, AuthOutageParkService.wake_parked_sessions!
    assert_equal "running", @session.reload.status
  end

  # ===========================================================================
  # resume_parked! — the window that let the sweep hijack 6597's resume
  # ===========================================================================

  # CleanupOrphanedSessionsJob calls a running session with a blank running_job_id
  # "DEFINITELY orphaned" with no grace period. resume_parked! used to leave the
  # session in exactly that shape while its job was still being enqueued, so a
  # sweep landing in the gap reaped the resume and replaced it with a
  # resume-monitoring job pointed at a stale pid.
  test "resuming a parked session records its prompt and its job id" do
    create_account(email: "restored@example.com", status: :active)
    @session.update!(status: :needs_input)
    park!
    assert_equal "waiting", @session.reload.status

    AuthOutageParkService.wake_parked_sessions!

    @session.reload
    assert_equal "running", @session.status
    assert @session.metadata["pending_follow_up_prompt"].present?,
      "The recovery prompt must be visible the moment the session is running"
    assert @session.running_job_id.present?,
      "The resuming job must be recorded so orphan detection has something to look at"
  end

  # The marker is only worth writing if the sweep honours it. This pins that it
  # does, for a session in the exact mid-resume shape.
  test "orphan detection skips a mid-resume session because of the prompt marker" do
    @session.update!(running_job_id: nil)
    @session.update_column(:created_at, 1.hour.ago)
    sweep = CleanupOrphanedSessionsJob.new

    assert sweep.send(:orphaned_running_session?, @session),
      "Without the marker a running session with no job is reaped — the 6597 window"

    @session.merge_metadata!("pending_follow_up_prompt" => "continue where you left off")

    assert_not sweep.send(:orphaned_running_session?, @session.reload),
      "The marker resume_parked! now writes must close that window"
  end
end
