require "test_helper"
require "automated_prompts"

class SigtermRetryServiceTest < ActiveSupport::TestCase
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
    @mock_rate_limit_tracker = MockRateLimitTracker.new
    @mock_file_system = MockFileSystemAdapter.new
    @log_buffer = LogBuffer.new(@session)
  end

  def create_service(file_system: nil, rate_limit_tracker: nil)
    SigtermRetryService.new(
      @session,
      cli_adapter: @mock_cli_adapter,
      process_manager: @mock_process_manager,
      log_buffer: @log_buffer,
      rate_limit_tracker: rate_limit_tracker || @mock_rate_limit_tracker,
      file_system: file_system || @mock_file_system
    )
  end

  def setup_transcript_directory
    # Calculate the transcript directory path using PathSanitizer
    require "path_sanitizer"
    home_dir = File.expand_path("~")
    sanitized_path = PathSanitizer.sanitize("/tmp/test-clone")
    @transcript_dir = File.join(home_dir, ".claude", "projects", sanitized_path)
    @transcript_file = File.join(@transcript_dir, "#{@session.session_id}.jsonl")
    @mock_file_system.mkdir_p(@transcript_dir)
  end

  test "returns :exhausted when retry count already at maximum" do
    @session.update!(metadata: @session.metadata.merge("sigterm_retry_count" => 3))

    service = create_service
    result = service.attempt_retry("/tmp/test")

    assert_equal :exhausted, result
  end

  test "returns :success when retry spawns a process that stays running" do
    # Configure mock to spawn a process that stays running
    # Uses execute_hook since no transcript exists (falls back to fresh spawn)
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service

    result = service.attempt_retry("/tmp/test")

    assert_equal :success, result
    @session.reload
    assert_equal 1, @session.metadata["sigterm_retry_count"]
    assert_equal 12345, @session.metadata["process_pid"]
  end

  test "returns :aborted when session state changes during retry delay" do
    # Set retry count to 1 so there's a delay
    @session.update!(metadata: @session.metadata.merge("sigterm_retry_count" => 1))

    service = create_service

    # Override sleep to change session state during the delay
    service.define_singleton_method(:sleep) do |duration|
      @session.update!(status: :needs_input)
    end

    result = service.attempt_retry("/tmp/test")

    assert_equal :aborted, result
  end

  test "returns :aborted when session paused immediately before spawn (race condition fix)" do
    # This tests the fix for a race condition where:
    # 1. wait_with_status_checks returns nil (session was running)
    # 2. User sends follow-up prompt, changing session to needs_input
    # 3. spawn_and_verify_retry is called but should abort before spawning
    #
    # The fix adds a final status check at the start of spawn_and_verify_retry

    setup_transcript_directory

    # Create transcript with assistant message so it would try to resume with automated recovery prompt
    transcript_content = [
      { "type" => "user", "message" => { "content" => "Hello" } }.to_json,
      { "type" => "assistant", "message" => { "content" => [ { "type" => "text", "text" => "Hi" } ] } }.to_json
    ].join("\n")
    @mock_file_system.write(@transcript_file, transcript_content)

    service = create_service

    # Skip actual sleeps during the retry delay
    service.define_singleton_method(:sleep) { |_| }

    # Simulate the race condition: session changes to needs_input AFTER
    # wait_with_status_checks returns but BEFORE spawn_and_verify_retry's status check
    # The first reload is from check_session_status in wait_with_status_checks
    # The second reload is from check_session_status in spawn_and_verify_retry (our fix)
    status_check_count = 0
    original_reload = @session.method(:reload)
    @session.define_singleton_method(:reload) do
      result = original_reload.call
      status_check_count += 1
      # On the 2nd reload (which is the status check in spawn_and_verify_retry),
      # simulate user pausing the session just before we would spawn
      if status_check_count == 2
        self.pause! if self.may_pause?
      end
      result
    end

    result = service.attempt_retry("/tmp/test-clone")

    assert_equal :aborted, result
    # Verify no process was spawned (resume was not called)
    assert_equal 0, @mock_cli_adapter.resumed_sessions.length, "Should not have spawned an automated recovery process"
    assert_equal 0, @mock_cli_adapter.executed_commands.length, "Should not have spawned any process"

    @log_buffer.flush
    logs = @session.logs.reload
    log_contents = logs.map(&:content).join("\n")

    # Verify the abort was logged
    assert_match(/Session state changed to needs_input/, log_contents)
  end

  test "increments retry count and tracks timestamps" do
    # Uses execute_hook since no transcript exists (falls back to fresh spawn)
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service

    service.attempt_retry("/tmp/test")

    @session.reload
    assert_equal 1, @session.metadata["sigterm_retry_count"]
    assert_kind_of Array, @session.metadata["sigterm_retry_timestamps"]
    assert_equal 1, @session.metadata["sigterm_retry_timestamps"].length
    assert_not_nil @session.metadata["last_sigterm_at"]
  end

  test "respects exponential backoff delays with normal pressure" do
    service = create_service

    # Track sleep calls
    sleep_calls = []
    service.define_singleton_method(:sleep) do |duration|
      sleep_calls << duration
    end

    # Make process die immediately during each retry
    @mock_process_manager.running_hook = ->(pid) { false }

    # Uses execute_hook since no transcript exists (falls back to fresh spawn)
    pid_counter = 100
    @mock_cli_adapter.execute_hook = ->(opts) do
      pid_counter += 1
      { pid: pid_counter, stderr_log_path: "/tmp/stderr.log" }
    end

    result = service.attempt_retry("/tmp/test")

    assert_equal :exhausted, result

    # Verify exponential backoff delays were used (normal delays: 5s, 10s, 20s)
    assert_includes sleep_calls, 5, "Should have 5s delay for first attempt"
    assert_includes sleep_calls, 10, "Should have 10s delay for second attempt"
    assert_includes sleep_calls, 20, "Should have 20s delay for third attempt"
  end

  test "uses escalated delays when under rate limit pressure" do
    @mock_rate_limit_tracker.set_under_pressure(true)
    setup_transcript_directory

    # Create a transcript with an assistant message so resume is used
    @mock_file_system.write(@transcript_file, '{"type":"assistant","message":"test"}' + "\n")

    service = create_service

    # Track total delay per retry attempt
    # With STATUS_CHECK_INTERVAL chunking, we sum the delays between process spawns
    total_delays = []
    current_delay_sum = 0
    spawn_count = 0

    service.define_singleton_method(:sleep) do |duration|
      current_delay_sum += duration
    end

    # Make process die immediately during each retry
    @mock_process_manager.running_hook = ->(pid) { false }

    pid_counter = 100
    @mock_cli_adapter.resume_hook = ->(opts) do
      pid_counter += 1
      # Record the total delay before this spawn
      total_delays << current_delay_sum
      current_delay_sum = 0
      spawn_count += 1
      { pid: pid_counter, stderr_log_path: "/tmp/stderr.log" }
    end

    result = service.attempt_retry("/tmp/test-clone")

    assert_equal :exhausted, result

    # Verify escalated total delays were used (60s, 180s, 300s)
    # total_delays contains the sum of all sleeps before each spawn
    assert_equal 60, total_delays[0], "First attempt should have 60s total delay under pressure"
    assert_equal 180, total_delays[1], "Second attempt should have 180s total delay under pressure"
    assert_equal 300, total_delays[2], "Third attempt should have 300s total delay under pressure"
  end

  test "records event in rate limit tracker on each retry" do
    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.attempt_retry("/tmp/test")

    assert_equal 1, @mock_rate_limit_tracker.recorded_events.size
  end

  test "logs rate limit pressure warning when under pressure" do
    @mock_rate_limit_tracker.set_under_pressure(true)
    # Add some events to the tracker to make recent_event_count return > 0
    3.times { @mock_rate_limit_tracker.record_event }

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service

    # Skip actual sleeps
    service.define_singleton_method(:sleep) { |_| }

    service.attempt_retry("/tmp/test")

    @log_buffer.flush

    logs = @session.logs.reload
    log_contents = logs.map(&:content).join("\n")

    assert_match(/rate limit pressure/, log_contents)
    assert_match(/escalated delays/, log_contents)
  end

  test "retries when process dies during verification period" do
    # Uses execute_hook since no transcript exists (falls back to fresh spawn)
    spawn_count = 0
    @mock_cli_adapter.execute_hook = ->(opts) do
      spawn_count += 1
      { pid: 100 + spawn_count, stderr_log_path: "/tmp/stderr.log" }
    end

    # First two spawns die, third stays running
    @mock_process_manager.running_hook = ->(pid) { pid == 103 }

    service = create_service

    # Skip actual sleeps
    service.define_singleton_method(:sleep) { |_| }

    result = service.attempt_retry("/tmp/test")

    assert_equal :success, result
    assert_equal 3, spawn_count

    @session.reload
    assert_equal 3, @session.metadata["sigterm_retry_count"]
    assert_equal 103, @session.metadata["process_pid"]
  end

  test "handles errors during retry and continues to next attempt" do
    # Uses execute_hook since no transcript exists (falls back to fresh spawn)
    attempt_count = 0
    @mock_cli_adapter.execute_hook = ->(opts) do
      attempt_count += 1
      if attempt_count < 3
        raise StandardError, "Simulated error"
      end
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service

    # Skip actual sleeps
    service.define_singleton_method(:sleep) { |_| }

    result = service.attempt_retry("/tmp/test")

    assert_equal :success, result
    assert_equal 3, attempt_count
  end

  test "returns :exhausted when all retries fail with errors" do
    # Uses execute_hook since no transcript exists (falls back to fresh spawn)
    @mock_cli_adapter.execute_hook = ->(opts) do
      raise StandardError, "Simulated error"
    end

    service = create_service

    # Skip actual sleeps
    service.define_singleton_method(:sleep) { |_| }

    result = service.attempt_retry("/tmp/test")

    assert_equal :exhausted, result
  end

  test "creates appropriate log entries during retry" do
    # Uses execute_hook since no transcript exists (falls back to fresh spawn)
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.attempt_retry("/tmp/test")

    @log_buffer.flush

    logs = @session.logs.reload
    log_contents = logs.map(&:content).join("\n")

    assert_match(/SIGTERM.*auto-retry/, log_contents)
    assert_match(/Spawned new Claude CLI process/, log_contents)
    assert_match(/retry.*successful/, log_contents)
  end

  test "logs warning when retry limit is reached" do
    @session.update!(metadata: @session.metadata.merge("sigterm_retry_count" => 3))

    service = create_service
    service.attempt_retry("/tmp/test")

    @log_buffer.flush

    logs = @session.logs.reload
    warning_logs = logs.select { |l| l.level == "warning" }

    assert warning_logs.any? { |l| l.content.include?("retry limit reached") }
  end

  test "uses correct retry delays from constants" do
    assert_equal 3, SigtermRetryService::MAX_RETRIES
    assert_equal 5, SigtermRetryService::SUCCESS_THRESHOLD
    assert_equal 10, SigtermRetryService::STATUS_CHECK_INTERVAL

    # Adaptive delays from GlobalRateLimitTracker
    assert_equal [ 5, 10, 20 ], GlobalRateLimitTracker::NORMAL_BASE_DELAYS
    assert_equal [ 60, 180, 300 ], GlobalRateLimitTracker::ESCALATED_DELAYS
    assert_equal 3, GlobalRateLimitTracker::ESCALATION_THRESHOLD
    assert_equal 5.minutes, GlobalRateLimitTracker::WINDOW_DURATION
  end

  test "verify_process_running returns true if process stays running for threshold" do
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service

    # Override SUCCESS_THRESHOLD check time by stubbing sleep
    sleep_count = 0
    service.define_singleton_method(:sleep) { |_| sleep_count += 1 }

    # The verify method is private, so we test through attempt_retry
    # Uses execute_hook since no transcript exists (falls back to fresh spawn)
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    result = service.attempt_retry("/tmp/test")

    assert_equal :success, result
  end

  test "verify_process_running returns false if process dies during threshold" do
    # Process runs for a bit then dies
    check_count = 0
    @mock_process_manager.running_hook = ->(pid) do
      check_count += 1
      check_count < 3 # Dies on 3rd check
    end

    service = create_service

    # Skip actual sleeps
    service.define_singleton_method(:sleep) { |_| }

    # Uses execute_hook since no transcript exists (falls back to fresh spawn)
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    # Will exhaust all retries since process keeps dying
    result = service.attempt_retry("/tmp/test")

    assert_equal :exhausted, result
  end

  # Tests for conversation_exists? and fresh spawn fallback (issue #413)

  test "uses resume when transcript has assistant messages" do
    setup_transcript_directory

    # Create transcript with assistant message
    transcript_content = [
      { "type" => "user", "message" => { "content" => "Hello" } }.to_json,
      { "type" => "assistant", "message" => { "content" => [ { "type" => "text", "text" => "Hi there!" } ] } }.to_json
    ].join("\n")
    @mock_file_system.write(@transcript_file, transcript_content)

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.attempt_retry("/tmp/test-clone")

    # Should have called resume, not execute
    assert_equal 1, @mock_cli_adapter.resumed_sessions.length
    assert_equal 0, @mock_cli_adapter.executed_commands.length
  end

  test "uses execute with original prompt when transcript has only queue operations" do
    setup_transcript_directory

    # Create transcript with only queue operations (no assistant messages)
    transcript_content = [
      { "type" => "queue-operation", "operation" => "enqueue" }.to_json,
      { "type" => "queue-operation", "operation" => "dequeue" }.to_json
    ].join("\n")
    @mock_file_system.write(@transcript_file, transcript_content)

    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.attempt_retry("/tmp/test-clone")

    # Should have called execute, not resume
    assert_equal 0, @mock_cli_adapter.resumed_sessions.length
    assert_equal 1, @mock_cli_adapter.executed_commands.length
    assert_equal "Test prompt", @mock_cli_adapter.executed_commands.first[:prompt]
  end

  test "uses execute when transcript file does not exist" do
    setup_transcript_directory
    # Don't create transcript file

    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.attempt_retry("/tmp/test-clone")

    # Should have called execute, not resume
    assert_equal 0, @mock_cli_adapter.resumed_sessions.length
    assert_equal 1, @mock_cli_adapter.executed_commands.length
  end

  test "uses execute when transcript directory does not exist" do
    # Don't set up transcript directory

    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.attempt_retry("/tmp/test-clone")

    # Should have called execute, not resume
    assert_equal 0, @mock_cli_adapter.resumed_sessions.length
    assert_equal 1, @mock_cli_adapter.executed_commands.length
  end

  test "uses execute when transcript is empty" do
    setup_transcript_directory
    @mock_file_system.write(@transcript_file, "")

    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.attempt_retry("/tmp/test-clone")

    # Should have called execute, not resume
    assert_equal 0, @mock_cli_adapter.resumed_sessions.length
    assert_equal 1, @mock_cli_adapter.executed_commands.length
  end

  test "logs message when starting fresh due to no conversation" do
    setup_transcript_directory
    # Don't create transcript file

    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.attempt_retry("/tmp/test-clone")

    @log_buffer.flush
    logs = @session.logs.reload
    log_contents = logs.map(&:content).join("\n")

    assert_match(/No existing conversation found, starting fresh with original prompt/, log_contents)
  end

  test "passes mcp_config_path when executing fresh spawn" do
    setup_transcript_directory
    @session.update!(metadata: @session.metadata.merge("mcp_config_path" => "/path/to/mcp.json"))

    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.attempt_retry("/tmp/test-clone")

    assert_equal 1, @mock_cli_adapter.executed_commands.length
    assert_equal "/path/to/mcp.json", @mock_cli_adapter.executed_commands.first[:mcp_config_path]
  end

  # Tests for pending follow-up prompt recovery (race condition fix)

  test "uses pending_follow_up_prompt instead of automated recovery prompt when present" do
    setup_transcript_directory

    # Create transcript with assistant message so it would normally try to resume with automated recovery prompt
    transcript_content = [
      { "type" => "user", "message" => { "content" => "Hello" } }.to_json,
      { "type" => "assistant", "message" => { "content" => [ { "type" => "text", "text" => "Hi" } ] } }.to_json
    ].join("\n")
    @mock_file_system.write(@transcript_file, transcript_content)

    # Set up a pending follow-up prompt (simulating the race condition scenario)
    @session.update!(metadata: @session.metadata.merge("pending_follow_up_prompt" => "Please fix the bug now"))

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    result = service.attempt_retry("/tmp/test-clone")

    assert_equal :success, result

    # Verify the pending prompt was used instead of automated recovery prompt
    assert_equal 1, @mock_cli_adapter.resumed_sessions.length
    assert_equal "Please fix the bug now", @mock_cli_adapter.resumed_sessions.first[:prompt]

    # Verify the pending prompt was cleared from metadata
    @session.reload
    assert_nil @session.metadata["pending_follow_up_prompt"]
  end

  test "uses automated recovery prompt when no pending_follow_up_prompt is present" do
    setup_transcript_directory

    # Create transcript with assistant message
    transcript_content = [
      { "type" => "user", "message" => { "content" => "Hello" } }.to_json,
      { "type" => "assistant", "message" => { "content" => [ { "type" => "text", "text" => "Hi" } ] } }.to_json
    ].join("\n")
    @mock_file_system.write(@transcript_file, transcript_content)

    # No pending follow-up prompt
    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    result = service.attempt_retry("/tmp/test-clone")

    assert_equal :success, result

    # Verify automated recovery prompt was used
    assert_equal 1, @mock_cli_adapter.resumed_sessions.length
    assert_equal AutomatedPrompts::SYSTEM_RECOVERY, @mock_cli_adapter.resumed_sessions.first[:prompt]
  end

  test "logs when using pending follow-up prompt" do
    setup_transcript_directory

    # Create transcript with assistant message
    transcript_content = [
      { "type" => "user", "message" => { "content" => "Hello" } }.to_json,
      { "type" => "assistant", "message" => { "content" => [ { "type" => "text", "text" => "Hi" } ] } }.to_json
    ].join("\n")
    @mock_file_system.write(@transcript_file, transcript_content)

    # Set up a pending follow-up prompt
    @session.update!(metadata: @session.metadata.merge("pending_follow_up_prompt" => "Run the tests"))

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.attempt_retry("/tmp/test-clone")

    @log_buffer.flush
    logs = @session.logs.reload
    log_contents = logs.map(&:content).join("\n")

    assert_match(/Using pending follow-up prompt instead of automated recovery prompt/, log_contents)
  end

  # Tests for system prompt passing

  test "passes system prompt when resuming with existing conversation" do
    setup_transcript_directory

    # Create transcript with assistant message so it uses resume
    transcript_content = [
      { "type" => "user", "message" => { "content" => "Hello" } }.to_json,
      { "type" => "assistant", "message" => { "content" => [ { "type" => "text", "text" => "Hi" } ] } }.to_json
    ].join("\n")
    @mock_file_system.write(@transcript_file, transcript_content)

    captured_system_prompt = nil
    @mock_cli_adapter.resume_hook = ->(opts) do
      captured_system_prompt = opts[:append_system_prompt]
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.attempt_retry("/tmp/test-clone")

    assert_not_nil captured_system_prompt, "System prompt should be passed to resume"
    assert_includes captured_system_prompt, "Agent Orchestrator"
    assert_includes captured_system_prompt, "Session ID: #{@session.id}"
  end

  test "passes system prompt when executing fresh spawn" do
    setup_transcript_directory
    # Don't create transcript file - will fall back to fresh spawn

    captured_system_prompt = nil
    @mock_cli_adapter.execute_hook = ->(opts) do
      captured_system_prompt = opts[:append_system_prompt]
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.attempt_retry("/tmp/test-clone")

    assert_not_nil captured_system_prompt, "System prompt should be passed to execute"
    assert_includes captured_system_prompt, "Agent Orchestrator"
    assert_includes captured_system_prompt, "Session ID: #{@session.id}"
  end
end
