require "test_helper"

class ContextLengthRetryServiceTest < ActiveSupport::TestCase
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
    @stderr_log_path = "/tmp/test-clone/claude_stderr.log"
  end

  def create_service
    ContextLengthRetryService.new(
      @session,
      cli_adapter: @mock_cli_adapter,
      process_manager: @mock_process_manager,
      log_buffer: @log_buffer,
      file_system: @mock_file_system
    )
  end

  # ============================================================================
  # Error Detection Tests
  # ============================================================================

  test "returns :not_applicable when stderr log path is nil" do
    service = create_service
    result = service.attempt_recovery("/tmp/test", nil)

    assert_equal :not_applicable, result
  end

  test "returns :not_applicable when stderr log file does not exist" do
    service = create_service
    result = service.attempt_recovery("/tmp/test", @stderr_log_path)

    assert_equal :not_applicable, result
  end

  test "returns :not_applicable when stderr log is empty" do
    @mock_file_system.write(@stderr_log_path, "")
    service = create_service
    result = service.attempt_recovery("/tmp/test", @stderr_log_path)

    assert_equal :not_applicable, result
  end

  test "returns :not_applicable when stderr has no context length errors" do
    @mock_file_system.write(@stderr_log_path, "Some normal log output\nAnother line")
    service = create_service
    result = service.attempt_recovery("/tmp/test", @stderr_log_path)

    assert_equal :not_applicable, result
  end

  test "detects 'prompt is too long' error pattern" do
    @mock_file_system.write(@stderr_log_path, "Error: prompt is too long for the context window")

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    result = service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    assert_equal :success, result
  end

  test "detects 'context length exceeded' error pattern" do
    @mock_file_system.write(@stderr_log_path, "The context length exceeded the maximum allowed")

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    result = service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    assert_equal :success, result
  end

  test "detects 'context limit exceeded' error pattern" do
    @mock_file_system.write(@stderr_log_path, "Error: context limit exceeded")

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    result = service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    assert_equal :success, result
  end

  test "detects 'token limit exceeded' error pattern" do
    @mock_file_system.write(@stderr_log_path, "API error: token limit exceeded")

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    result = service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    assert_equal :success, result
  end

  test "detects 'maximum context length' error pattern" do
    @mock_file_system.write(@stderr_log_path, "Error: maximum context length reached")

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    result = service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    assert_equal :success, result
  end

  test "detects 'input too long' error pattern" do
    @mock_file_system.write(@stderr_log_path, "The input is too long for processing")

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    result = service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    assert_equal :success, result
  end

  test "error detection is case insensitive" do
    @mock_file_system.write(@stderr_log_path, "ERROR: PROMPT IS TOO LONG")

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    result = service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    assert_equal :success, result
  end

  # ============================================================================
  # Retry Limit Tests
  # ============================================================================

  test "returns :exhausted when compact retry count already at maximum" do
    @mock_file_system.write(@stderr_log_path, "Error: prompt is too long")
    @session.update!(metadata: @session.metadata.merge("compact_retry_count" => 2))

    service = create_service
    result = service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    assert_equal :exhausted, result
  end

  test "returns :success when compact spawns a process that stays running" do
    @mock_file_system.write(@stderr_log_path, "Error: prompt is too long")

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    result = service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    assert_equal :success, result
    @session.reload
    assert_equal 1, @session.metadata["compact_retry_count"]
    assert_equal 12345, @session.metadata["process_pid"]
  end

  test "increments compact retry count and tracks last_compact_at" do
    @mock_file_system.write(@stderr_log_path, "Error: prompt is too long")

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    @session.reload
    assert_equal 1, @session.metadata["compact_retry_count"]
    assert_not_nil @session.metadata["last_compact_at"]
  end

  test "sets pending_compact_continuation flag when spawning compact" do
    @mock_file_system.write(@stderr_log_path, "Error: prompt is too long")

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    @session.reload
    assert_equal true, @session.metadata["pending_compact_continuation"],
      "Should set pending_compact_continuation flag to signal auto-continuation after compact"
  end

  # ============================================================================
  # Process Spawning Tests
  # ============================================================================

  test "sends /compact command when attempting recovery" do
    @mock_file_system.write(@stderr_log_path, "Error: prompt is too long")

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    assert_equal 1, @mock_cli_adapter.resumed_sessions.length
    assert_equal "/compact", @mock_cli_adapter.resumed_sessions.first[:prompt]
    assert_equal @session.session_id, @mock_cli_adapter.resumed_sessions.first[:session_id]
  end

  test "updates process_pid in session metadata after spawning" do
    @mock_file_system.write(@stderr_log_path, "Error: prompt is too long")

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 99999, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    @session.reload
    assert_equal 99999, @session.metadata["process_pid"]
  end

  # ============================================================================
  # Process Verification Tests
  # ============================================================================

  test "retries when process dies during verification period" do
    @mock_file_system.write(@stderr_log_path, "Error: prompt is too long")

    spawn_count = 0
    @mock_cli_adapter.resume_hook = ->(opts) do
      spawn_count += 1
      { pid: 100 + spawn_count, stderr_log_path: "/tmp/stderr.log" }
    end

    # First spawn dies, second stays running
    @mock_process_manager.running_hook = ->(pid) { pid == 102 }

    service = create_service
    # Skip actual sleeps
    service.define_singleton_method(:sleep) { |_| }

    result = service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    assert_equal :success, result
    assert_equal 2, spawn_count

    @session.reload
    assert_equal 2, @session.metadata["compact_retry_count"]
    assert_equal 102, @session.metadata["process_pid"]
    # Verify pending_compact_continuation flag is preserved through retries
    assert_equal true, @session.metadata["pending_compact_continuation"],
      "Should preserve pending_compact_continuation flag through retries for auto-continuation"
  end

  test "returns :exhausted when all compact retries fail" do
    @mock_file_system.write(@stderr_log_path, "Error: prompt is too long")

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { false }

    service = create_service
    # Skip actual sleeps
    service.define_singleton_method(:sleep) { |_| }

    result = service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    assert_equal :exhausted, result
  end

  test "handles errors during compact and continues to next attempt" do
    @mock_file_system.write(@stderr_log_path, "Error: prompt is too long")

    attempt_count = 0
    @mock_cli_adapter.resume_hook = ->(opts) do
      attempt_count += 1
      if attempt_count < 2
        raise StandardError, "Simulated error"
      end
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    result = service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    assert_equal :success, result
    assert_equal 2, attempt_count
  end

  test "returns :exhausted when all retries fail with errors" do
    @mock_file_system.write(@stderr_log_path, "Error: prompt is too long")

    @mock_cli_adapter.resume_hook = ->(opts) do
      raise StandardError, "Simulated error"
    end

    service = create_service
    result = service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    assert_equal :exhausted, result
  end

  # ============================================================================
  # Logging Tests
  # ============================================================================

  test "creates appropriate log entries during compact" do
    @mock_file_system.write(@stderr_log_path, "Error: prompt is too long")

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    @log_buffer.flush

    logs = @session.logs.reload
    log_contents = logs.map(&:content).join("\n")

    assert_match(/Context length error detected.*auto-compact/, log_contents)
    assert_match(/Sending \/compact command/, log_contents)
    assert_match(/compact.*successful/, log_contents)
  end

  test "logs warning when compact retry limit is reached" do
    @mock_file_system.write(@stderr_log_path, "Error: prompt is too long")
    @session.update!(metadata: @session.metadata.merge("compact_retry_count" => 2))

    service = create_service
    service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    @log_buffer.flush

    logs = @session.logs.reload
    warning_logs = logs.select { |l| l.level == "warning" }

    assert warning_logs.any? { |l| l.content.include?("compact limit reached") }
  end

  test "logs process spawn information" do
    @mock_file_system.write(@stderr_log_path, "Error: prompt is too long")

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    @log_buffer.flush

    logs = @session.logs.reload
    log_contents = logs.map(&:content).join("\n")

    assert_match(/Spawned Claude CLI process with PID 12345/, log_contents)
  end

  # ============================================================================
  # Constants Tests
  # ============================================================================

  test "uses correct retry limits from constants" do
    assert_equal 2, ContextLengthRetryService::MAX_RETRIES
    assert_equal 5, ContextLengthRetryService::SUCCESS_THRESHOLD
    assert_equal 6, ContextLengthRetryService::CONTEXT_LENGTH_ERROR_PATTERNS.size
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  test "handles nil metadata gracefully" do
    @session.update!(metadata: nil)
    @mock_file_system.write(@stderr_log_path, "Error: prompt is too long")

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    result = service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    assert_equal :success, result
    @session.reload
    assert_equal 1, @session.metadata["compact_retry_count"]
  end

  test "handles file system read errors gracefully" do
    # Create file system that raises on read
    error_file_system = MockFileSystemAdapter.new
    error_file_system.define_singleton_method(:exists?) { |_| true }
    error_file_system.define_singleton_method(:read) { |_| raise StandardError, "Read error" }

    service = ContextLengthRetryService.new(
      @session,
      cli_adapter: @mock_cli_adapter,
      process_manager: @mock_process_manager,
      log_buffer: @log_buffer,
      file_system: error_file_system
    )

    result = service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    assert_equal :not_applicable, result
  end

  # ============================================================================
  # Transcript-Based Error Detection Tests (Issue #615)
  # ============================================================================

  test "detects context length error from transcript API error message" do
    # Setup empty stderr (the original code path)
    @mock_file_system.write(@stderr_log_path, "")

    # Setup transcript with API error message
    setup_transcript_with_api_error("Prompt is too long")

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    result = service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    assert_equal :success, result
  end

  test "detects context length error from transcript when stderr is missing" do
    # Don't create stderr file at all
    setup_transcript_with_api_error("Prompt is too long")

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    result = service.attempt_recovery("/tmp/test-clone", nil)

    assert_equal :success, result
  end

  test "detects context length error from transcript with various error patterns" do
    error_messages = [
      "Prompt is too long",
      "context length exceeded",
      "The context limit exceeded maximum",
      "token limit exceeded",
      "maximum context length reached",
      "input too long"
    ]

    error_messages.each do |error_message|
      # Reset session for each test case - include context_length_last_checked_line
      # to ensure each iteration starts fresh (otherwise the line tracking would
      # cause subsequent iterations to see errors as "already processed")
      @session.update!(metadata: @session.metadata.merge(
        "compact_retry_count" => 0,
        "context_length_last_checked_line" => nil
      ))

      # Don't create stderr file
      @mock_file_system.clear
      setup_transcript_with_api_error(error_message)

      @mock_cli_adapter.resume_hook = ->(opts) do
        { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
      end
      @mock_process_manager.running_hook = ->(pid) { true }

      service = create_service
      result = service.attempt_recovery("/tmp/test-clone", nil)

      assert_equal :success, result, "Should detect context length error for: #{error_message}"
    end
  end

  test "ignores non-context-length API errors in transcript" do
    # Setup empty stderr
    @mock_file_system.write(@stderr_log_path, "")

    # Setup transcript with different API error (not context length)
    setup_transcript_with_api_error("Rate limit exceeded", error_type: "rate_limit")

    service = create_service
    result = service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    assert_equal :not_applicable, result
  end

  test "detects context length error from regular assistant message in transcript" do
    # Setup empty stderr
    @mock_file_system.write(@stderr_log_path, "")

    # Setup transcript with regular assistant message (not an API error)
    # This handles the case where Claude CLI emits "Prompt is too long" as a
    # regular message and stays alive but idle (detected by monitoring loop)
    setup_transcript_with_regular_message("Prompt is too long")

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    result = service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    assert_equal :success, result
  end

  test "ignores regular assistant messages that do not match error patterns" do
    # Setup empty stderr
    @mock_file_system.write(@stderr_log_path, "")

    # Setup transcript with regular assistant message that doesn't match error patterns
    setup_transcript_with_regular_message("Hello, how can I help you?")

    service = create_service
    result = service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    assert_equal :not_applicable, result
  end

  test "prefers stderr error detection over transcript" do
    # Setup stderr with error
    @mock_file_system.write(@stderr_log_path, "Error: prompt is too long")

    # Also setup transcript with API error (should be checked second)
    setup_transcript_with_api_error("Prompt is too long")

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    result = service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    assert_equal :success, result
  end

  test "returns :not_applicable when transcript directory does not exist" do
    # Setup empty stderr
    @mock_file_system.write(@stderr_log_path, "")

    # Don't create transcript directory
    service = create_service
    result = service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    assert_equal :not_applicable, result
  end

  test "handles malformed JSON lines in transcript gracefully" do
    # Setup empty stderr
    @mock_file_system.write(@stderr_log_path, "")

    # Setup transcript with malformed JSON and valid API error
    transcript_dir = calculate_test_transcript_dir
    @mock_file_system.mkdir_p(transcript_dir)
    transcript_content = <<~JSONL
      {"type": "user", "message": "Hello"}
      {invalid json line
      #{api_error_json("Prompt is too long")}
    JSONL
    @mock_file_system.write(File.join(transcript_dir, "#{@session.session_id}.jsonl"), transcript_content)

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    result = service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    assert_equal :success, result, "Should skip malformed JSON and still detect valid API error"
  end

  test "handles empty transcript file gracefully" do
    # Setup empty stderr
    @mock_file_system.write(@stderr_log_path, "")

    # Setup empty transcript file
    transcript_dir = calculate_test_transcript_dir
    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write(File.join(transcript_dir, "#{@session.session_id}.jsonl"), "")

    service = create_service
    result = service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    assert_equal :not_applicable, result
  end

  private

  # Helper to calculate the transcript directory for the test session
  def calculate_test_transcript_dir
    home_dir = File.expand_path("~")
    claude_projects_dir = File.join(home_dir, ".claude", "projects")
    sanitized_path = PathSanitizer.sanitize("/tmp/test-clone")
    File.join(claude_projects_dir, sanitized_path)
  end

  # Helper to create API error JSON entry
  def api_error_json(message, error_type: "invalid_request")
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

  # Helper to setup transcript with API error
  def setup_transcript_with_api_error(message, error_type: "invalid_request")
    transcript_dir = calculate_test_transcript_dir
    @mock_file_system.mkdir_p(transcript_dir)
    transcript_content = <<~JSONL
      {"type": "user", "message": {"content": [{"type": "text", "text": "Hello"}]}}
      {"type": "assistant", "message": {"content": [{"type": "text", "text": "Hi there!"}]}}
      #{api_error_json(message, error_type: error_type)}
    JSONL
    @mock_file_system.write(File.join(transcript_dir, "#{@session.session_id}.jsonl"), transcript_content)
  end

  # Helper to setup transcript with regular message (not API error)
  def setup_transcript_with_regular_message(message)
    transcript_dir = calculate_test_transcript_dir
    @mock_file_system.mkdir_p(transcript_dir)
    transcript_content = <<~JSONL
      {"type": "user", "message": {"content": [{"type": "text", "text": "Hello"}]}}
      {"type": "assistant", "message": {"content": [{"type": "text", "text": "#{message}"}]}}
    JSONL
    @mock_file_system.write(File.join(transcript_dir, "#{@session.session_id}.jsonl"), transcript_content)
  end

  # ============================================================================
  # Transcript Line Tracking Tests (Loop Prevention)
  # ============================================================================

  test "saves context_length_last_checked_line when detecting error from transcript" do
    # Setup empty stderr
    @mock_file_system.write(@stderr_log_path, "")

    # Setup transcript with API error
    setup_transcript_with_api_error("Prompt is too long")

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    @session.reload
    # The transcript has 3 lines (user message, assistant message, API error)
    assert_equal 3, @session.metadata["context_length_last_checked_line"],
      "Should save the transcript line count to prevent re-detecting same error"
  end

  test "skips already-checked transcript lines when looking for context length errors" do
    # Setup empty stderr
    @mock_file_system.write(@stderr_log_path, "")

    # Setup transcript with API error
    setup_transcript_with_api_error("Prompt is too long")

    # Set context_length_last_checked_line to 3 (all lines already checked)
    @session.update!(metadata: @session.metadata.merge("context_length_last_checked_line" => 3))

    service = create_service
    result = service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    # Should return :not_applicable because the error was already processed
    assert_equal :not_applicable, result,
      "Should skip transcript lines that were already checked"
  end

  test "detects new transcript errors after last_checked_line" do
    # Setup empty stderr
    @mock_file_system.write(@stderr_log_path, "")

    # Setup transcript with an API error at line 3
    setup_transcript_with_api_error("Prompt is too long")

    # Set context_length_last_checked_line to 2 (only first 2 lines checked)
    @session.update!(metadata: @session.metadata.merge("context_length_last_checked_line" => 2))

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    result = service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    # Should detect the new error at line 3
    assert_equal :success, result,
      "Should detect new errors after the last_checked_line position"
  end

  test "prevents loop by not re-detecting same transcript error after compact" do
    # This is the main loop prevention test
    # Scenario:
    # 1. Process exits with context length error in transcript (line 3)
    # 2. attempt_recovery detects error, sets last_checked_line=3, spawns /compact
    # 3. /compact completes successfully
    # 4. Continuation process exits (for any reason)
    # 5. handle_exit checks for context length error again
    # 6. Should NOT detect the old error at line 3

    # Setup empty stderr
    @mock_file_system.write(@stderr_log_path, "")

    # Setup transcript with API error
    setup_transcript_with_api_error("Prompt is too long")

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service

    # First detection - should succeed and save last_checked_line
    result = service.attempt_recovery("/tmp/test-clone", @stderr_log_path)
    assert_equal :success, result

    @session.reload
    assert_equal 3, @session.metadata["context_length_last_checked_line"]

    # Now simulate a second check (as would happen after /compact continuation exits)
    # The transcript still has the same error at line 3, but it should be skipped
    service2 = create_service
    result2 = service2.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    assert_equal :not_applicable, result2,
      "Should not re-detect the same error that was already processed"
  end

  test "updates context_length_last_checked_line during retry" do
    # Setup empty stderr
    @mock_file_system.write(@stderr_log_path, "")

    # Setup transcript with API error
    setup_transcript_with_api_error("Prompt is too long")

    spawn_count = 0
    @mock_cli_adapter.resume_hook = ->(opts) do
      spawn_count += 1
      { pid: 100 + spawn_count, stderr_log_path: "/tmp/stderr.log" }
    end

    # First spawn dies, second stays running
    @mock_process_manager.running_hook = ->(pid) { pid == 102 }

    service = create_service
    # Skip actual sleeps
    service.define_singleton_method(:sleep) { |_| }

    result = service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    assert_equal :success, result
    @session.reload
    # context_length_last_checked_line should be set during retry as well
    assert_equal 3, @session.metadata["context_length_last_checked_line"]
  end

  # ============================================================================
  # Race Condition Tests
  # ============================================================================

  test "returns :aborted when session paused immediately before spawn (race condition fix)" do
    # This tests the fix for a race condition where:
    # 1. attempt_recovery is called with a context length error
    # 2. User sends follow-up prompt, changing session to needs_input
    # 3. spawn_and_verify_recovery is called but should abort before spawning
    #
    # The fix adds a final status check at the start of spawn_and_verify_recovery
    @mock_file_system.write(@stderr_log_path, "Error: prompt is too long")

    service = create_service

    # Skip actual sleeps during the recovery
    service.define_singleton_method(:sleep) { |_| }

    # Simulate the race condition: session changes to needs_input AFTER
    # attempt_recovery starts but BEFORE spawn_and_verify_recovery's status check
    status_check_count = 0
    original_reload = @session.method(:reload)
    @session.define_singleton_method(:reload) do
      result = original_reload.call
      status_check_count += 1
      # On the 1st reload (which is the status check in spawn_and_verify_recovery),
      # simulate user pausing the session just before we would spawn
      if status_check_count == 1
        self.pause! if self.may_pause?
      end
      result
    end

    result = service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    assert_equal :aborted, result
    # Verify no process was spawned (resume was not called)
    assert_equal 0, @mock_cli_adapter.resumed_sessions.length, "Should not have spawned a /compact process"

    @log_buffer.flush
    logs = @session.logs.reload
    log_contents = logs.map(&:content).join("\n")

    # Verify the abort was logged
    assert_match(/Session state changed to needs_input.*aborting/, log_contents)
  end

  # ============================================================================
  # System Prompt Tests
  # ============================================================================

  test "passes system prompt when sending compact command" do
    @mock_file_system.write(@stderr_log_path, "Error: prompt is too long")

    captured_system_prompt = nil
    @mock_cli_adapter.resume_hook = ->(opts) do
      captured_system_prompt = opts[:append_system_prompt]
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.attempt_recovery("/tmp/test-clone", @stderr_log_path)

    assert_not_nil captured_system_prompt, "System prompt should be passed to resume"
    assert_includes captured_system_prompt, "Zimmer"
    assert_includes captured_system_prompt, "Session ID: #{@session.id}"
  end

  # ============================================================================
  # Assistant Message Detection Tests (Prompt Too Long Hang)
  # ============================================================================

  test "context_length_error_in_assistant_message detects matching pattern" do
    setup_transcript_with_regular_message("Prompt is too long")

    service = create_service
    result = service.send(:context_length_error_in_assistant_message?, "/tmp/test-clone")

    assert result, "Should detect 'Prompt is too long' in regular assistant message"
  end

  test "context_length_error_in_assistant_message ignores non-matching messages" do
    setup_transcript_with_regular_message("Here is your answer")

    service = create_service
    result = service.send(:context_length_error_in_assistant_message?, "/tmp/test-clone")

    assert_not result, "Should not detect non-matching assistant messages"
  end

  test "context_length_error_in_assistant_message ignores API error messages" do
    setup_transcript_with_api_error("Prompt is too long")

    service = create_service
    result = service.send(:context_length_error_in_assistant_message?, "/tmp/test-clone")

    assert_not result, "Should not detect API error messages (those are handled by context_length_error_in_transcript?)"
  end

  test "context_length_error_in_assistant_message respects context_length_last_checked_line" do
    setup_transcript_with_regular_message("Prompt is too long")

    # Mark all lines as already checked
    @session.update!(metadata: @session.metadata.merge("context_length_last_checked_line" => 10))

    service = create_service
    result = service.send(:context_length_error_in_assistant_message?, "/tmp/test-clone")

    assert_not result, "Should skip already-checked lines"
  end

  test "context_length_error_in_assistant_message returns false for nil working directory" do
    service = create_service
    result = service.send(:context_length_error_in_assistant_message?, nil)

    assert_not result
  end
end
