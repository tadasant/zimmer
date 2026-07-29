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

  def create_account(email:, status:, reset_5h: nil, reset_7d: nil)
    account = ClaudeAccount.create!(
      email: email,
      status: status,
      runtime: "claude_code",
      oauth_config: { "credentials_json" => { "claudeAiOauth" => { "accessToken" => "tok" } } }
    )
    if reset_5h || reset_7d
      account.quota_snapshots.create!(reset_5h: reset_5h, reset_7d: reset_7d,
        utilization_5h: 1.0, utilization_7d: 1.0)
    end
    account
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

    assert_in_delta (3.hours.from_now + AuthOutageParkService::RESET_BUFFER).to_i, retry_at.to_i, 60
  end

  test "falls back to the default delay when no snapshot carries a reset time" do
    create_account(email: "nosnap@example.com", status: :quota_exceeded)

    retry_at = park!

    assert_in_delta AuthOutageParkService::DEFAULT_RETRY_DELAY.from_now.to_i, retry_at.to_i, 60
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

  # An auth outage has no published reset clock, so snapshots must be ignored.
  test "an auth outage always uses the default delay" do
    create_account(email: "quota@example.com", status: :quota_exceeded,
      reset_5h: 2.hours.from_now, reset_7d: 2.hours.from_now)

    retry_at = park!(reason: AuthOutageParkService::AUTH_UNRECOVERABLE)

    assert_in_delta AuthOutageParkService::DEFAULT_RETRY_DELAY.from_now.to_i, retry_at.to_i, 60
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
  test "waking a parked session consumes its pending wake-up trigger" do
    create_account(email: "restored@example.com", status: :active)
    @session.update!(status: :needs_input)
    park!

    AuthOutageParkService.wake_parked_sessions!

    condition = Trigger.find_by(last_session_id: @session.id).trigger_conditions.first
    assert_not_nil condition.reload.last_triggered_at,
      "The pending wake-up must be consumed so it cannot double-fire"
  end

  test "does not touch sessions that were never parked" do
    create_account(email: "fine@example.com", status: :active)
    @session.update!(status: :needs_input)

    assert_equal 0, AuthOutageParkService.wake_parked_sessions!
    assert_equal "needs_input", @session.reload.status
  end

  # An auth park is reached precisely when an account WAS available and the
  # runtime rejected its credentials anyway, so "an account is available" is not
  # evidence the outage cleared. Waking on it would resume into the identical
  # failure every 15 minutes — the same loop this whole change exists to stop.
  test "an auth-outage park is not woken merely because an account exists" do
    create_account(email: "present@example.com", status: :active)
    @session.update!(status: :needs_input)
    park!(reason: AuthOutageParkService::AUTH_UNRECOVERABLE)

    assert_equal 0, AuthOutageParkService.wake_parked_sessions!
    assert_equal "waiting", @session.reload.status,
      "Auth parks wait for their scheduled retry, not for the quota sweep"
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

    assert_in_delta AuthOutageParkService::DEFAULT_RETRY_DELAY.from_now.to_i, retry_at.to_i, 60
    assert_match(/Codex/, @session.logs.where(level: "error").last.content)
  end
end
