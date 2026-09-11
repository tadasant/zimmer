# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Exercises the decision tree that used to not exist: before this, an auth
# recovery re-injected the CURRENT account unconditionally, so a session whose
# account was itself the problem re-spawned into the identical "Not logged in"
# wall up to three times and then parked with the wrong reason.
class AuthRecoveryCoordinatorTest < ActiveSupport::TestCase
  setup do
    QuotaCheckService.stubs(:check_with_token).returns(
      QuotaCheckService::Result.new(
        success: true, subscription_type: "claude_max", rate_limit_tier: "tier_4",
        utilization_5h: 0.5, utilization_7d: 0.3, status_5h: "allowed", status_7d: "allowed",
        reset_5h: 3.hours.from_now, reset_7d: 5.days.from_now
      )
    )
    stub_token_refresh(success: true)

    @primary = claude_accounts(:primary)
    @secondary = claude_accounts(:secondary)
    @session = Session.create!(
      prompt: "Test prompt",
      agent_runtime: "claude_code",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      session_id: SecureRandom.uuid,
      metadata: { "clone_path" => "/tmp/test-clone", "working_directory" => "/tmp/test-clone" }
    )
  end

  teardown do
    release_foreign_pool_lock
  end

  # Anthropic's OAuth token endpoint, faked. success: false models a permanently
  # invalid refresh token (invalid_grant), which is what marks needs_reauth.
  def stub_token_refresh(success:)
    response = success ? Net::HTTPSuccess.new("1.1", "200", "OK") : Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
    response.stubs(:code).returns(success ? "200" : "400")
    response.stubs(:body).returns(
      if success
        { access_token: "stubbed-access", refresh_token: "stubbed-refresh", expires_in: 3600 }.to_json
      else
        # The description matters: an expired refresh token is the response that
        # proves a dead credential, and it is dead credentials these tests model.
        # A bare invalid_grant means only that the value was rejected (#530).
        { error: "invalid_grant", error_description: "Refresh token expired" }.to_json
      end
    )
    Net::HTTP.any_instance.stubs(:request).returns(response)
  end

  def coordinator(session = @session)
    AuthRecoveryCoordinator.new(session)
  end

  # A reading that says the account cannot serve: both windows at the cap, both
  # refused, and both resets still ahead.
  def spent_reading_for!(account)
    account.quota_snapshots.create!(
      subscription_type: "claude_max", rate_limit_tier: "tier_4",
      utilization_5h: 1.0, utilization_7d: 1.0,
      status_5h: "rejected", status_7d: "rejected",
      reset_5h: 3.hours.from_now, reset_7d: 5.days.from_now,
      trigger: "rotation"
    )
  end

  # The pool as it looks when quota really is what stopped it: every account
  # labelled quota_exceeded AND carrying a reading that says so.
  #
  # Both halves are load-bearing. A `quota_exceeded` label with a clear reading
  # behind it is exactly the false positive that parked four production sessions
  # on 2026-08-23, and #park_reason_for_pool now reads the reading — so a test
  # that sets only the label is not describing a drained pool.
  def drain_pool_by_quota!(except: nil)
    ClaudeAccount.for_runtime("claude_code").find_each do |account|
      next if except && account.id == except.id

      account.update!(status: :quota_exceeded)
      spent_reading_for!(account)
    end
  end

  # A reading, newer than the account's label, that says it can serve.
  def clear_reading_for!(account)
    account.quota_snapshots.create!(
      subscription_type: "claude_max", rate_limit_tier: "tier_4",
      utilization_5h: 0.35, utilization_7d: 0.12,
      status_5h: "allowed", status_7d: "allowed",
      reset_5h: 26.minutes.from_now, reset_7d: 6.days.from_now,
      trigger: "page_view"
    )
  end

  # Make the live probe report a spent account, so a rotation away from it has
  # the evidence that justifies labelling it quota_exceeded.
  def stub_quota_probe_as_spent
    QuotaCheckService.stubs(:check_with_token).returns(
      QuotaCheckService::Result.new(
        success: true, subscription_type: "claude_max", rate_limit_tier: "tier_4",
        utilization_5h: 1.0, utilization_7d: 1.0, status_5h: "rejected", status_7d: "rejected",
        reset_5h: 3.hours.from_now, reset_7d: 5.days.from_now
      )
    )
  end

  def refused_quota_probe
    QuotaCheckService::Result.new(
      success: false,
      unreachable: false,
      status_code: 401,
      error_message: "No rate-limit headers in response (HTTP 401)"
    )
  end

  def spawned_as!(email)
    @session.update!(metadata: @session.metadata.merge(AuthRecoveryCoordinator::IDENTITY_KEY => email))
  end

  def spawned_with_scoped_token!(account, fingerprint: AuthRecoveryCoordinator.credential_fingerprint(account))
    @session.update!(metadata: @session.metadata.merge(
      AuthRecoveryCoordinator::IDENTITY_KEY => account.email,
      AuthRecoveryCoordinator::CREDENTIAL_FINGERPRINT_KEY => fingerprint
    ))
  end

  # Take the runtime's pool lock on a SEPARATE Postgres backend, which is what a
  # rotation running in another Zimmer process looks like from here.
  #
  # A raw PG connection rather than connection_pool.checkout: under transactional
  # tests Rails pins one connection and hands it to every checkout, and a Postgres
  # advisory lock is re-entrant within a session — so a pooled "second" connection
  # would take the lock happily and prove nothing.
  def hold_pool_lock_elsewhere(runtime = "claude_code")
    config = ClaudeAccount.connection_db_config.configuration_hash
    @foreign_conn = PG.connect(
      host: config[:host], port: config[:port], dbname: config[:database],
      user: config[:username], password: config[:password], sslmode: config[:sslmode] || "prefer"
    )
    @foreign_conn.exec_params(
      "SELECT pg_advisory_lock($1, $2)",
      [ ClaudeAccount::POOL_ADVISORY_LOCK_NAMESPACE, ClaudeAccount.pool_lock_key(runtime) ]
    )
  end

  def release_foreign_pool_lock
    return unless @foreign_conn

    @foreign_conn.exec("SELECT pg_advisory_unlock_all()")
    @foreign_conn.close
    @foreign_conn = nil
  end

  # ===========================================================================
  # Branch 1 — a rotation already moved the pool: adopt it, don't rotate again
  # ===========================================================================

  test "adopts the pool's current account when it differs from the one the process was spawned with" do
    @secondary.mark_current!
    spawned_as!(@primary.email)

    plan = coordinator.resolve!("/tmp/test-clone")

    assert_equal :adopted, plan.outcome
    assert_equal @secondary.email, plan.account.email
    assert_not plan.consumes_budget?,
      "Someone else's rotation is not an attempt this session made"

    assert_equal "active", @secondary.reload.status,
      "Adoption must not mark anything quota_exceeded — nothing was rotated"
    assert_equal "active", @primary.reload.status
    assert_equal 0, AccountRotationEvent.count, "Adoption must not start a rotation"
  end

  test "adoption records the newly adopted identity so the next failure rotates instead" do
    @secondary.mark_current!
    spawned_as!(@primary.email)

    coordinator.resolve!("/tmp/test-clone")

    assert_equal @secondary.email, @session.reload.metadata[AuthRecoveryCoordinator::IDENTITY_KEY]

    # Same account fails again — nothing left to adopt, and the replacement child
    # is holding the token the pool currently has, so re-seeding it would hand
    # over the same value. Rotate.
    spawned_with_scoped_token!(@secondary)
    plan = coordinator(@session.reload).resolve!("/tmp/test-clone")
    assert_equal :rotated, plan.outcome
  end

  # ===========================================================================
  # Branch 2 — Claude Code: repair the process before the pool
  #
  # Every Claude session carries its own access token, so a "Not logged in" can
  # mean the token this process was handed is one refresh behind rather than that
  # the account is finished. Re-seeding is the cheaper repair, and it is tried
  # first. Codex and Pi keep the refresh-then-rotate path below.
  # ===========================================================================

  test "re-seeds a session-scoped process when the DB access token and quota are healthy" do
    spawned_as!(@primary.email)
    token_before = @primary.claude_access_token

    plan = coordinator.resolve!("/tmp/test-clone")

    assert_equal :reseeded, plan.outcome
    assert_equal @primary.email, plan.account.email
    assert plan.consumes_budget?
    assert_equal token_before, @primary.reload.claude_access_token,
      "A readiness probe must not rotate the current account's credential chain"
    assert_equal 0, AccountRotationEvent.count
    assert_equal "auth_recovery", @primary.latest_snapshot.trigger
  end

  test "rotates when the same session-scoped token fails again after being re-seeded" do
    spawned_with_scoped_token!(@primary)

    plan = coordinator.resolve!("/tmp/test-clone")

    assert_equal :rotated, plan.outcome
    assert_equal @secondary.email, plan.account.email
    assert_equal 1, AccountRotationEvent.count,
      "A token the child already retried must not consume the whole recovery budget through repeated reseeds"
  end

  test "re-seeds the only account with quota instead of parking it as unusable" do
    drain_pool_by_quota!(except: @primary)
    @primary.update!(status: :quota_exceeded)
    spawned_as!(@primary.email)

    plan = coordinator.resolve!("/tmp/test-clone")

    assert_equal :reseeded, plan.outcome
    assert_equal @primary.email, plan.account.email
    assert_equal "active", @primary.reload.status,
      "The fresh clear reading must converge the sticky label before account selection"
    assert_equal AuthOutageParkService::AUTH_UNRECOVERABLE, coordinator.park_reason_for_pool,
      "The pool shape still says a human would be needed if recovery parked, but recovery must use the serviceable account"
  end

  test "refreshes a refused session-scoped access token once and re-seeds the repaired account" do
    spawned_as!(@primary.email)
    token_before = @primary.claude_access_token
    healthy = QuotaCheckService::Result.new(
      success: true, subscription_type: "claude_max", rate_limit_tier: "tier_4",
      utilization_5h: 0.5, utilization_7d: 0.3, status_5h: "allowed", status_7d: "allowed",
      reset_5h: 3.hours.from_now, reset_7d: 5.days.from_now
    )
    QuotaCheckService.stubs(:check_with_token).returns(refused_quota_probe, healthy)

    plan = coordinator.resolve!("/tmp/test-clone")

    assert_equal :reseeded, plan.outcome
    assert_not_equal token_before, @primary.reload.claude_access_token
    assert_includes plan.detail, "refreshed the rejected access token"
    assert_equal 0, AccountRotationEvent.count
  end

  test "rotates a session-scoped account only when its live reading says quota is spent" do
    spawned_as!(@primary.email)
    token_before = @primary.claude_access_token
    spent = QuotaCheckService::Result.new(
      success: true, subscription_type: "claude_max", rate_limit_tier: "tier_4",
      utilization_5h: 1.0, utilization_7d: 1.0, status_5h: "rejected", status_7d: "rejected",
      reset_5h: 3.hours.from_now, reset_7d: 5.days.from_now
    )
    healthy = QuotaCheckService::Result.new(
      success: true, subscription_type: "claude_max", rate_limit_tier: "tier_4",
      utilization_5h: 0.2, utilization_7d: 0.3, status_5h: "allowed", status_7d: "allowed",
      reset_5h: 3.hours.from_now, reset_7d: 5.days.from_now
    )
    # Coordinator probe + rotation's outgoing snapshot both see the current
    # account spent; the incoming account's activation snapshot is clear.
    QuotaCheckService.stubs(:check_with_token).returns(spent, spent, healthy)

    plan = coordinator.resolve!("/tmp/test-clone")

    assert_equal :rotated, plan.outcome
    assert_equal token_before, @primary.reload.claude_access_token,
      "Quota evidence must not spend the outgoing account's refresh token"
    assert_equal "quota_exceeded", @primary.status
    assert_equal 1, AccountRotationEvent.count
  end

  test "preserves a spent five-hour probe when rotation's second probe is unreachable" do
    drain_pool_by_quota!(except: @primary)
    spawned_with_scoped_token!(@primary, fingerprint: Digest::SHA256.hexdigest("older-access-token"))

    five_hour_spent = QuotaCheckService::Result.new(
      success: true, subscription_type: "claude_max", rate_limit_tier: "tier_4",
      utilization_5h: 1.0, utilization_7d: 0.4, status_5h: "rejected", status_7d: "allowed",
      reset_5h: 3.hours.from_now, reset_7d: 5.days.from_now
    )
    unreachable = QuotaCheckService::Result.new(
      success: false,
      unreachable: true,
      error_message: "API request timed out"
    )
    QuotaCheckService.stubs(:check_with_token).returns(five_hour_spent, unreachable)

    plan = coordinator.resolve!("/tmp/test-clone")

    assert_equal :quota_exhausted, plan.outcome
    assert_equal "quota_exceeded", @primary.reload.status,
      "The first definitive probe must survive an inconclusive rotation probe"
    assert_equal AuthOutageParkService::QUOTA_EXHAUSTED, coordinator.park_reason_for_pool
  end

  test "does not call a non-active current account re-seeded after an inconclusive probe" do
    @primary.update!(status: :needs_reauth)
    spawned_with_scoped_token!(@primary, fingerprint: Digest::SHA256.hexdigest("older-access-token"))
    unreachable = QuotaCheckService::Result.new(
      success: false,
      unreachable: true,
      error_message: "API request timed out"
    )
    QuotaCheckService.stubs(:check_with_token).returns(unreachable)

    plan = coordinator.resolve!("/tmp/test-clone")

    assert_equal :rotated, plan.outcome
    assert_equal @secondary.email, plan.account.email
    assert_includes plan.detail, @secondary.email
  end

  # ===========================================================================
  # Branch 3 — rotate rather than re-injecting a failure
  # ===========================================================================

  test "rotates away from the identity the runtime rejected instead of re-injecting it" do
    spawned_with_scoped_token!(@primary)

    plan = coordinator.resolve!("/tmp/test-clone")

    assert_equal :rotated, plan.outcome
    assert_not_equal @primary.email, plan.account.email,
      "Re-injecting the account that just failed is the bug this fixes"
    assert plan.consumes_budget?

    # NOT quota_exceeded. The probe in setup reports this account at 50%/30% and
    # allowed on both windows, so nothing observed says its quota is gone — and
    # "Not logged in" says nothing about quota either. Stamping the label anyway
    # is what emptied the production pool on 2026-08-23.
    assert_equal "active", @primary.reload.status
    assert plan.account.reload.is_current?
  end

  # The regression that cost four sessions a ten-hour park. A single blanked
  # credential logged every session on the worker out; each rotated away from the
  # account it held; every rotation stamped `quota_exceeded` on the account it
  # left; and in about forty seconds a pool of healthy accounts read as drained.
  test "an auth rotation across the whole pool leaves every account serviceable" do
    ClaudeAccount.for_runtime("claude_code").where.not(id: @primary.id).update_all(is_current: false)

    3.times do
      session = @session.reload
      spawned_as!(ClaudeAccount.current_account.email)
      AuthRecoveryCoordinator.new(session).resolve!("/tmp/test-clone")
    end

    assert_equal 0, ClaudeAccount.for_runtime("claude_code").quota_exceeded.where.not(id: claude_accounts(:exceeded).id).count,
      "Rotating away from an account is not evidence about its quota"
    assert ClaudeAccount.any_serviceable_for?("claude_code"),
      "A pool of healthy accounts must never read as drained just because sessions rotated through it"
    assert_equal AuthOutageParkService::AUTH_UNRECOVERABLE, coordinator.park_reason_for_pool,
      "With accounts still serviceable, 'wait ten hours for a quota reset' is the wrong story"
  end

  # The other direction: a rotation that DOES have quota evidence still labels the
  # account, so the pool still drains when quota is genuinely what stopped it.
  test "an auth rotation labels the outgoing account when its own reading says the windows are spent" do
    stub_quota_probe_as_spent
    spawned_as!(@primary.email)

    coordinator.resolve!("/tmp/test-clone")

    assert_equal "quota_exceeded", @primary.reload.status
  end

  test "records the rotation as auth_recovery so it is distinguishable from a quota rotation" do
    spawned_with_scoped_token!(@primary)

    coordinator.resolve!("/tmp/test-clone")

    event = AccountRotationEvent.order(:created_at).last
    assert_equal "auth_recovery", event.reason
    assert_equal @primary.id, event.rotated_from_id
    assert_equal "session:#{@session.id}", event.triggered_by
  end

  # A session with no recorded spawn identity predates the marker, so there is no
  # evidence the pool moved AND no fingerprint saying which token generation its
  # child was holding. It gets exactly one re-seed — the cheaper repair, and the
  # replacement records a fingerprint at the spawn seam...
  test "re-seeds once when the session has no recorded spawn identity" do
    plan = coordinator.resolve!("/tmp/test-clone")

    assert_equal :reseeded, plan.outcome
    assert_equal 0, AccountRotationEvent.count
  end

  # ...and when that re-seeded token fails too, the budget stops being spent on
  # the same value and the pool moves instead.
  test "rotates once the child is known to hold the token the pool already has" do
    spawned_with_scoped_token!(@primary)

    plan = coordinator.resolve!("/tmp/test-clone")

    assert_equal :rotated, plan.outcome
  end

  # The status an outgoing account lands in has to say whether waiting can fix
  # it, so a rotation with no quota evidence behind it must NOT label the account
  # quota_exceeded — that makes an unusable pool look recoverable and schedules
  # the retry off a reset that will not help.
  #
  # Recovery deliberately does not refresh the outgoing account to find out
  # WHICH kind of broken it is. A refresh spends a single-use token on a path
  # that does not need one, and doing it per recovery is what produced the
  # cascades of zimmer#672. The five-minute sweep (RefreshRuntimeAuthTokensJob)
  # is what condemns a dead refresh token, and it alerts when it does.
  test "an account recovery could not move past is left unlabelled, not quota_exceeded" do
    spawned_with_scoped_token!(@primary)
    # Every refresh in the pool fails, so there is nothing to rotate into either.
    stub_token_refresh(success: false)

    plan = coordinator.resolve!("/tmp/test-clone")

    assert plan.park?
    assert_equal "active", @primary.reload.status,
      "Nothing observed says this account's quota is gone"
  end

  # ===========================================================================
  # Branch 4 — the pool is out of runway
  # ===========================================================================

  test "parks with quota_exhausted when the last account is rotated away and the rest are over quota" do
    drain_pool_by_quota!(except: @primary)
    # The last account's own probe condemns it too — without that the pool is not
    # drained by quota, it is just labelled that way.
    stub_quota_probe_as_spent
    spawned_as!(@primary.email)

    plan = coordinator.resolve!("/tmp/test-clone")

    assert_equal :quota_exhausted, plan.outcome
    assert plan.park?
    assert_equal AuthOutageParkService::QUOTA_EXHAUSTED, coordinator.park_reason_for_pool
  end

  test "parks with unusable when nothing in the pool is merely throttled" do
    ClaudeAccount.for_runtime("claude_code").update_all(status: ClaudeAccount.statuses[:needs_reauth])
    @primary.reload.update!(status: :active, is_current: true)
    spawned_with_scoped_token!(@primary)
    stub_token_refresh(success: false)

    plan = coordinator.resolve!("/tmp/test-clone")

    assert_equal :unusable, plan.outcome
    assert_equal AuthOutageParkService::AUTH_UNRECOVERABLE, coordinator.park_reason_for_pool
  end

  # The distinction the user actually sees: "wait for reset" vs "go re-authenticate".
  test "park_reason_for_pool prefers AUTH_UNRECOVERABLE while any account is still available" do
    assert ClaudeAccount.for_runtime("claude_code").available.exists?

    assert_equal AuthOutageParkService::AUTH_UNRECOVERABLE, coordinator.park_reason_for_pool,
      "A healthy pool that still rejects us is a credentials problem, not a quota one"
  end

  test "park_reason_for_pool reports QUOTA_EXHAUSTED once the pool is drained by quota" do
    drain_pool_by_quota!

    assert_equal AuthOutageParkService::QUOTA_EXHAUSTED, coordinator.park_reason_for_pool
  end

  # The false positive itself: labels alone are not evidence. Every account is
  # stamped quota_exceeded, and every account's own latest reading says both
  # windows are clear — which is precisely the state the production pool was in at
  # 02:06Z on 2026-08-23, seven minutes before the health check reported three
  # accounts available.
  test "park_reason_for_pool refuses QUOTA_EXHAUSTED when the labels are stale and the readings are clear" do
    ClaudeAccount.for_runtime("claude_code").update_all(status: ClaudeAccount.statuses[:quota_exceeded])
    ClaudeAccount.for_runtime("claude_code").find_each { |account| clear_reading_for!(account) }

    assert_equal AuthOutageParkService::AUTH_UNRECOVERABLE, coordinator.park_reason_for_pool,
      "A pool whose own readings say it can serve must never be called quota-exhausted"
  end

  # ===========================================================================
  # Concurrency — N sessions hitting the wall must not each rotate
  # ===========================================================================

  # Genuine contention, not a stub: the lock is held on a different Postgres
  # backend, exactly as another Zimmer process mid-rotation would hold it. The
  # short wait keeps the test fast; the production 45s value is the same code
  # path with a different number.
  test "a session that finds the pool lock held reports a rotation in flight instead of starting one" do
    hold_pool_lock_elsewhere
    spawned_as!(@primary.email)

    plan = AuthRecoveryCoordinator.new(@session, lock_wait: 0.3).resolve!("/tmp/test-clone")

    assert_equal :rotation_in_flight, plan.outcome
    assert_equal 0, AccountRotationEvent.count,
      "A second rotation would burn the account the first one is activating"
    assert_equal "active", @primary.reload.status
  end

  test "with_pool_lock returns nil rather than blocking when another backend holds the lock" do
    hold_pool_lock_elsewhere

    ran = false
    result = ClaudeAccount.with_pool_lock("claude_code", wait: 0.5) { ran = true }

    assert_nil result
    assert_not ran, "The critical section must not run while another process holds the lock"
  end

  test "with_pool_lock runs and releases so the next caller gets straight in" do
    assert_equal [ :ran ], ClaudeAccount.with_pool_lock("claude_code", wait: 1) { [ :ran ] }
    assert_equal [ :ran_again ], ClaudeAccount.with_pool_lock("claude_code", wait: 1) { [ :ran_again ] }
  end

  test "with_pool_lock releases the lock even when the block raises" do
    assert_raises(RuntimeError) do
      ClaudeAccount.with_pool_lock("claude_code", wait: 1) { raise "boom" }
    end

    assert_equal [ :free ], ClaudeAccount.with_pool_lock("claude_code", wait: 1) { [ :free ] }
  end

  test "different runtimes take different pool locks" do
    assert_not_equal ClaudeAccount.pool_lock_key("claude_code"), ClaudeAccount.pool_lock_key("codex")

    hold_pool_lock_elsewhere("claude_code")
    assert_equal [ :codex_unblocked ], ClaudeAccount.with_pool_lock("codex", wait: 0.5) { [ :codex_unblocked ] },
      "One runtime's rotation must not block another runtime's pool"
  end

  # Two sessions hit the wall on the same account. The first rotates; the second,
  # arriving after it, finds the pool already moved and adopts rather than
  # rotating again. Sequential by construction — the mutual exclusion itself is
  # covered by the cross-backend lock tests above; this covers what the second
  # racer decides once it gets in.
  test "two sessions on the same failed account produce exactly one rotation" do
    second_session = Session.create!(
      prompt: "Second", agent_runtime: "claude_code", status: :running,
      git_root: "https://github.com/test/repo.git", branch: "main", session_id: SecureRandom.uuid,
      metadata: {
        "clone_path" => "/tmp/other-clone",
        AuthRecoveryCoordinator::IDENTITY_KEY => @primary.email,
        AuthRecoveryCoordinator::CREDENTIAL_FINGERPRINT_KEY =>
          AuthRecoveryCoordinator.credential_fingerprint(@primary)
      }
    )
    spawned_with_scoped_token!(@primary)

    first = coordinator.resolve!("/tmp/test-clone")
    second = coordinator(second_session).resolve!("/tmp/other-clone")

    assert_equal :rotated, first.outcome
    assert_equal :adopted, second.outcome
    assert_equal first.account.email, second.account.email
    assert_equal 1, AccountRotationEvent.count,
      "Two sessions, one rotation — the pool must not be drained by concurrent recoveries"
  end

  # ===========================================================================
  # Rotation serialization (#242) — the quota path shares this lock
  # ===========================================================================

  # A quota stampede used to have N sessions read the same `current`, pick the
  # same successor, and each call refresh_token! on it. Anthropic's refresh
  # tokens are single-use, so the losers got invalid_grant and condemned a
  # healthy account to needs_reauth. Collapsing is what stops the stampede from
  # burning one account per racer.
  test "a rotation whose expected account is no longer current collapses instead of rotating again" do
    @secondary.mark_current!

    result = AccountRotationService.new.rotate!(
      reason: "quota_exceeded",
      triggered_by: "session:1",
      expected_current_email: @primary.email
    )

    assert result[:success]
    assert result[:collapsed]
    assert_equal @secondary.email, result[:account].email
    assert_equal "active", @secondary.reload.status,
      "The account another session just rotated to must not be burned by the racer behind it"
    assert_equal 0, AccountRotationEvent.count
  end

  test "a rotation still on its expected account rotates normally" do
    result = AccountRotationService.new.rotate!(
      reason: "quota_exceeded",
      triggered_by: "session:1",
      expected_current_email: @primary.email
    )

    assert result[:success]
    assert_nil result[:collapsed]
    assert_equal "quota_exceeded", @primary.reload.status
    assert_equal 1, AccountRotationEvent.count
  end

  # The collapse must be gated on recency, not just on inequality. A caller's
  # recorded identity goes stale whenever the pool moves without telling it, so a
  # long-running session that has since been using account B would otherwise
  # collapse on its own genuine complaint about B and be re-spawned onto it.
  test "a rotation onto the current account long ago does not collapse a later genuine complaint" do
    @secondary.mark_current!
    @secondary.update!(last_rotated_to_at: (AccountRotationService::COLLAPSE_WINDOW + 5.minutes).ago)

    result = AccountRotationService.new.rotate!(
      reason: "quota_exceeded",
      triggered_by: "session:1",
      expected_current_email: @primary.email
    )

    assert result[:success]
    assert_nil result[:collapsed], "A rotation this old is the account the caller has been using, not a stampede"
    assert_equal "quota_exceeded", @secondary.reload.status,
      "The genuine complaint must actually move the pool"
  end

  test "rotate! reports rotation_in_flight rather than racing a rotation another process holds" do
    hold_pool_lock_elsewhere

    result = AccountRotationService.new.rotate!(reason: "quota_exceeded", triggered_by: "session:1")

    assert_not result[:success]
    assert_equal "rotation_in_flight", result[:reason]
    assert_equal "active", @primary.reload.status,
      "A rotation that never ran must not have marked anything"
  end

  # A lost lock race means the holder is mid-rotation and about to write good
  # credentials. Parking the loser as quota-exhausted would be wrong twice over:
  # the pool is fine, and the retry would be scheduled off a quota reset.
  test "a rotation that loses the lock race resolves as rotation_in_flight, not a park" do
    spawned_with_scoped_token!(@primary)
    AccountRotationService.any_instance.stubs(:rotate!)
      .returns({ success: false, reason: "rotation_in_flight" })

    plan = coordinator.resolve!("/tmp/test-clone")

    assert_equal :rotation_in_flight, plan.outcome
    assert_not plan.park?, "The pool is healthy — this session must not be parked"
  end

  # inject swallows filesystem/IO failures into nil. When the pool is healthy,
  # that is a disk problem, and the park detail must not read as "your accounts
  # are dead" — the whole point of this PR is that the message matches the cause.
  test "an injection failure over a healthy pool parks with a detail naming the real cause" do
    @secondary.mark_current!
    spawned_as!(@primary.email)
    AccountRotationService.any_instance.stubs(:ensure_active_account!).raises(Errno::EACCES, "disk")

    plan = coordinator.resolve!("/tmp/test-clone")

    assert_equal :unusable, plan.outcome
    assert_match(/could not be written to disk/, plan.detail)
  end

  # The coordinator holds the pool lock and then calls through to rotate!, which
  # takes it again. Postgres advisory locks are re-entrant by count, so this must
  # work — and must still release cleanly.
  test "the coordinator's rotation nests inside its own pool lock without deadlocking" do
    spawned_with_scoped_token!(@primary)

    plan = coordinator.resolve!("/tmp/test-clone")

    assert_equal :rotated, plan.outcome
    assert_equal [ :free_after ], ClaudeAccount.with_pool_lock("claude_code", wait: 1) { [ :free_after ] },
      "Nested acquire/release must leave the lock fully released"
  end

  # ===========================================================================
  # Identity recording
  # ===========================================================================

  test "record_identity! stores the email the process was spawned with" do
    AuthRecoveryCoordinator.record_identity!(@session, @primary)

    assert_equal @primary.email, @session.reload.metadata[AuthRecoveryCoordinator::IDENTITY_KEY]
    assert_not_nil @session.metadata[AuthRecoveryCoordinator::IDENTITY_AT_KEY]
  end

  test "record_spawn_credentials! stores a one-way fingerprint of the token handed over" do
    AuthRecoveryCoordinator.record_spawn_credentials!(session_id: @session.id, account: @primary)

    metadata = @session.reload.metadata
    assert_equal @primary.email, metadata[AuthRecoveryCoordinator::IDENTITY_KEY]
    assert_equal Digest::SHA256.hexdigest(@primary.claude_access_token),
      metadata[AuthRecoveryCoordinator::CREDENTIAL_FINGERPRINT_KEY]
    assert_not_equal @primary.claude_access_token,
      metadata[AuthRecoveryCoordinator::CREDENTIAL_FINGERPRINT_KEY]
  end

  test "record_identity! is a no-op for the boot warm-up path, which has no session" do
    assert_nothing_raised { AuthRecoveryCoordinator.record_identity!(nil, @primary) }
  end

  test "record_identity! is a no-op when no account was injected" do
    AuthRecoveryCoordinator.record_identity!(@session, nil)

    assert_nil @session.reload.metadata[AuthRecoveryCoordinator::IDENTITY_KEY]
  end
end
