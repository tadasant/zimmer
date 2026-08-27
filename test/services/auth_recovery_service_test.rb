require "test_helper"
require "automated_prompts"

class AuthRecoveryServiceTest < ActiveSupport::TestCase
  # Minimal fake account — the service only reads #email for logging.
  FakeAccount = Struct.new(:email)

  # Fake coordinator standing in for AuthRecoveryCoordinator. The coordinator's
  # own decision tree (adopt / rotate / wait / park) is exercised against a real
  # account pool in AuthRecoveryCoordinatorTest; here it is stubbed so these tests
  # stay about what AuthRecoveryService owns — the attempt budget, the log line,
  # the re-spawn, and the mapping from plan to return value.
  class FakeCoordinator
    attr_reader :calls

    def initialize(plan)
      @plan = plan
      @calls = []
    end

    def resolve!(working_directory)
      @calls << working_directory
      @plan
    end
  end

  def plan(outcome, email: "rotated@example.com", detail: "rotated from old@example.com to #{email}")
    AuthRecoveryCoordinator::Plan.new(
      outcome: outcome,
      account: email ? FakeAccount.new(email) : nil,
      detail: detail
    )
  end

  setup do
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

    @mock_process_manager = MockProcessManager.new
    @mock_cli_adapter = MockClaudeCliAdapter.new
    @mock_file_system = MockFileSystemAdapter.new
    @log_buffer = LogBuffer.new(@session)
    @account = FakeAccount.new("rotated@example.com")
  end

  def create_service(coordinator: nil)
    AuthRecoveryService.new(
      @session,
      cli_adapter: @mock_cli_adapter,
      process_manager: @mock_process_manager,
      log_buffer: @log_buffer,
      file_system: @mock_file_system,
      coordinator: coordinator || FakeCoordinator.new(plan(:rotated))
    )
  end

  def setup_transcript_directory
    require "path_sanitizer"
    home_dir = File.expand_path("~")
    sanitized_path = PathSanitizer.sanitize("/tmp/test-clone")
    @transcript_dir = File.join(home_dir, ".claude", "projects", sanitized_path)
    @transcript_file = File.join(@transcript_dir, "#{@session.session_id}.jsonl")
    @mock_file_system.mkdir_p(@transcript_dir)
  end

  def api_error_json(message, error_type: "api_error")
    JSON.generate({
      "type" => "assistant",
      "isApiErrorMessage" => true,
      "error" => error_type,
      "message" => {
        "model" => "<synthetic>",
        "content" => [ { "type" => "text", "text" => message } ]
      }
    })
  end

  # The real rotation-induced signature, recorded exactly as Claude Code writes it.
  def auth_error_json(message = "Not logged in · Please run /login")
    api_error_json(message, error_type: "")
  end

  def setup_transcript_with_auth_error(message = "Not logged in · Please run /login")
    setup_transcript_directory
    transcript_content = <<~JSONL
      {"type": "user", "message": {"content": [{"type": "text", "text": "Hello"}]}}
      {"type": "assistant", "message": {"content": [{"type": "text", "text": "Hi there!"}]}}
      #{auth_error_json(message)}
    JSONL
    @mock_file_system.write(@transcript_file, transcript_content)
  end

  # ===========================================================================
  # Detection Tests
  # ===========================================================================

  test "detects 'Not logged in · Please run /login' as a recoverable auth error" do
    setup_transcript_with_auth_error("Not logged in · Please run /login")

    service = create_service
    assert service.auth_error_detected?("/tmp/test-clone")
  end

  test "detects the 'Please run /login' half of the signature on its own" do
    setup_transcript_with_auth_error("Authentication required. Please run /login to continue.")

    service = create_service
    assert service.auth_error_detected?("/tmp/test-clone")
  end

  test "detects the 'Not logged in' half of the signature on its own" do
    setup_transcript_with_auth_error("Not logged in")

    service = create_service
    assert service.auth_error_detected?("/tmp/test-clone")
  end

  test "does not detect a transient server error as an auth error" do
    setup_transcript_with_auth_error("500 Internal Server Error")

    service = create_service
    assert_not service.auth_error_detected?("/tmp/test-clone")
  end

  test "does not detect regular assistant messages as auth errors" do
    setup_transcript_directory
    @mock_file_system.write(@transcript_file, <<~JSONL)
      {"type": "user", "message": {"content": [{"type": "text", "text": "Hello"}]}}
      {"type": "assistant", "message": {"content": [{"type": "text", "text": "Please run /login is just text, not an error"}]}}
    JSONL

    service = create_service
    assert_not service.auth_error_detected?("/tmp/test-clone"),
      "Non-API-error message mentioning /login must not be treated as an auth failure"
  end

  # Most-recent-error-wins: an older auth error followed by a newer 500 must NOT
  # be classified as an auth failure (the 500 is the operative current error,
  # handled by ApiErrorRetryService).
  test "does not detect auth error when a newer API error shadows it" do
    setup_transcript_directory
    @mock_file_system.write(@transcript_file, <<~JSONL)
      {"type": "user", "message": {"content": [{"type": "text", "text": "Hello"}]}}
      #{auth_error_json("Not logged in · Please run /login")}
      #{api_error_json("500 Internal Server Error", error_type: "api_error")}
    JSONL

    service = create_service
    assert_not service.auth_error_detected?("/tmp/test-clone"),
      "When the most recent API error is a 500, auth recovery must not fire"
  end

  # The mirror case: an older 500 followed by a newer auth error IS an auth failure.
  test "detects auth error when it is the most recent API error" do
    setup_transcript_directory
    @mock_file_system.write(@transcript_file, <<~JSONL)
      {"type": "user", "message": {"content": [{"type": "text", "text": "Hello"}]}}
      #{api_error_json("500 Internal Server Error", error_type: "api_error")}
      #{auth_error_json("Not logged in · Please run /login")}
    JSONL

    service = create_service
    assert service.auth_error_detected?("/tmp/test-clone"),
      "When the most recent API error is 'Not logged in', auth recovery must fire"
  end

  # === The 2026-08-20 incident (production session 6412) ===
  #
  # Claude Code 2.1.237 records a dead OAuth session as an API error with a
  # MACHINE-READABLE type and prose that the old /not logged in|please run
  # \/login/i pattern never matched. Nothing classified it, so the turn was
  # parked as `needs_input` with a human's message unanswered.
  test "detects a dead OAuth session recorded with the authentication_failed error type" do
    setup_transcript_directory
    @mock_file_system.write(@transcript_file, <<~JSONL)
      {"type": "user", "message": {"content": [{"type": "text", "text": "Hello"}]}}
      #{api_error_json("Failed to authenticate: OAuth session expired and could not be refreshed", error_type: "authentication_failed")}
    JSONL

    service = create_service
    assert service.auth_error_detected?("/tmp/test-clone"),
      "The exact entry that silently ended production session 6412 must route to auth recovery"
  end

  # The error type alone is enough — the prose is the half that moves.
  test "detects an authentication_failed entry whose prose Zimmer has never seen" do
    setup_transcript_directory
    @mock_file_system.write(@transcript_file, <<~JSONL)
      {"type": "user", "message": {"content": [{"type": "text", "text": "Hello"}]}}
      #{api_error_json("Some wording nobody has written yet", error_type: "authentication_failed")}
    JSONL

    service = create_service
    assert service.auth_error_detected?("/tmp/test-clone"),
      "The structured error type must classify the failure even when the message text is unrecognizable"
  end

  # ...and so is the prose, for the entries the runtime records with an empty type.
  test "detects 'Failed to authenticate' prose on an entry with no error type" do
    setup_transcript_with_auth_error("Failed to authenticate: OAuth session expired and could not be refreshed")

    service = create_service
    assert service.auth_error_detected?("/tmp/test-clone")
  end

  test "skips already-checked lines using auth_error_last_checked_line" do
    setup_transcript_with_auth_error

    @session.update!(metadata: @session.metadata.merge("auth_error_last_checked_line" => 10))

    service = create_service
    assert_not service.auth_error_detected?("/tmp/test-clone"),
      "Should not re-detect an already-handled auth error"
  end

  test "returns false when transcript directory does not exist" do
    service = create_service
    assert_not service.auth_error_detected?("/tmp/test-clone")
  end

  test "returns false when working_directory is nil" do
    service = create_service
    assert_not service.auth_error_detected?(nil)
  end

  # ===========================================================================
  # Recovery Logic Tests
  # ===========================================================================

  test "returns :not_applicable when no auth error detected" do
    setup_transcript_directory
    @mock_file_system.write(@transcript_file, <<~JSONL)
      {"type": "user", "message": {"content": [{"type": "text", "text": "Hello"}]}}
    JSONL

    service = create_service
    assert_equal :not_applicable, service.attempt_recovery("/tmp/test-clone")
  end

  test "resolves the identity against the pool then resumes and returns :success when process stays running" do
    setup_transcript_with_auth_error

    @mock_cli_adapter.resume_hook = ->(_opts) { { pid: 4242, stderr_log_path: "/tmp/stderr.log" } }
    @mock_process_manager.running_hook = ->(_pid) { true }

    coordinator = FakeCoordinator.new(plan(:rotated))
    service = create_service(coordinator: coordinator)
    service.define_singleton_method(:sleep) { |_| }

    result = service.attempt_recovery("/tmp/test-clone")

    assert_equal :success, result

    # The pool was consulted for this working directory BEFORE re-spawn.
    assert_equal [ "/tmp/test-clone" ], coordinator.calls

    # The session was re-spawned and the new PID recorded.
    assert_equal 1, @mock_cli_adapter.resumed_sessions.length
    @session.reload
    assert_equal 4242, @session.metadata["process_pid"]

    # The attempt is COUNTED even though the re-spawned process is still alive:
    # surviving SUCCESS_THRESHOLD only means the process started, not that the
    # auth error is gone. Aging the counter out by CONSECUTIVE_WINDOW (rather
    # than resetting it here) is what bounds a re-spawn loop.
    assert_equal 1, @session.metadata["auth_recovery_count"]
    assert_not_nil @session.metadata["last_auth_recovery_at"]
    assert @session.metadata["auth_error_last_checked_line"].to_i > 0,
      "Should advance the auth line marker so the same entry isn't re-detected"
  end

  test "resumes with the SYSTEM_RECOVERY prompt and the orchestrator system prompt" do
    setup_transcript_with_auth_error

    captured = {}
    @mock_cli_adapter.resume_hook = ->(opts) do
      captured = opts
      { pid: 4242, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(_pid) { true }

    service = create_service
    service.define_singleton_method(:sleep) { |_| }

    service.attempt_recovery("/tmp/test-clone")

    assert_equal AutomatedPrompts::SYSTEM_RECOVERY, captured[:prompt]
    assert_not_nil captured[:append_system_prompt]
    assert_includes captured[:append_system_prompt], "Session ID: #{@session.id}"
  end

  # No account in the pool has usable credentials — no reset will fix that, only
  # a human. Fail cleanly WITHOUT re-spawning and WITHOUT looping.
  test "returns :unrecoverable without spawning when the pool has no usable credentials" do
    setup_transcript_with_auth_error

    coordinator = FakeCoordinator.new(plan(:unusable, email: nil, detail: "no usable credentials"))
    service = create_service(coordinator: coordinator)
    service.define_singleton_method(:sleep) { |_| }

    result = service.attempt_recovery("/tmp/test-clone")

    assert_equal :unrecoverable, result
    assert_equal 1, coordinator.calls.size, "Should consult the pool exactly once"
    assert_equal 0, @mock_cli_adapter.resumed_sessions.length,
      "Must NOT spawn a process when there is no account to recover to"

    # Marker advanced so a later manual resume doesn't re-detect and loop, but the
    # retry counter was never incremented (we never actually retried).
    @session.reload
    assert @session.metadata["auth_error_last_checked_line"].to_i > 0
    assert_nil @session.metadata["auth_recovery_count"]
  end

  # Branch 3 of the fix: when the pool is drained by quota, the FIRST "Not logged
  # in" goes straight to the over-quota failure mode. Before this the session
  # re-spawned into the same wall three times and then parked with
  # AUTH_UNRECOVERABLE, telling the user to re-authenticate when the actual fix
  # was to wait.
  test "returns :pool_quota_exhausted on the first failure when every account is over quota" do
    setup_transcript_with_auth_error

    coordinator = FakeCoordinator.new(plan(:quota_exhausted, email: nil, detail: "all over quota"))
    service = create_service(coordinator: coordinator)
    service.define_singleton_method(:sleep) { |_| }

    result = service.attempt_recovery("/tmp/test-clone")

    assert_equal :pool_quota_exhausted, result
    assert_equal 0, @mock_cli_adapter.resumed_sessions.length,
      "Must not re-spawn into a wall that only a quota reset can clear"

    @session.reload
    assert @session.metadata["auth_error_last_checked_line"].to_i > 0
    assert_nil @session.metadata["auth_recovery_count"],
      "Parking on a drained pool is not a retry and must not spend budget"

    assert_includes @session.logs.pluck(:content).join(" "), "over its quota"
  end

  test "returns :exhausted when recovery count already at maximum" do
    setup_transcript_with_auth_error
    @session.update!(metadata: @session.metadata.merge("auth_recovery_count" => AuthRecoveryService::MAX_RECOVERY_ATTEMPTS))

    service = create_service
    service.define_singleton_method(:sleep) { |_| }

    result = service.attempt_recovery("/tmp/test-clone")

    assert_equal :exhausted, result
    assert_equal 0, @mock_cli_adapter.resumed_sessions.length,
      "Should not spawn once the consecutive-failure cap is reached"
  end

  test "returns :exhausted after MAX_RECOVERY_ATTEMPTS when the process keeps dying" do
    setup_transcript_with_auth_error

    spawn_count = 0
    @mock_cli_adapter.resume_hook = ->(_opts) do
      spawn_count += 1
      { pid: 5000 + spawn_count, stderr_log_path: "/tmp/stderr.log" }
    end
    # Process always dies during verification.
    @mock_process_manager.running_hook = ->(_pid) { false }

    service = create_service
    service.define_singleton_method(:sleep) { |_| }

    result = service.attempt_recovery("/tmp/test-clone")

    assert_equal :exhausted, result
    assert_equal AuthRecoveryService::MAX_RECOVERY_ATTEMPTS, spawn_count,
      "Should make exactly MAX_RECOVERY_ATTEMPTS spawn attempts before giving up"
  end

  test "recovers on a later attempt when an early re-spawn dies" do
    setup_transcript_with_auth_error

    spawn_count = 0
    @mock_cli_adapter.resume_hook = ->(_opts) do
      spawn_count += 1
      { pid: 6000 + spawn_count, stderr_log_path: "/tmp/stderr.log" }
    end
    # First spawn dies, second stays running.
    @mock_process_manager.running_hook = ->(pid) { pid == 6002 }

    service = create_service
    service.define_singleton_method(:sleep) { |_| }

    result = service.attempt_recovery("/tmp/test-clone")

    assert_equal :success, result
    assert_equal 2, spawn_count
    @session.reload
    assert_equal 2, @session.metadata["auth_recovery_count"],
      "Both attempts count toward the budget — only elapsed time clears it"
  end

  test "returns :aborted when session state changes during the settle delay" do
    setup_transcript_with_auth_error

    service = create_service
    service.define_singleton_method(:sleep) do |_duration|
      @session.update!(status: :needs_input)
    end

    result = service.attempt_recovery("/tmp/test-clone")

    assert_equal :aborted, result
    assert_equal 0, @mock_cli_adapter.resumed_sessions.length
  end

  # ===========================================================================
  # Constants / metadata-lifecycle Tests
  # ===========================================================================

  test "uses correct constants" do
    assert_equal 3, AuthRecoveryService::MAX_RECOVERY_ATTEMPTS
    assert_equal 3, AuthRecoveryService::MAX_FREE_ADOPTIONS
    assert_equal 5, AuthRecoveryService::SUCCESS_THRESHOLD
    assert_equal 2, AuthRecoveryService::RETRY_DELAY
    assert_equal 15.minutes, AuthRecoveryService::CONSECUTIVE_WINDOW
  end

  # ===========================================================================
  # Adoption budget — waiting on someone else's rotation is free
  # ===========================================================================

  test "adopting another session's rotation does not spend the recovery budget" do
    setup_transcript_with_auth_error

    @mock_cli_adapter.resume_hook = ->(_opts) { { pid: 4242, stderr_log_path: "/tmp/stderr.log" } }
    @mock_process_manager.running_hook = ->(_pid) { true }

    service = create_service(coordinator: FakeCoordinator.new(
      plan(:adopted, email: "someone-elses-rotation@example.com", detail: "pool already rotated")
    ))
    service.define_singleton_method(:sleep) { |_| }

    assert_equal :success, service.attempt_recovery("/tmp/test-clone")

    @session.reload
    assert_nil @session.metadata["auth_recovery_count"],
      "An adoption is another session's rotation doing this one a favour — not an attempt it made"
    assert_equal 1, @session.metadata["auth_recovery_adoptions"]
    assert_includes @session.logs.pluck(:content).join(" "), "no attempt charged"
  end

  test "re-seeding a healthy current account spends budget and names the repair" do
    setup_transcript_with_auth_error

    @mock_cli_adapter.resume_hook = ->(_opts) { { pid: 4242, stderr_log_path: "/tmp/stderr.log" } }
    @mock_process_manager.running_hook = ->(_pid) { true }
    detail = "proved current@example.com still has a valid access token and quota, then re-seeded it"
    service = create_service(coordinator: FakeCoordinator.new(
      plan(:reseeded, email: "current@example.com", detail: detail)
    ))
    service.define_singleton_method(:sleep) { |_| }

    assert_equal :success, service.attempt_recovery("/tmp/test-clone")

    @session.reload
    assert_equal 1, @session.metadata["auth_recovery_count"]
    logs = @session.logs.pluck(:content).join(" ")
    assert_includes logs, detail
    assert_includes logs, "Retrying 1/3"
  end

  test "adoptions beyond MAX_FREE_ADOPTIONS start spending the recovery budget" do
    setup_transcript_with_auth_error

    @session.update!(metadata: @session.metadata.merge(
      "auth_recovery_adoptions" => AuthRecoveryService::MAX_FREE_ADOPTIONS,
      "last_auth_adoption_at" => 1.minute.ago.iso8601
    ))
    @mock_cli_adapter.resume_hook = ->(_opts) { { pid: 4242, stderr_log_path: "/tmp/stderr.log" } }
    @mock_process_manager.running_hook = ->(_pid) { true }

    service = create_service(coordinator: FakeCoordinator.new(plan(:adopted)))
    service.define_singleton_method(:sleep) { |_| }

    assert_equal :success, service.attempt_recovery("/tmp/test-clone")

    @session.reload
    assert_equal 1, @session.metadata["auth_recovery_count"],
      "Free adoptions that never converge must stop being free, or the loop is unbounded"
  end

  test "an adoption older than CONSECUTIVE_WINDOW starts a fresh free-adoption budget" do
    setup_transcript_with_auth_error

    @session.update!(metadata: @session.metadata.merge(
      "auth_recovery_adoptions" => AuthRecoveryService::MAX_FREE_ADOPTIONS,
      "last_auth_adoption_at" => (AuthRecoveryService::CONSECUTIVE_WINDOW + 1.minute).ago.iso8601
    ))
    @mock_cli_adapter.resume_hook = ->(_opts) { { pid: 4242, stderr_log_path: "/tmp/stderr.log" } }
    @mock_process_manager.running_hook = ->(_pid) { true }

    service = create_service(coordinator: FakeCoordinator.new(plan(:adopted)))
    service.define_singleton_method(:sleep) { |_| }

    assert_equal :success, service.attempt_recovery("/tmp/test-clone")

    @session.reload
    assert_nil @session.metadata["auth_recovery_count"]
    assert_equal 1, @session.metadata["auth_recovery_adoptions"]
  end

  # A rotation in flight belongs to another process. Starting a second one would
  # burn the account that rotation is activating, so the session waits — but the
  # wait IS charged, because unlike an adoption nothing has been shown to change.
  test "waiting on a rotation in flight spends the budget" do
    setup_transcript_with_auth_error

    @mock_cli_adapter.resume_hook = ->(_opts) { { pid: 4242, stderr_log_path: "/tmp/stderr.log" } }
    @mock_process_manager.running_hook = ->(_pid) { true }

    service = create_service(coordinator: FakeCoordinator.new(
      plan(:rotation_in_flight, email: nil, detail: "another rotation is running")
    ))
    service.define_singleton_method(:sleep) { |_| }

    assert_equal :success, service.attempt_recovery("/tmp/test-clone")

    @session.reload
    assert_equal 1, @session.metadata["auth_recovery_count"]
    assert_includes @session.logs.pluck(:content).join(" "), "still in flight"
  end

  test "the adoption budget is cleared on resume alongside the retry budget" do
    assert_includes Session::STALE_RETRY_METADATA_KEYS, "auth_recovery_adoptions"
    assert_includes Session::STALE_RETRY_METADATA_KEYS, "last_auth_adoption_at"
  end

  test "auth_identity_email survives resume so an adoption stays distinguishable" do
    assert_not_includes Session::STALE_RETRY_METADATA_KEYS, AuthRecoveryCoordinator::IDENTITY_KEY,
      "Clearing the spawn identity would make every recovery look like a rotation"
  end

  # ===========================================================================
  # Re-spawn loop bound (regression: production session 684)
  # ===========================================================================

  # The exact shape of the incident: every re-spawned process clears the
  # 5-second liveness bar (a real Claude Code process spends its first 10-15
  # seconds connecting MCP servers), then reports the same auth error and exits.
  # The old code read that liveness as recovery success and reset
  # auth_recovery_count to 0, so the counter oscillated 0 → 1 → 0 and the cap was
  # unreachable — the CLI was re-spawned 115 times over 35 minutes, all logged as
  # "retrying 1/3".
  test "consecutive re-spawns that stay alive still exhaust the attempt budget" do
    setup_transcript_with_auth_error

    spawn_count = 0
    @mock_cli_adapter.resume_hook = ->(_opts) do
      spawn_count += 1
      { pid: 7000 + spawn_count, stderr_log_path: "/tmp/stderr.log" }
    end
    # Every spawned process stays alive past SUCCESS_THRESHOLD, exactly as the
    # real CLI does while its MCP servers connect.
    @mock_process_manager.running_hook = ->(_pid) { true }

    # Drive the loop the way ProcessLifecycleManager does: each :success means
    # "monitoring continues", the re-spawned process appends a FRESH auth error
    # to the transcript, and the next exit routes straight back here.
    results = []
    4.times do
      @mock_file_system.write(
        @transcript_file,
        @mock_file_system.read(@transcript_file) + auth_error_json + "\n"
      )
      service = create_service
      service.define_singleton_method(:sleep) { |_| }
      results << service.attempt_recovery("/tmp/test-clone")
      break if results.last == :exhausted
    end

    assert_equal [ :success, :success, :success, :exhausted ], results,
      "The 4th consecutive attempt must exhaust rather than loop forever"
    assert_equal AuthRecoveryService::MAX_RECOVERY_ATTEMPTS, spawn_count,
      "No spawn happens once the budget is exhausted"

    @session.reload
    assert_equal AuthRecoveryService::MAX_RECOVERY_ATTEMPTS, @session.metadata["auth_recovery_count"],
      "The counter must accumulate across consecutive attempts, never reset to 0"
  end

  test "an attempt older than CONSECUTIVE_WINDOW starts a fresh budget" do
    setup_transcript_with_auth_error

    @session.update!(metadata: @session.metadata.merge(
      "auth_recovery_count" => AuthRecoveryService::MAX_RECOVERY_ATTEMPTS,
      "last_auth_recovery_at" => (AuthRecoveryService::CONSECUTIVE_WINDOW + 1.minute).ago.iso8601
    ))

    @mock_cli_adapter.resume_hook = ->(_opts) { { pid: 4242, stderr_log_path: "/tmp/stderr.log" } }
    @mock_process_manager.running_hook = ->(_pid) { true }

    service = create_service
    service.define_singleton_method(:sleep) { |_| }

    assert_equal :success, service.attempt_recovery("/tmp/test-clone"),
      "A rotation long after the last one is a new incident, not a continuing loop"
    @session.reload
    assert_equal 1, @session.metadata["auth_recovery_count"]
  end

  test "an attempt inside CONSECUTIVE_WINDOW continues the existing budget" do
    setup_transcript_with_auth_error

    @session.update!(metadata: @session.metadata.merge(
      "auth_recovery_count" => AuthRecoveryService::MAX_RECOVERY_ATTEMPTS,
      "last_auth_recovery_at" => 1.minute.ago.iso8601
    ))

    service = create_service
    service.define_singleton_method(:sleep) { |_| }

    assert_equal :exhausted, service.attempt_recovery("/tmp/test-clone")
    assert_equal 0, @mock_cli_adapter.resumed_sessions.length
  end

  test "auth_error_last_checked_line is preserved across resume (not stale)" do
    assert_not_includes Session::STALE_RETRY_METADATA_KEYS, "auth_error_last_checked_line",
      "Scan position must survive resume so already-handled auth errors are not re-detected"
  end

  test "auth_recovery_count is cleared on resume (stale) to give a fresh budget" do
    assert_includes Session::STALE_RETRY_METADATA_KEYS, "auth_recovery_count"
  end

  # The counter can't be cleared on a liveness check (that's the bug), so the
  # real success signal lives where it is unambiguous: a turn that ran to a
  # normal exit got past the auth wall. Without this, a long-running session
  # surviving several GENUINE rotations inside CONSECUTIVE_WINDOW would be
  # parked despite every recovery having worked.
  test "a completed turn clears the recovery budget" do
    @session.update!(metadata: @session.metadata.merge(
      "auth_recovery_count" => 2,
      "last_auth_recovery_at" => 1.minute.ago.iso8601
    ))

    @session.pause!

    @session.reload
    assert_nil @session.metadata["auth_recovery_count"]
    assert_nil @session.metadata["last_auth_recovery_at"]
  end

  test "three genuine rotations spread across completed turns never exhaust" do
    setup_transcript_with_auth_error

    3.times do
      # Each rotation appends its own auth error, as the real CLI does.
      @mock_file_system.write(
        @transcript_file,
        @mock_file_system.read(@transcript_file) + auth_error_json + "\n"
      )
      @mock_cli_adapter.resume_hook = ->(_opts) { { pid: 4242, stderr_log_path: "/tmp/stderr.log" } }
      @mock_process_manager.running_hook = ->(_pid) { true }

      service = create_service
      service.define_singleton_method(:sleep) { |_| }
      assert_equal :success, service.attempt_recovery("/tmp/test-clone")

      # The recovered process finishes its turn normally.
      @session.reload.pause!
      @session.resume!
    end

    assert_nil @session.reload.metadata["auth_recovery_count"]
  end
end
