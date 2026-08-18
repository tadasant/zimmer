require "test_helper"
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
  def parked_peer
    Session.create!(
      prompt: "Peer",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      metadata: { "clone_path" => "/tmp/test-clone", "working_directory" => "/tmp/test-clone" }
    )
  end

  def create_account(email:, status:, reset_5h: nil, reset_7d: nil,
    utilization_5h: 1.0, utilization_7d: 1.0, snapshot: nil)
    account = ClaudeAccount.create!(
      email: email,
      status: status,
      runtime: "claude_code",
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

  # RETRY_JITTER is added after the clamp, so every retry assertion has to
  # tolerate it. Bundled here so the number appears once.
  def jitter_delta(base = 60)
    base + AuthOutageParkService::RETRY_JITTER.to_i
  end

  # ===========================================================================
  # park!
  # ===========================================================================

  test "records the outage, logs it, and schedules a wake-up trigger" do
    retry_at = park!

    assert_not_nil retry_at

    @session.reload
    assert_equal AuthOutageParkService::QUOTA_EXHAUSTED, @session.metadata["auth_outage_reason"]
    assert_equal retry_at.utc.iso8601, @session.metadata["auth_outage_retry_at"]
    assert_not_nil @session.metadata["auth_outage_parked_at"]

    log = @session.logs.where(level: "error").last
    assert_includes log.content, "Quota exceeded across all Claude Code accounts"
    assert_includes log.content, "will resume automatically"

    trigger = Trigger.find_by(last_session_id: @session.id)
    assert_not_nil trigger, "A one-time wake-up trigger must be created"
    assert trigger.reuse_session
    condition = trigger.trigger_conditions.first
    assert condition.one_time_schedule?
    assert_equal "UTC", condition.configuration["timezone"]
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
  # Retry time
  # ===========================================================================

  # QuotaResetCheckerJob clears an account only when BOTH windows are clear, so
  # an account frees up at the LATER of its two resets; the pool frees up at the
  # EARLIEST such account.
  test "derives the retry time from the earliest usable account reset" do
    create_account(email: "late@example.com", status: :quota_exceeded,
      reset_5h: 6.hours.from_now, reset_7d: 8.hours.from_now)
    create_account(email: "early@example.com", status: :quota_exceeded,
      reset_5h: 2.hours.from_now, reset_7d: 3.hours.from_now)

    retry_at = park!

    assert_in_delta (3.hours.from_now + AuthOutageParkService::RESET_BUFFER).to_i, retry_at.to_i,
      jitter_delta
  end

  test "falls back to the default delay when no snapshot carries a reset time" do
    create_account(email: "nosnap@example.com", status: :quota_exceeded)

    retry_at = park!

    assert_in_delta AuthOutageParkService::DEFAULT_RETRY_DELAY.from_now.to_i, retry_at.to_i,
      jitter_delta
  end

  test "clamps a reset time that has effectively already passed up to the floor" do
    create_account(email: "justnow@example.com", status: :quota_exceeded,
      reset_5h: 10.seconds.from_now, reset_7d: 10.seconds.from_now)

    retry_at = park!

    assert retry_at >= AuthOutageParkService::MIN_RETRY_DELAY.from_now - 5.seconds,
      "A wake-up in the past or seconds away would fire-and-drop in the scheduler"
  end

  test "clamps an absurdly distant reset time down to the ceiling" do
    create_account(email: "sentinel@example.com", status: :quota_exceeded,
      reset_5h: 40.days.from_now, reset_7d: 40.days.from_now)

    retry_at = park!

    assert retry_at <= AuthOutageParkService::MAX_RETRY_DELAY.from_now + 5.seconds
  end

  # The ceiling swallows jitter the same way the floor does, and this is the case
  # the observed trigger waves came from: a weekly reset or a sentinel expiry far
  # enough out that every session in the outage pins to MAX_RETRY_DELAY. Jitter
  # added on top of the ceiling clamps straight back down onto it, so the whole
  # cohort lands on one instant twelve hours out.
  test "a cohort pinned to the ceiling still spreads, and still respects the ceiling" do
    create_account(email: "sentinel@example.com", status: :quota_exceeded,
      reset_5h: 40.days.from_now, reset_7d: 40.days.from_now)

    started_at = Time.current
    retries = Array.new(12) do
      AuthOutageParkService.new(parked_peer).park!(reason: AuthOutageParkService::QUOTA_EXHAUSTED)
    end

    assert_operator retries.uniq.size, :>, 1,
      "every session pinned to the ceiling must not wake at the same instant"
    assert_operator retries.max - retries.min, :>, 30.seconds,
      "the cohort must occupy a window, not a point"
    assert_operator retries.max, :<=, started_at + AuthOutageParkService::MAX_RETRY_DELAY + 60.seconds
    assert_operator retries.min, :>=, started_at + AuthOutageParkService::MAX_RETRY_DELAY -
      AuthOutageParkService::RETRY_JITTER - 60.seconds
  end

  # compute_retry_at clamps into [floor, ceiling] before adding jitter. Ruby's
  # `clamp` raises when the low bound exceeds the high one, and park!'s rescue
  # would turn that into a session parked with no retry at all — so the ceiling
  # is held at or above the floor even when the backoff has run all the way up.
  test "a fully backed-off quota park still computes a retry" do
    create_account(email: "still-out@example.com", status: :quota_exceeded,
      reset_5h: 40.days.from_now, reset_7d: 40.days.from_now)
    @session.update!(metadata: @session.metadata.merge(
      AuthOutageParkService::QUOTA_PARK_LOG_KEY =>
        Array.new(AuthOutageParkService::MAX_QUOTA_PARK_BACKOFF_STEPS) { 1.minute.ago.utc.iso8601 }
    ))

    retry_at = park!

    assert_not_nil retry_at
    assert_operator retry_at, :<=, AuthOutageParkService::MAX_RETRY_DELAY.from_now + 5.seconds
  end

  # An auth outage has no published reset clock, so snapshots must be ignored.
  test "an auth outage always uses the default delay" do
    create_account(email: "quota@example.com", status: :quota_exceeded,
      reset_5h: 2.hours.from_now, reset_7d: 2.hours.from_now)

    retry_at = park!(reason: AuthOutageParkService::AUTH_UNRECOVERABLE)

    assert_in_delta AuthOutageParkService::DEFAULT_RETRY_DELAY.from_now.to_i, retry_at.to_i,
      jitter_delta
  end

  # =========================================================================
  # Retry backoff — the 2026-08-17 queue backlog
  # =========================================================================
  #
  # A snapshot carrying NO reset stamps is the shape that broke this. Its weekly
  # counter still reads as spent — .effective_utilization only discounts a
  # counter once a reset time has actually passed, and there is no time here to
  # pass — so #windows_clear? is false and QuotaResetCheckerJob correctly leaves
  # the account exceeded. Reading the absent stamps as "clears now" pinned every
  # parked session to the 5-minute floor, so the whole parked population woke
  # into the same exhausted pool and re-parked, every five minutes, indefinitely.
  # On 2026-08-17 that put 148 sessions through 368 parks in 40 minutes and 377
  # jobs into the ready queue.
  test "an exceeded account the healer will not restore does not read as clearing now" do
    account = create_account(email: "nostamps@example.com", status: :quota_exceeded,
      reset_5h: nil, reset_7d: nil, utilization_7d: 1.0, snapshot: true)
    assert_not account.latest_snapshot.windows_clear?,
      "fixture must be an account the healer would decline to restore"

    retry_at = park!

    assert retry_at > 30.minutes.from_now,
      "An account the next QuotaResetCheckerJob tick will leave exceeded must not " \
      "produce a five-minute retry — that is the re-park loop"
    assert_in_delta AuthOutageParkService::DEFAULT_RETRY_DELAY.from_now.to_i, retry_at.to_i,
      jitter_delta
  end

  # The counterpart the fix must not break: a stamp that really has passed means
  # the sliding window turned over, so the healer will restore this account on
  # its next tick and "now" is the honest answer.
  test "an exceeded account the healer would restore still clears at now" do
    account = create_account(email: "clearing@example.com", status: :quota_exceeded,
      reset_5h: 1.hour.ago, reset_7d: 1.hour.ago)
    assert account.latest_snapshot.windows_clear?,
      "fixture must be an account the healer would restore on its next tick"

    retry_at = park!

    assert retry_at <= jitter_delta(AuthOutageParkService::MIN_RETRY_DELAY.to_i).seconds.from_now,
      "A pool about to recover keeps its fast first retry"
  end

  test "each consecutive quota park doubles the floor under the retry" do
    create_account(email: "nosnap@example.com", status: :quota_exceeded)

    floors = 3.times.map do |i|
      @session.update!(metadata: (@session.metadata || {}).merge(
        AuthOutageParkService::QUOTA_PARK_LOG_KEY => Array.new(i) { |n| (n + 1).minutes.ago.utc.iso8601 }
      ))
      AuthOutageParkService.new(@session).send(:quota_retry_floor)
    end

    assert_equal [ 5.minutes, 10.minutes, 20.minutes ], floors
  end

  test "the backoff floor stops doubling at MAX_QUOTA_PARK_BACKOFF_STEPS" do
    stamps = Array.new(50) { |n| (n + 1).minutes.ago.utc.iso8601 }
    @session.update!(metadata: (@session.metadata || {}).merge(
      AuthOutageParkService::QUOTA_PARK_LOG_KEY => stamps
    ))

    expected = AuthOutageParkService::MIN_RETRY_DELAY *
      (2**AuthOutageParkService::MAX_QUOTA_PARK_BACKOFF_STEPS)
    assert_equal expected, AuthOutageParkService.new(@session).send(:quota_retry_floor)
  end

  test "parks outside the rolling window stop counting against the floor" do
    @session.update!(metadata: (@session.metadata || {}).merge(
      AuthOutageParkService::QUOTA_PARK_LOG_KEY => [
        (AuthOutageParkService::QUOTA_PARK_WINDOW + 1.hour).ago.utc.iso8601,
        (AuthOutageParkService::QUOTA_PARK_WINDOW + 2.hours).ago.utc.iso8601
      ]
    ))

    assert_equal AuthOutageParkService::MIN_RETRY_DELAY,
      AuthOutageParkService.new(@session).send(:quota_retry_floor)
  end

  test "a quota park records itself in the backoff log, trimmed to the steps the floor uses" do
    create_account(email: "nosnap@example.com", status: :quota_exceeded)
    cap = AuthOutageParkService::MAX_QUOTA_PARK_BACKOFF_STEPS
    @session.update!(metadata: (@session.metadata || {}).merge(
      AuthOutageParkService::QUOTA_PARK_LOG_KEY => Array.new(cap + 3) { |n| (n + 1).minutes.ago.utc.iso8601 }
    ))

    park!

    log = @session.reload.metadata[AuthOutageParkService::QUOTA_PARK_LOG_KEY]
    assert_equal cap, log.size
  end

  # The backoff log is what throttles the resume, so a resume that cleared it
  # would hand every re-park a clean slate and bound nothing.
  test "the backoff log survives the resume it throttles" do
    create_account(email: "restored@example.com", status: :active)
    @session.update!(status: :needs_input)
    park!
    assert @session.reload.metadata[AuthOutageParkService::QUOTA_PARK_LOG_KEY].present?

    AuthOutageParkService.wake_parked_sessions!

    assert @session.reload.metadata[AuthOutageParkService::QUOTA_PARK_LOG_KEY].present?,
      "clearing the log on resume would let a session re-park at the floor forever"
    assert_not_includes AuthOutageParkService::OUTAGE_METADATA_KEYS,
      AuthOutageParkService::QUOTA_PARK_LOG_KEY
    assert_not_includes Session::STALE_RETRY_METADATA_KEYS,
      AuthOutageParkService::QUOTA_PARK_LOG_KEY
  end

  # 148 sessions parked within seconds of each other must not wake within seconds
  # of each other onto a queue sized for 16 concurrent agents.
  test "retry times are jittered so a parked population does not wake as a herd" do
    create_account(email: "nosnap@example.com", status: :quota_exceeded)

    retries = 25.times.map do
      session = Session.create!(
        prompt: "Test prompt", agent_runtime: "claude_code", status: :running,
        git_root: "https://github.com/test/repo.git", branch: "main",
        execution_provider: "local_filesystem", session_id: SecureRandom.uuid,
        metadata: { "clone_path" => "/tmp/c", "working_directory" => "/tmp/c" }
      )
      AuthOutageParkService.new(session).park!(reason: AuthOutageParkService::QUOTA_EXHAUSTED)
    end.compact

    assert retries.map(&:to_i).uniq.size > 1,
      "every session computing the same retry second is the thundering herd"
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

  test "leaves a parked session alone while the pool is still exhausted" do
    create_account(email: "still-out@example.com", status: :quota_exceeded)
    @session.update!(status: :needs_input)
    park!

    assert_equal 0, AuthOutageParkService.wake_parked_sessions!
    assert_equal "waiting", @session.reload.status
  end

  # resume! consumes the session's pending one-time wake conditions, so the timer
  # backstop cannot fire again on an already-running session.
  # A consumed condition leaves the trigger row inert but enabled, having fired
  # nothing, so the sweep drops the row too — otherwise every park/resume cycle
  # adds a line to the trigger list that nothing reaps until an hour after a
  # scheduled_at up to 12 hours out.
  test "waking a parked session consumes and then discards its wake-up trigger" do
    create_account(email: "restored@example.com", status: :active)
    @session.update!(status: :needs_input)
    park!
    assert_equal 1, AuthOutageParkService.retry_triggers_for(@session).count

    AuthOutageParkService.wake_parked_sessions!

    assert_equal 0, AuthOutageParkService.retry_triggers_for(@session).count,
      "A spent retry trigger must not outlive the resume it delivered"
  end

  # A user's own wake for the same session has the identical reuse_session +
  # last_session_id shape. Only the name tells them apart, so only the name may
  # decide what gets destroyed.
  test "discarding retry triggers leaves the session's other wake-ups alone" do
    create_account(email: "restored@example.com", status: :active)
    @session.update!(status: :needs_input)
    park!

    mine = Trigger.create!(
      name: "Wake me up later for session ##{@session.id}",
      agent_root_name: @session.agent_runtime,
      prompt_template: "check on the deploy",
      reuse_session: true,
      last_session_id: @session.id,
      trigger_conditions_attributes: [ {
        condition_type: "schedule",
        configuration: { "scheduled_at" => 3.hours.from_now.utc.strftime("%Y-%m-%dT%H:%M:%S"),
                         "timezone" => "UTC" }
      } ]
    )

    AuthOutageParkService.wake_parked_sessions!

    assert Trigger.exists?(mine.id), "Only Zimmer's own retry triggers are Zimmer's to destroy"
  end

  test "a re-park supersedes the previous retry trigger instead of stacking one" do
    3.times do
      @session.update!(status: :needs_input)
      park!
    end

    assert_equal 1, AuthOutageParkService.retry_triggers_for(@session).count,
      "Three parks must leave one armed retry, not a column of them"

    scheduled = AuthOutageParkService.retry_triggers_for(@session).first
      .trigger_conditions.first.configuration["scheduled_at"]
    assert_equal @session.reload.metadata["auth_outage_retry_at"],
      Time.zone.parse(scheduled).utc.iso8601,
      "the surviving trigger is the current one, not the first"
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

  # parked_sessions sorts the stamp lexicographically, which only agrees with
  # chronological order while every stamp is written in the same zone.
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
  test "an auth-outage park with no recorded fingerprint is left to its timer" do
    create_account(email: "present@example.com", status: :active)
    @session.update!(status: :needs_input)
    park!(reason: AuthOutageParkService::AUTH_UNRECOVERABLE)
    @session.update!(metadata: @session.metadata.except(AuthOutageParkService::POOL_FINGERPRINT_KEY))

    create_account(email: "freshly-added@example.com", status: :active)

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

  # The metadata renders "will resume automatically at HH:MM", so recording it
  # before the trigger exists would promise a retry nothing can keep.
  test "a failed wake-up schedule leaves no retry promise behind" do
    Trigger.stubs(:create!).raises(ActiveRecord::RecordInvalid.new(Trigger.new))

    assert_nil park!
    @session.reload
    AuthOutageParkService::OUTAGE_METADATA_KEYS.each do |key|
      assert_nil @session.metadata[key], "#{key} must not outlive a failed schedule"
    end
  end

  # Codex has no quota API and therefore no snapshots to derive a reset from.
  test "a runtime without quota snapshots parks on the default delay" do
    @session.update!(agent_runtime: "codex")

    retry_at = park!

    assert_in_delta AuthOutageParkService::DEFAULT_RETRY_DELAY.from_now.to_i, retry_at.to_i,
      jitter_delta
    assert_match(/Codex/, @session.logs.where(level: "error").last.content)
  end
end
