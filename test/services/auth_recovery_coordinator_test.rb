# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Exercises the decision tree that used to not exist: before this, an auth
# recovery re-injected the CURRENT account unconditionally, so a session whose
# account was itself the problem re-spawned into the identical "Not logged in"
# wall up to three times and then parked with the wrong reason.
class AuthRecoveryCoordinatorTest < ActiveSupport::TestCase
  setup do
    @tmpdir = Dir.mktmpdir
    @original_claude_json = ClaudeAuthProvider::CLAUDE_JSON_PATH
    @original_credentials_json = ClaudeAuthProvider::CREDENTIALS_JSON_PATH

    ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
    ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, File.join(@tmpdir, "claude.json"))
    ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
    ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, File.join(@tmpdir, ".credentials.json"))

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
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      metadata: { "clone_path" => "/tmp/test-clone", "working_directory" => "/tmp/test-clone" }
    )
  end

  teardown do
    release_foreign_pool_lock
    FileUtils.rm_rf(@tmpdir)
    ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
    ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, @original_claude_json)
    ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
    ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, @original_credentials_json)
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
        { error: "invalid_grant" }.to_json
      end
    )
    Net::HTTP.any_instance.stubs(:request).returns(response)
  end

  def coordinator(session = @session)
    AuthRecoveryCoordinator.new(session)
  end

  def spawned_as!(email)
    @session.update!(metadata: @session.metadata.merge(AuthRecoveryCoordinator::IDENTITY_KEY => email))
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

    # Same account fails again — now there is nothing to adopt, so it rotates.
    plan = coordinator(@session.reload).resolve!("/tmp/test-clone")
    assert_equal :rotated, plan.outcome
  end

  # ===========================================================================
  # Branch 2 — nobody rotated: rotate, rather than re-injecting what just failed
  # ===========================================================================

  test "rotates away from the identity the runtime rejected instead of re-injecting it" do
    spawned_as!(@primary.email)

    plan = coordinator.resolve!("/tmp/test-clone")

    assert_equal :rotated, plan.outcome
    assert_not_equal @primary.email, plan.account.email,
      "Re-injecting the account that just failed is the bug this fixes"
    assert plan.consumes_budget?

    assert_equal "quota_exceeded", @primary.reload.status
    assert plan.account.reload.is_current?
  end

  test "records the rotation as auth_recovery so it is distinguishable from a quota rotation" do
    spawned_as!(@primary.email)

    coordinator.resolve!("/tmp/test-clone")

    event = AccountRotationEvent.order(:created_at).last
    assert_equal "auth_recovery", event.reason
    assert_equal @primary.id, event.rotated_from_id
    assert_equal "session:#{@session.id}", event.triggered_by
  end

  # With no recorded spawn identity (a session that predates the marker) there is
  # no evidence the pool moved, so the corrective branch is the right default.
  test "rotates when the session has no recorded spawn identity" do
    plan = coordinator.resolve!("/tmp/test-clone")

    assert_equal :rotated, plan.outcome
  end

  # The outgoing account is probed before it is parked so the status it lands in
  # says whether waiting can fix it. A dead refresh token cannot be fixed by a
  # quota reset, so it must NOT be labelled quota_exceeded.
  test "an outgoing account with a permanently invalid token is marked needs_reauth, not quota_exceeded" do
    spawned_as!(@primary.email)
    stub_token_refresh(success: false)

    coordinator.resolve!("/tmp/test-clone")

    assert_equal "needs_reauth", @primary.reload.status,
      "Relabelling a dead credential as merely throttled makes an unusable pool look recoverable"
  end

  # ===========================================================================
  # Branch 3 — the pool is out of runway
  # ===========================================================================

  test "parks with quota_exhausted when the last account is rotated away and the rest are over quota" do
    ClaudeAccount.for_runtime("claude_code").where.not(id: @primary.id).update_all(status: ClaudeAccount.statuses[:quota_exceeded])
    spawned_as!(@primary.email)

    plan = coordinator.resolve!("/tmp/test-clone")

    assert_equal :quota_exhausted, plan.outcome
    assert plan.park?
    assert_equal AuthOutageParkService::QUOTA_EXHAUSTED, coordinator.park_reason_for_pool
  end

  test "parks with unusable when nothing in the pool is merely throttled" do
    ClaudeAccount.for_runtime("claude_code").update_all(status: ClaudeAccount.statuses[:needs_reauth])
    @primary.reload.update!(status: :active, is_current: true)
    spawned_as!(@primary.email)
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
    ClaudeAccount.for_runtime("claude_code").update_all(status: ClaudeAccount.statuses[:quota_exceeded])

    assert_equal AuthOutageParkService::QUOTA_EXHAUSTED, coordinator.park_reason_for_pool
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

  # The end-to-end concurrency case: two sessions hit the wall on the same
  # account. The first rotates; the second, arriving after it, finds the pool
  # already moved and adopts rather than rotating again.
  test "two sessions on the same failed account produce exactly one rotation" do
    second_session = Session.create!(
      prompt: "Second", agent_runtime: "claude_code", status: :running,
      git_root: "https://github.com/test/repo.git", branch: "main",
      execution_provider: "local_filesystem", session_id: SecureRandom.uuid,
      metadata: {
        "clone_path" => "/tmp/other-clone",
        AuthRecoveryCoordinator::IDENTITY_KEY => @primary.email
      }
    )
    spawned_as!(@primary.email)

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
    assert_not result[:collapsed]
    assert_equal "quota_exceeded", @primary.reload.status
    assert_equal 1, AccountRotationEvent.count
  end

  test "rotate! reports rotation_in_flight rather than racing a rotation another process holds" do
    hold_pool_lock_elsewhere

    result = AccountRotationService.new.rotate!(reason: "quota_exceeded", triggered_by: "session:1")

    assert_not result[:success]
    assert_equal "rotation_in_flight", result[:reason]
    assert_equal "active", @primary.reload.status,
      "A rotation that never ran must not have marked anything"
  end

  # The coordinator holds the pool lock and then calls through to rotate!, which
  # takes it again. Postgres advisory locks are re-entrant by count, so this must
  # work — and must still release cleanly.
  test "the coordinator's rotation nests inside its own pool lock without deadlocking" do
    spawned_as!(@primary.email)

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

  test "record_identity! is a no-op for the boot warm-up path, which has no session" do
    assert_nothing_raised { AuthRecoveryCoordinator.record_identity!(nil, @primary) }
  end

  test "record_identity! is a no-op when no account was injected" do
    AuthRecoveryCoordinator.record_identity!(@session, nil)

    assert_nil @session.reload.metadata[AuthRecoveryCoordinator::IDENTITY_KEY]
  end
end
