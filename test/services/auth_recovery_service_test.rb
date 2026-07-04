require "test_helper"
require "automated_prompts"

class AuthRecoveryServiceTest < ActiveSupport::TestCase
  # Minimal fake account — the service only reads #email for logging.
  FakeAccount = Struct.new(:email)

  # Fake auth provider standing in for RuntimeAuthProvider.for(runtime). Records
  # the inject_for_session! calls so tests can assert the identity refresh ran
  # with the right arguments, and returns a configurable account (or nil to model
  # "no valid account available").
  class FakeAuthProvider
    attr_reader :calls

    def initialize(account:)
      @account = account
      @calls = []
    end

    def inject_for_session!(session, working_directory = nil)
      @calls << { session: session, working_directory: working_directory }
      @account
    end
  end

  # Auth provider whose inject_for_session! raises, modeling a provider-level
  # failure (e.g. filesystem write error) during identity refresh.
  class RaisingAuthProvider
    def inject_for_session!(_session, _working_directory = nil)
      raise StandardError, "identity refresh boom"
    end
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

  def create_service(auth_provider: nil)
    AuthRecoveryService.new(
      @session,
      cli_adapter: @mock_cli_adapter,
      process_manager: @mock_process_manager,
      log_buffer: @log_buffer,
      file_system: @mock_file_system,
      auth_provider: auth_provider || FakeAuthProvider.new(account: @account)
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

  test "refreshes identity then resumes and returns :success when process stays running" do
    setup_transcript_with_auth_error

    @mock_cli_adapter.resume_hook = ->(_opts) { { pid: 4242, stderr_log_path: "/tmp/stderr.log" } }
    @mock_process_manager.running_hook = ->(_pid) { true }

    provider = FakeAuthProvider.new(account: @account)
    service = create_service(auth_provider: provider)
    service.define_singleton_method(:sleep) { |_| }

    result = service.attempt_recovery("/tmp/test-clone")

    assert_equal :success, result

    # Identity was refreshed with this session and its working directory BEFORE re-spawn.
    assert_equal 1, provider.calls.size
    assert_equal @session, provider.calls.first[:session]
    assert_equal "/tmp/test-clone", provider.calls.first[:working_directory]

    # The session was re-spawned and the new PID recorded.
    assert_equal 1, @mock_cli_adapter.resumed_sessions.length
    @session.reload
    assert_equal 4242, @session.metadata["process_pid"]

    # Counter reset to 0 on success so future independent rotations get a fresh budget.
    assert_equal 0, @session.metadata["auth_recovery_count"]
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

  # The core negative case from the task: NO valid account available means
  # inject_for_session! returns nil. The service must fail cleanly WITHOUT
  # re-spawning and WITHOUT looping.
  test "returns :unrecoverable without spawning when no valid account is available" do
    setup_transcript_with_auth_error

    provider = FakeAuthProvider.new(account: nil)
    service = create_service(auth_provider: provider)
    service.define_singleton_method(:sleep) { |_| }

    result = service.attempt_recovery("/tmp/test-clone")

    assert_equal :unrecoverable, result
    assert_equal 1, provider.calls.size, "Should attempt identity refresh exactly once"
    assert_equal 0, @mock_cli_adapter.resumed_sessions.length,
      "Must NOT spawn a process when there is no account to recover to"

    # Marker advanced so a later manual resume doesn't re-detect and loop, but the
    # retry counter was never incremented (we never actually retried).
    @session.reload
    assert @session.metadata["auth_error_last_checked_line"].to_i > 0
    assert_nil @session.metadata["auth_recovery_count"]
  end

  test "returns :unrecoverable when identity refresh raises" do
    setup_transcript_with_auth_error

    service = create_service(auth_provider: RaisingAuthProvider.new)
    service.define_singleton_method(:sleep) { |_| }

    result = service.attempt_recovery("/tmp/test-clone")

    assert_equal :unrecoverable, result
    assert_equal 0, @mock_cli_adapter.resumed_sessions.length
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
    assert_equal 0, @session.metadata["auth_recovery_count"], "Counter reset to 0 on eventual success"
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
    assert_equal 5, AuthRecoveryService::SUCCESS_THRESHOLD
    assert_equal 2, AuthRecoveryService::RETRY_DELAY
  end

  test "auth_error_last_checked_line is preserved across resume (not stale)" do
    assert_not_includes Session::STALE_RETRY_METADATA_KEYS, "auth_error_last_checked_line",
      "Scan position must survive resume so already-handled auth errors are not re-detected"
  end

  test "auth_recovery_count is cleared on resume (stale) to give a fresh budget" do
    assert_includes Session::STALE_RETRY_METADATA_KEYS, "auth_recovery_count"
  end
end
