require "test_helper"
require "mocha/minitest"
require "automated_prompts"

class ApiErrorRetryServiceTest < ActiveSupport::TestCase
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
    @mock_rate_limit_tracker = MockRateLimitTracker.new
    @log_buffer = LogBuffer.new(@session)
  end

  def create_service(file_system: nil, rate_limit_tracker: nil)
    ApiErrorRetryService.new(
      @session,
      cli_adapter: @mock_cli_adapter,
      process_manager: @mock_process_manager,
      log_buffer: @log_buffer,
      file_system: file_system || @mock_file_system,
      rate_limit_tracker: rate_limit_tracker || @mock_rate_limit_tracker
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

  def setup_transcript_with_api_error(message, error_type: "api_error")
    setup_transcript_directory
    transcript_content = <<~JSONL
      {"type": "user", "message": {"content": [{"type": "text", "text": "Hello"}]}}
      {"type": "assistant", "message": {"content": [{"type": "text", "text": "Hi there!"}]}}
      #{api_error_json(message, error_type: error_type)}
    JSONL
    @mock_file_system.write(@transcript_file, transcript_content)
  end

  # The CLI's own synthetic report of a tool call that would not parse. Note what
  # it does NOT carry: an "error" key. The entry is untyped by construction, so
  # error_type is "" — the specific hole issue #668 fell through.
  def malformed_tool_call_json(message)
    JSON.generate({
      "type" => "assistant",
      "isApiErrorMessage" => true,
      "message" => {
        "model" => "<synthetic>",
        "content" => [ { "type" => "text", "text" => message } ]
      }
    })
  end

  # Reproduces the tail of the production transcript from session 8878 (#668):
  # the assistant's last real message, the CLI's own in-turn retry prompt, and
  # the synthetic entry it wrote when that retry also failed.
  def setup_transcript_with_malformed_tool_call(
    message = "The model's tool call could not be parsed (retry also failed)."
  )
    setup_transcript_directory
    transcript_content = <<~JSONL
      {"type": "assistant", "message": {"content": [{"type": "text", "text": "Real MP3 downloaded. Uploading it so Tadas can play it."}]}}
      {"type": "user", "message": {"content": [{"type": "text", "text": "Your tool call was malformed and could not be parsed. Please retry."}]}}
      #{malformed_tool_call_json(message)}
    JSONL
    @mock_file_system.write(@transcript_file, transcript_content)
  end

  def setup_transcript_with_regular_message(message)
    setup_transcript_directory
    transcript_content = <<~JSONL
      {"type": "user", "message": {"content": [{"type": "text", "text": "Hello"}]}}
      {"type": "assistant", "message": {"content": [{"type": "text", "text": "#{message}"}]}}
    JSONL
    @mock_file_system.write(@transcript_file, transcript_content)
  end

  # ===========================================================================
  # Detection Tests
  # ===========================================================================

  test "detects api_error type in transcript" do
    setup_transcript_with_api_error("Internal server error", error_type: "api_error")

    service = create_service
    assert service.retryable_api_error_detected?("/tmp/test-clone")
  end

  test "detects overloaded_error type in transcript" do
    setup_transcript_with_api_error("Service is overloaded", error_type: "overloaded_error")

    service = create_service
    assert service.retryable_api_error_detected?("/tmp/test-clone")
  end

  test "detects 500 Internal Server Error message in transcript" do
    setup_transcript_with_api_error("500 Internal Server Error")

    service = create_service
    assert service.retryable_api_error_detected?("/tmp/test-clone")
  end

  test "detects 529 overloaded message in transcript" do
    setup_transcript_with_api_error("API Error: 529 Overloaded")

    service = create_service
    assert service.retryable_api_error_detected?("/tmp/test-clone")
  end

  test "does not detect client errors like invalid_request" do
    setup_transcript_with_api_error("Invalid request parameters", error_type: "invalid_request")

    service = create_service
    assert_not service.retryable_api_error_detected?("/tmp/test-clone")
  end

  test "does not detect context length errors (handled by ContextLengthRetryService)" do
    setup_transcript_with_api_error("Prompt is too long", error_type: "invalid_request")

    service = create_service
    assert_not service.retryable_api_error_detected?("/tmp/test-clone")
  end

  test "does not detect regular assistant messages as API errors" do
    setup_transcript_with_regular_message("Everything is fine")

    service = create_service
    assert_not service.retryable_api_error_detected?("/tmp/test-clone")
  end

  # ===========================================================================
  # Unclassified API error extraction (#53)
  # ===========================================================================

  test "unclassified_api_error_text returns the wording no classifier matched" do
    setup_transcript_with_api_error("Your account has been placed in cool-down mode", error_type: "invalid_request")

    service = create_service
    text = service.unclassified_api_error_text("/tmp/test-clone")

    assert_match(/cool-down mode/, text)
    assert_match(/invalid_request/, text)
  end

  test "unclassified_api_error_text returns nil for an error this service already classifies" do
    setup_transcript_with_api_error("500 Internal Server Error")

    service = create_service
    assert_nil service.unclassified_api_error_text("/tmp/test-clone")
  end

  # A compact recovery is an entirely ordinary event. Reporting it as an unknown
  # failure mode would be exactly the false alarm this change must not create.
  test "unclassified_api_error_text ignores context length errors owned by ContextLengthRetryService" do
    setup_transcript_with_api_error("Prompt is too long", error_type: "invalid_request")

    service = create_service
    assert_nil service.unclassified_api_error_text("/tmp/test-clone")
  end

  test "unclassified_api_error_text ignores the auth signature owned by AuthRecoveryService" do
    setup_transcript_with_api_error("Not logged in. Please run /login", error_type: "invalid_request")

    service = create_service
    assert_nil service.unclassified_api_error_text("/tmp/test-clone")
  end

  test "unclassified_api_error_text ignores regular assistant messages" do
    setup_transcript_with_regular_message("Everything is fine")

    service = create_service
    assert_nil service.unclassified_api_error_text("/tmp/test-clone")
  end

  # ===========================================================================
  # Malformed tool calls (#668)
  #
  # The CLI writes these with isApiErrorMessage: true and NO error field, so
  # error_type is "" and every type-based classifier declines. Before this
  # classifier existed, a session that died this way was failed as an unknown
  # failure mode and paged #alerts, with no retry — production session 8878 lost
  # a finished deliverable on its upload step.
  # ===========================================================================

  test "detects the CLI's untyped malformed tool call report" do
    setup_transcript_with_malformed_tool_call

    assert create_service.retryable_api_error_detected?("/tmp/test-clone"),
      "An unparseable tool call is a sampling artifact — a fresh draw usually parses"
  end

  test "detects the malformed tool call on an entry that carries no error field at all" do
    setup_transcript_directory
    @mock_file_system.write(
      @transcript_file,
      malformed_tool_call_json("The model's tool call could not be parsed (retry also failed).") + "\n"
    )

    service = create_service
    assert service.retryable_api_error_detected?("/tmp/test-clone")
    assert service.detected_malformed_tool_call?,
      "The retry ladder needs to know which failure it is spending itself on"
  end

  test "detects the alternate malformed tool call wording" do
    setup_transcript_with_malformed_tool_call("Your tool call was malformed and could not be parsed.")

    assert create_service.retryable_api_error_detected?("/tmp/test-clone")
  end

  # The CLI's in-turn re-prompt carries the same prose but is an ordinary user
  # turn. Only isApiErrorMessage entries are errors; matching prose anywhere else
  # would make every conversation *about* this bug look like an instance of it.
  test "does not treat the CLI's in-turn retry prompt as an API error" do
    setup_transcript_directory
    @mock_file_system.write(@transcript_file, <<~JSONL)
      {"type": "user", "message": {"content": [{"type": "text", "text": "Your tool call was malformed and could not be parsed. Please retry."}]}}
    JSONL

    assert_not create_service.retryable_api_error_detected?("/tmp/test-clone")
  end

  test "does not flag a plain server error as a malformed tool call" do
    setup_transcript_with_api_error("500 Internal Server Error", error_type: "api_error")

    service = create_service
    assert service.retryable_api_error_detected?("/tmp/test-clone")
    assert_not service.detected_malformed_tool_call?
  end

  test "an account quota limit still wins over the malformed tool call classifier" do
    setup_transcript_with_api_error(
      "You've hit your weekly limit · resets Jan 15, 6pm (UTC). The model's tool call could not be parsed.",
      error_type: "rate_limit_error"
    )

    service = create_service
    service.retryable_api_error_detected?("/tmp/test-clone")

    assert_not service.detected_malformed_tool_call?,
      "A quota limit needs hours, not a 5s backoff — it must not be downgraded to a transient retry"
    assert_equal :quota_exceeded, service.attempt_retry("/tmp/test-clone")
  end

  test "unclassified_api_error_text does not report a malformed tool call as unknown" do
    setup_transcript_with_malformed_tool_call

    assert_nil create_service.unclassified_api_error_text("/tmp/test-clone"),
      "The wording has an owner now, so it is no longer news"
  end

  test "terminal_api_error marks an untyped malformed tool call recognized" do
    setup_transcript_with_malformed_tool_call

    terminal = create_service.terminal_api_error("/tmp/test-clone")

    assert_match(/tool call could not be parsed/, terminal.text)
    assert terminal.recognized?,
      "ApiErrorRetryService owns this wording, so it must not page as an unknown failure mode"
  end

  test "retries a malformed tool call by respawning the session" do
    setup_transcript_with_malformed_tool_call

    resume_count = 0
    @mock_cli_adapter.resume_hook = ->(_opts) do
      resume_count += 1
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(_pid) { true }

    service = create_service
    service.define_singleton_method(:sleep) { |_| }

    assert_equal :success, service.attempt_retry("/tmp/test-clone")
    assert_equal 1, resume_count
    assert_equal 1, @session.reload.metadata["api_error_retry_count"]
  end

  test "a malformed tool call retry does not record a global rate limit event" do
    setup_transcript_with_malformed_tool_call

    @mock_cli_adapter.resume_hook = ->(_opts) { { pid: 12345, stderr_log_path: "/tmp/stderr.log" } }
    @mock_process_manager.running_hook = ->(_pid) { true }

    service = create_service
    service.define_singleton_method(:sleep) { |_| }
    service.attempt_retry("/tmp/test-clone")

    assert_empty @mock_rate_limit_tracker.recorded_events,
      "An unparseable tool call is not upstream pressure — it must not slow other sessions down"
  end

  # The other half of the bet. Retrying assumes the failure is stochastic; a
  # payload that is deterministically unserializable (an oversized base64 tool
  # argument, say) fails identically every time. The ladder must run out.
  test "returns :exhausted when a malformed tool call survives every retry" do
    setup_transcript_with_malformed_tool_call

    resume_count = 0
    @mock_cli_adapter.resume_hook = ->(_opts) do
      resume_count += 1
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(_pid) { false }

    service = create_service
    service.define_singleton_method(:sleep) { |_| }

    assert_equal :exhausted, service.attempt_retry("/tmp/test-clone")
    assert_equal ApiErrorRetryService::MAX_RETRIES, resume_count,
      "bounded by MAX_RETRIES — a repeating failure must not be retried forever"
    assert service.detected_malformed_tool_call?,
      "the caller reads this on the exhausted path to decide whether to alert"
  end

  test "logs the malformed tool call as its own category rather than as a server error" do
    setup_transcript_with_malformed_tool_call

    @mock_cli_adapter.resume_hook = ->(_opts) { { pid: 12345, stderr_log_path: "/tmp/stderr.log" } }
    @mock_process_manager.running_hook = ->(_pid) { true }

    service = create_service
    service.define_singleton_method(:sleep) { |_| }
    service.attempt_retry("/tmp/test-clone")
    @log_buffer.flush

    assert_match(/Malformed tool call detected - attempting auto-retry 1\/6/,
      @session.logs.reload.pluck(:content).join("\n"))
  end

  # ===========================================================================
  # Terminal API errors — "this turn DIED on an error", the structural question
  # ProcessLifecycleManager asks last on the normal-completion path.
  # ===========================================================================

  test "terminal_api_error reports an unrecognized error the turn ended on" do
    setup_transcript_with_api_error("Your quantum entitlement has decohered", error_type: "novel_failure")

    terminal = create_service.terminal_api_error("/tmp/test-clone")

    assert_match(/quantum entitlement has decohered/, terminal.text)
    assert_match(/novel_failure/, terminal.text)
    assert_not terminal.recognized?, "Nothing owns this wording"
  end

  # The hole the classifier filter used to leave. A 5xx is retried, the cursor
  # advances past it, the respawn writes nothing and exits 1 — and every
  # classifier now says "not mine" about a transcript whose last word is that
  # 5xx. Filtering recognized errors out here is what let that park silently.
  test "terminal_api_error reports a recognized error too, marked recognized" do
    setup_transcript_with_api_error("500 Internal Server Error", error_type: "api_error")
    @session.update!(metadata: @session.metadata.merge("api_error_last_checked_line" => 99))

    terminal = create_service.terminal_api_error("/tmp/test-clone")

    assert_match(/500 Internal Server Error/, terminal.text)
    assert terminal.recognized?,
      "ApiErrorRetryService owns this wording, so it must not be alerted as unknown"
  end

  test "terminal_api_error marks the auth signature recognized rather than dropping it" do
    setup_transcript_with_api_error(
      "Failed to authenticate: OAuth session expired and could not be refreshed",
      error_type: "authentication_failed"
    )

    terminal = create_service.terminal_api_error("/tmp/test-clone")

    assert terminal.recognized?, "AuthRecoveryService owns this wording"
  end

  test "terminal_api_error returns nil when the turn recovered and produced output" do
    setup_transcript_directory
    @mock_file_system.write(@transcript_file, <<~JSONL)
      {"type": "user", "message": {"content": [{"type": "text", "text": "Hello"}]}}
      #{api_error_json("Your quantum entitlement has decohered", error_type: "novel_failure")}
      {"type": "assistant", "message": {"content": [{"type": "text", "text": "Recovered and finished."}]}}
    JSONL

    assert_nil create_service.terminal_api_error("/tmp/test-clone"),
      "An error the turn recovered from is not the error the turn died on"
  end

  # The shape of the real production session 6412 transcript: bookkeeping entries
  # land after the last message, so "the last line" is the wrong question.
  test "terminal_api_error looks past trailing bookkeeping entries" do
    setup_transcript_directory
    @mock_file_system.write(@transcript_file, <<~JSONL)
      {"type": "user", "message": {"content": [{"type": "text", "text": "Hello"}]}}
      #{api_error_json("Your quantum entitlement has decohered", error_type: "novel_failure")}
      {"type": "last-prompt", "prompt": "Hello"}
      {"type": "atis-latch", "value": 1}
    JSONL

    assert_match(/decohered/, create_service.terminal_api_error("/tmp/test-clone").text)
  end

  test "terminal_api_error ignores a subagent's error" do
    setup_transcript_directory
    sidechain = JSON.parse(api_error_json("Subagent blew up", error_type: "novel_failure")).merge("isSidechain" => true)
    @mock_file_system.write(@transcript_file, <<~JSONL)
      {"type": "user", "message": {"content": [{"type": "text", "text": "Hello"}]}}
      {"type": "assistant", "message": {"content": [{"type": "text", "text": "All done."}]}}
      #{JSON.generate(sidechain)}
    JSONL

    assert_nil create_service.terminal_api_error("/tmp/test-clone"),
      "A sidechain failure does not end the main turn"
  end

  # The cursor exists to stop a HANDLED error being retried twice. A terminal
  # error is by definition the one that just ended this turn, so honouring the
  # cursor here would be the silence this backstop exists to remove.
  test "terminal_api_error ignores the api_error_last_checked_line cursor" do
    setup_transcript_with_api_error("Your quantum entitlement has decohered", error_type: "novel_failure")
    @session.update!(metadata: @session.metadata.merge("api_error_last_checked_line" => 10))

    assert_match(/decohered/, create_service.terminal_api_error("/tmp/test-clone").text)
  end

  test "terminal_api_error returns nil for a turn that ended on real output" do
    setup_transcript_with_regular_message("Everything is fine")

    assert_nil create_service.terminal_api_error("/tmp/test-clone")
  end

  test "terminal_api_error reports the line number of the entry the turn died on" do
    setup_transcript_with_api_error("Your quantum entitlement has decohered", error_type: "novel_failure")

    # user, assistant, error — the helper writes the error third.
    assert_equal 3, create_service.terminal_api_error("/tmp/test-clone").line
  end

  # A bare scalar is valid JSON and not an entry. Asking it for ["type"] would
  # raise past the lazy block and silently disable the backstop for that exit.
  test "terminal_api_error survives a transcript line that parses to a bare scalar" do
    setup_transcript_directory
    @mock_file_system.write(@transcript_file, <<~JSONL)
      {"type": "user", "message": {"content": [{"type": "text", "text": "Hello"}]}}
      #{api_error_json("Your quantum entitlement has decohered", error_type: "novel_failure")}
      null
      42
    JSONL

    assert_match(/decohered/, create_service.terminal_api_error("/tmp/test-clone").text)
  end

  test "unclassified_api_error_text respects the api_error_last_checked_line cursor" do
    setup_transcript_with_api_error("Your account has been placed in cool-down mode", error_type: "invalid_request")
    @session.update!(metadata: @session.metadata.merge("api_error_last_checked_line" => 10))

    service = create_service
    assert_nil service.unclassified_api_error_text("/tmp/test-clone")
  end

  # Extraction only — detection runs on every normal turn completion, so alerting
  # from here would fire repeatedly for a transcript that merely contains an old
  # unrecognized entry. ProcessLifecycleManager owns the emission.
  test "unclassified_api_error_text never alerts on its own" do
    setup_transcript_with_api_error("Your account has been placed in cool-down mode", error_type: "invalid_request")
    AlertService.expects(:raise_alert).never

    create_service.unclassified_api_error_text("/tmp/test-clone")
  end

  test "skips already-checked lines using api_error_last_checked_line" do
    setup_transcript_with_api_error("Internal server error", error_type: "api_error")

    # Mark all current lines as already checked
    @session.update!(metadata: @session.metadata.merge("api_error_last_checked_line" => 10))

    service = create_service
    assert_not service.retryable_api_error_detected?("/tmp/test-clone"),
      "Should not re-detect an already-handled API error"
  end

  test "returns false when transcript directory does not exist" do
    service = create_service
    assert_not service.retryable_api_error_detected?("/tmp/test-clone")
  end

  test "returns false when working_directory is nil" do
    service = create_service
    assert_not service.retryable_api_error_detected?(nil)
  end

  # ===========================================================================
  # Retry Logic Tests
  # ===========================================================================

  test "returns :not_applicable when no API error detected" do
    setup_transcript_with_regular_message("Everything is fine")

    service = create_service
    result = service.attempt_retry("/tmp/test-clone")

    assert_equal :not_applicable, result
  end

  test "returns :exhausted when retry count already at maximum" do
    setup_transcript_with_api_error("Internal server error", error_type: "api_error")
    @session.update!(metadata: @session.metadata.merge("api_error_retry_count" => 6))

    service = create_service
    result = service.attempt_retry("/tmp/test-clone")

    assert_equal :exhausted, result
  end

  test "returns :success when retry spawns a process that stays running" do
    setup_transcript_with_api_error("Internal server error", error_type: "api_error")

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    # Skip actual sleeps
    service.define_singleton_method(:sleep) { |_| }

    result = service.attempt_retry("/tmp/test-clone")

    assert_equal :success, result
    @session.reload
    assert_equal 1, @session.metadata["api_error_retry_count"]
    assert_equal 12345, @session.metadata["process_pid"]
    assert_not_nil @session.metadata["last_api_error_retry_at"]
  end

  test "returns :aborted when session state changes during retry delay" do
    setup_transcript_with_api_error("Internal server error", error_type: "api_error")

    service = create_service

    # Override sleep to change session state during the delay
    service.define_singleton_method(:sleep) do |duration|
      @session.update!(status: :needs_input)
    end

    result = service.attempt_retry("/tmp/test-clone")

    assert_equal :aborted, result
  end

  test "increments retry count and tracks timestamps" do
    setup_transcript_with_api_error("Internal server error", error_type: "api_error")

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.define_singleton_method(:sleep) { |_| }

    service.attempt_retry("/tmp/test-clone")

    @session.reload
    assert_equal 1, @session.metadata["api_error_retry_count"]
    assert_not_nil @session.metadata["last_api_error_retry_at"]
    assert_not_nil @session.metadata["api_error_last_checked_line"]
  end

  test "uses exponential backoff delays" do
    setup_transcript_with_api_error("Internal server error", error_type: "api_error")

    service = create_service

    # Track sleep calls
    sleep_calls = []
    service.define_singleton_method(:sleep) do |duration|
      sleep_calls << duration
    end

    # Make process die immediately during each retry
    @mock_process_manager.running_hook = ->(pid) { false }

    pid_counter = 100
    @mock_cli_adapter.resume_hook = ->(opts) do
      pid_counter += 1
      { pid: pid_counter, stderr_log_path: "/tmp/stderr.log" }
    end

    result = service.attempt_retry("/tmp/test-clone")

    assert_equal :exhausted, result

    # Verify exponential backoff delays were used (5s, 15s, 30s, 60s, 120s, 300s)
    assert_includes sleep_calls, 5, "Should have 5s delay for first attempt"
    assert_includes sleep_calls, 15, "Should have 15s delay for second attempt"
    assert_includes sleep_calls, 30, "Should have 30s delay for third attempt"
  end

  test "retries when process dies during verification period" do
    setup_transcript_with_api_error("Internal server error", error_type: "api_error")

    spawn_count = 0
    @mock_cli_adapter.resume_hook = ->(opts) do
      spawn_count += 1
      { pid: 100 + spawn_count, stderr_log_path: "/tmp/stderr.log" }
    end

    # First two spawns die, third stays running
    @mock_process_manager.running_hook = ->(pid) { pid == 103 }

    service = create_service
    service.define_singleton_method(:sleep) { |_| }

    result = service.attempt_retry("/tmp/test-clone")

    assert_equal :success, result
    assert_equal 3, spawn_count

    @session.reload
    assert_equal 3, @session.metadata["api_error_retry_count"]
    assert_equal 103, @session.metadata["process_pid"]
  end

  test "creates appropriate log entries during retry" do
    setup_transcript_with_api_error("Internal server error", error_type: "api_error")

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.define_singleton_method(:sleep) { |_| }

    service.attempt_retry("/tmp/test-clone")

    @log_buffer.flush

    logs = @session.logs.reload
    log_contents = logs.map(&:content).join("\n")

    assert_match(/detected.*auto-retry/, log_contents)
    assert_match(/Spawned new Claude CLI process/, log_contents)
    assert_match(/API error retry.*successful/, log_contents)
  end

  test "logs warning when retry limit is reached" do
    setup_transcript_with_api_error("Internal server error", error_type: "api_error")
    @session.update!(metadata: @session.metadata.merge("api_error_retry_count" => 6))

    service = create_service
    service.attempt_retry("/tmp/test-clone")

    @log_buffer.flush

    logs = @session.logs.reload
    warning_logs = logs.select { |l| l.level == "warning" }

    assert warning_logs.any? { |l| l.content.include?("retry limit reached") }
  end

  test "uses correct constants" do
    assert_equal 6, ApiErrorRetryService::BUDGET.max
    assert_equal 5, ApiErrorRetryService::SUCCESS_THRESHOLD
    assert_equal 10, ApiErrorRetryService::STATUS_CHECK_INTERVAL
    assert_equal 300, ApiErrorRetryService::MAX_SINGLE_DELAY
    assert_equal [ 5, 15, 30, 60, 120, 300 ], ApiErrorRetryService::RETRY_DELAYS
  end

  test "handles errors during retry and continues to next attempt" do
    setup_transcript_with_api_error("Internal server error", error_type: "api_error")

    attempt_count = 0
    @mock_cli_adapter.resume_hook = ->(opts) do
      attempt_count += 1
      if attempt_count < 3
        raise StandardError, "Simulated error"
      end
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.define_singleton_method(:sleep) { |_| }

    result = service.attempt_retry("/tmp/test-clone")

    assert_equal :success, result
    assert_equal 3, attempt_count
  end

  test "returns :exhausted when all retries fail with errors" do
    setup_transcript_with_api_error("Internal server error", error_type: "api_error")

    @mock_cli_adapter.resume_hook = ->(opts) do
      raise StandardError, "Simulated error"
    end

    service = create_service
    service.define_singleton_method(:sleep) { |_| }

    result = service.attempt_retry("/tmp/test-clone")

    assert_equal :exhausted, result
  end

  test "passes system prompt when resuming session" do
    setup_transcript_with_api_error("Internal server error", error_type: "api_error")

    captured_system_prompt = nil
    @mock_cli_adapter.resume_hook = ->(opts) do
      captured_system_prompt = opts[:append_system_prompt]
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.define_singleton_method(:sleep) { |_| }

    service.attempt_retry("/tmp/test-clone")

    assert_not_nil captured_system_prompt, "System prompt should be passed to resume"
    assert_includes captured_system_prompt, "Zimmer"
    assert_includes captured_system_prompt, "Session ID: #{@session.id}"
  end

  test "uses automated recovery prompt when resuming" do
    setup_transcript_with_api_error("Internal server error", error_type: "api_error")

    captured_prompt = nil
    @mock_cli_adapter.resume_hook = ->(opts) do
      captured_prompt = opts[:prompt]
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.define_singleton_method(:sleep) { |_| }

    service.attempt_retry("/tmp/test-clone")

    assert_equal AutomatedPrompts::SYSTEM_RECOVERY, captured_prompt
  end

  # ===========================================================================
  # Error Pattern Detection Tests
  # ===========================================================================

  test "detects various API server error patterns" do
    patterns = [
      { message: "Internal server error", error_type: "api_error" },
      { message: "Service is overloaded", error_type: "overloaded_error" },
      { message: "Bad gateway", error_type: "api_error" },
      { message: "Service unavailable", error_type: "server_error" },
      { message: "Gateway timeout", error_type: "api_error" },
      { message: "API Error: 502 Bad Gateway", error_type: "api_error" },
      { message: "API Error: 503 Service Unavailable", error_type: "api_error" }
    ]

    patterns.each do |pattern|
      # Reset transcript for each pattern
      setup_transcript_with_api_error(pattern[:message], error_type: pattern[:error_type])
      @session.update!(metadata: @session.metadata.except("api_error_last_checked_line"))

      service = create_service
      assert service.retryable_api_error_detected?("/tmp/test-clone"),
        "Should detect error: #{pattern[:message]} (#{pattern[:error_type]})"
    end
  end

  test "returns :aborted when session paused immediately before spawn" do
    setup_transcript_with_api_error("Internal server error", error_type: "api_error")

    service = create_service
    service.define_singleton_method(:sleep) { |_| }

    # Simulate the race condition: session changes to needs_input AFTER
    # wait_with_status_checks but BEFORE spawn
    status_check_count = 0
    original_reload = @session.method(:reload)
    @session.define_singleton_method(:reload) do
      result = original_reload.call
      status_check_count += 1
      # On the 2nd reload (status check in spawn_and_verify_retry, right before spawn),
      # simulate user pausing
      if status_check_count == 2
        self.pause! if self.may_pause?
      end
      result
    end

    result = service.attempt_retry("/tmp/test-clone")

    assert_equal :aborted, result
    # Verify no process was spawned
    assert_equal 0, @mock_cli_adapter.resumed_sessions.length
  end

  # ===========================================================================
  # Rate Limit Error Detection Tests
  # ===========================================================================

  test "detects rate_limit_error type in transcript" do
    setup_transcript_with_api_error("Rate limit reached", error_type: "rate_limit_error")

    service = create_service
    assert service.retryable_api_error_detected?("/tmp/test-clone")
  end

  test "detects 429 rate limit message in transcript" do
    setup_transcript_with_api_error("API Error: 429 Too Many Requests")

    service = create_service
    assert service.retryable_api_error_detected?("/tmp/test-clone")
  end

  test "detects 'Rate limit reached' message pattern" do
    setup_transcript_with_api_error("API Error: Rate limit reached")

    service = create_service
    assert service.retryable_api_error_detected?("/tmp/test-clone")
  end

  test "detects 'rate limit' message pattern regardless of error type" do
    # Even with a generic error type, rate limit message should be detected
    setup_transcript_with_api_error("Rate limit exceeded, please try again later", error_type: "error")

    service = create_service
    assert service.retryable_api_error_detected?("/tmp/test-clone")
  end

  test "detects 'too many requests' message pattern" do
    setup_transcript_with_api_error("Too many requests, slow down", error_type: "api_error")

    service = create_service
    assert service.retryable_api_error_detected?("/tmp/test-clone")
  end

  test "detects various rate limit error patterns" do
    patterns = [
      { message: "Rate limit reached", error_type: "rate_limit_error" },
      { message: "API Error: 429 Too Many Requests", error_type: "api_error" },
      { message: "API Error: Rate limit reached", error_type: "api_error" },
      { message: "Request limit exceeded", error_type: "rate_limit_error" },
      { message: "Too many requests", error_type: "api_error" }
    ]

    patterns.each do |pattern|
      setup_transcript_with_api_error(pattern[:message], error_type: pattern[:error_type])
      @session.update!(metadata: @session.metadata.except("api_error_last_checked_line"))

      service = create_service
      assert service.retryable_api_error_detected?("/tmp/test-clone"),
        "Should detect rate limit error: #{pattern[:message]} (#{pattern[:error_type]})"
    end
  end

  # ===========================================================================
  # Adaptive Delay Tests (GlobalRateLimitTracker integration)
  # ===========================================================================

  test "records event in rate limit tracker on retry for rate limit errors" do
    setup_transcript_with_api_error("Rate limit reached", error_type: "rate_limit_error")

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.define_singleton_method(:sleep) { |_| }

    service.attempt_retry("/tmp/test-clone")

    assert_equal 1, @mock_rate_limit_tracker.recorded_events.size,
      "Should record one event in rate limit tracker for rate limit errors"
  end

  test "does not record event in rate limit tracker for server errors" do
    setup_transcript_with_api_error("Internal server error", error_type: "api_error")

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.define_singleton_method(:sleep) { |_| }

    service.attempt_retry("/tmp/test-clone")

    assert_equal 0, @mock_rate_limit_tracker.recorded_events.size,
      "Should not record events for server errors (only rate limits)"
  end

  test "uses escalated delays when under rate limit pressure" do
    setup_transcript_with_api_error("Rate limit reached", error_type: "rate_limit_error")

    @mock_rate_limit_tracker.set_under_pressure(true)

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.define_singleton_method(:sleep) { |_| }

    service.attempt_retry("/tmp/test-clone")

    @log_buffer.flush

    logs = @session.logs.reload
    log_contents = logs.map(&:content).join("\n")

    # Under pressure, the escalated delay (60s for attempt 0) should appear in logs
    assert_match(/after 60s delay/, log_contents,
      "Should use escalated delay of 60s when under pressure")
  end

  test "uses normal delays when not under rate limit pressure" do
    setup_transcript_with_api_error("Internal server error", error_type: "api_error")

    @mock_rate_limit_tracker.set_under_pressure(false)

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.define_singleton_method(:sleep) { |_| }

    service.attempt_retry("/tmp/test-clone")

    @log_buffer.flush

    logs = @session.logs.reload
    log_contents = logs.map(&:content).join("\n")

    # Under normal conditions, first delay should be 5s (from RETRY_DELAYS[0])
    assert_match(/after 5s delay/, log_contents,
      "Should use normal delay of 5s")
  end

  test "logs rate limit pressure warning when under pressure" do
    setup_transcript_with_api_error("Rate limit reached", error_type: "rate_limit_error")

    @mock_rate_limit_tracker.set_under_pressure(true)
    # Record some events so recent_event_count returns > 0
    3.times { @mock_rate_limit_tracker.record_event }

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.define_singleton_method(:sleep) { |_| }

    service.attempt_retry("/tmp/test-clone")

    @log_buffer.flush

    logs = @session.logs.reload
    log_contents = logs.map(&:content).join("\n")

    assert_match(/rate limit pressure/, log_contents,
      "Should log rate limit pressure warning")
    assert_match(/escalated delays/, log_contents,
      "Should mention escalated delays")
  end

  test "logs rate limit category for rate limit errors" do
    setup_transcript_with_api_error("Rate limit reached", error_type: "rate_limit_error")

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.define_singleton_method(:sleep) { |_| }

    service.attempt_retry("/tmp/test-clone")

    @log_buffer.flush

    logs = @session.logs.reload
    log_contents = logs.map(&:content).join("\n")

    assert_match(/[Rr]ate limit.*detected.*auto-retry/, log_contents,
      "Should log 'rate limit' category for rate limit errors")
  end

  test "logs server error category for server errors" do
    setup_transcript_with_api_error("Internal server error", error_type: "api_error")

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.define_singleton_method(:sleep) { |_| }

    service.attempt_retry("/tmp/test-clone")

    @log_buffer.flush

    logs = @session.logs.reload
    log_contents = logs.map(&:content).join("\n")

    assert_match(/API server error.*detected.*auto-retry/, log_contents,
      "Should log 'API server error' category for server errors")
  end

  # ===========================================================================
  # Account Quota Limit Detection Tests
  # ===========================================================================

  test "detects account quota limit message and returns :quota_exceeded" do
    setup_transcript_with_api_error(
      "You've hit your limit · resets 5pm (UTC)",
      error_type: "rate_limit_error"
    )

    service = create_service
    result = service.attempt_retry("/tmp/test-clone")

    assert_equal :quota_exceeded, result
  end

  test "does not retry when daily quota limit with time-only reset is detected" do
    setup_transcript_with_api_error(
      "You've hit your limit · resets 11pm (UTC)",
      error_type: "rate_limit_error"
    )

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    service = create_service
    service.define_singleton_method(:sleep) { |_| }

    result = service.attempt_retry("/tmp/test-clone")

    assert_equal :quota_exceeded, result
    assert_equal 0, @mock_cli_adapter.resumed_sessions.length,
      "Should NOT spawn any process for quota limit errors"
  end

  test "does not retry when weekly quota limit with date reset is detected" do
    setup_transcript_with_api_error(
      "You've hit your limit · resets Jan 15, 6pm (UTC)",
      error_type: "rate_limit_error"
    )

    service = create_service
    service.define_singleton_method(:sleep) { |_| }

    result = service.attempt_retry("/tmp/test-clone")

    assert_equal :quota_exceeded, result
  end

  test "does not retry quota limit with month and day in reset time" do
    setup_transcript_with_api_error(
      "You've hit your limit · resets Mar 6, 3am (UTC)",
      error_type: "rate_limit_error"
    )

    service = create_service
    service.define_singleton_method(:sleep) { |_| }

    result = service.attempt_retry("/tmp/test-clone")

    assert_equal :quota_exceeded, result
  end

  test "detects quota limit with rate_limit_error error type" do
    setup_transcript_with_api_error(
      "You've hit your limit · resets 2pm (UTC)",
      error_type: "rate_limit_error"
    )

    service = create_service
    result = service.attempt_retry("/tmp/test-clone")

    assert_equal :quota_exceeded, result
  end

  # Regression: prod incident 2026-06-14 (sessions 8093/8106/8161-8165). The CLI
  # changed its usage-limit wording to "hit your SESSION limit", which the old
  # /hit your limit.*resets/i regex did not match. The error_type is "rate_limit"
  # (not "rate_limit_error"), so it was retried 6× as a transient rate limit and
  # the session failed without ever rotating to another account.
  test "detects session limit message and returns :quota_exceeded (no retry)" do
    setup_transcript_with_api_error(
      "You've hit your session limit · resets 5:50pm (UTC)",
      error_type: "rate_limit"
    )

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    service = create_service
    service.define_singleton_method(:sleep) { |_| }

    result = service.attempt_retry("/tmp/test-clone")

    assert_equal :quota_exceeded, result
    assert_equal 0, @mock_cli_adapter.resumed_sessions.length,
      "Should NOT spawn any process for session limit errors — must rotate, not retry"
  end

  test "detects weekly limit message and returns :quota_exceeded" do
    setup_transcript_with_api_error(
      "You've hit your weekly limit · resets Jan 15, 6pm (UTC)",
      error_type: "rate_limit"
    )

    service = create_service
    service.define_singleton_method(:sleep) { |_| }

    result = service.attempt_retry("/tmp/test-clone")

    assert_equal :quota_exceeded, result
  end

  test "still retries transient rate limit errors after quota limit feature added" do
    setup_transcript_with_api_error(
      "API Error: Rate limit reached",
      error_type: "rate_limit_error"
    )

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.define_singleton_method(:sleep) { |_| }

    result = service.attempt_retry("/tmp/test-clone")

    assert_equal :success, result
    assert_equal 1, @mock_cli_adapter.resumed_sessions.length,
      "Should still spawn a process for transient rate limit errors"
  end

  test "still retries 429 Too Many Requests after quota limit feature added" do
    setup_transcript_with_api_error(
      "API Error: 429 Too Many Requests",
      error_type: "api_error"
    )

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.define_singleton_method(:sleep) { |_| }

    result = service.attempt_retry("/tmp/test-clone")

    assert_equal :success, result
  end

  test "logs clear warning for quota limit detection" do
    setup_transcript_with_api_error(
      "You've hit your limit · resets 5pm (UTC)",
      error_type: "rate_limit_error"
    )

    service = create_service
    service.attempt_retry("/tmp/test-clone")

    @log_buffer.flush

    logs = @session.logs.reload
    log_contents = logs.map(&:content).join("\n")

    assert_match(/[Aa]ccount quota limit detected/, log_contents,
      "Should log that an account quota limit was detected")
    assert_match(/not a transient rate limit/, log_contents,
      "Should clarify this is not a transient rate limit")
  end

  test "records quota limit event in session metadata" do
    setup_transcript_with_api_error(
      "You've hit your limit · resets 5pm (UTC)",
      error_type: "rate_limit_error"
    )

    service = create_service
    service.attempt_retry("/tmp/test-clone")

    @session.reload
    assert_not_nil @session.metadata["last_quota_limit_at"],
      "Should record last_quota_limit_at in metadata"
    assert_equal 1, @session.metadata["quota_limit_count"],
      "Should record quota_limit_count in metadata"
  end

  test "does not record rate limit tracker event for quota limits" do
    setup_transcript_with_api_error(
      "You've hit your limit · resets 5pm (UTC)",
      error_type: "rate_limit_error"
    )

    service = create_service
    service.attempt_retry("/tmp/test-clone")

    assert_equal 0, @mock_rate_limit_tracker.recorded_events.size,
      "Should not record events in rate limit tracker for quota limits"
  end

  test "ACCOUNT_QUOTA_LIMIT_PATTERN matches known production messages" do
    pattern = ApiErrorRetryService::ACCOUNT_QUOTA_LIMIT_PATTERN

    # Known production message formats — overall limit (legacy wording)
    assert_match pattern, "You've hit your limit · resets 5pm (UTC)"
    assert_match pattern, "You've hit your limit · resets 11pm (UTC)"
    assert_match pattern, "You've hit your limit · resets 2pm (UTC)"
    assert_match pattern, "You've hit your limit · resets Jan 15, 6pm (UTC)"
    assert_match pattern, "You've hit your limit · resets Mar 6, 3am (UTC)"

    # Descriptor-word variants the CLI introduced (prod incident 2026-06-14).
    # A word between "your" and "limit" must not break detection.
    assert_match pattern, "You've hit your session limit · resets 5:50pm (UTC)"
    assert_match pattern, "You've hit your session limit · resets 12:50pm (UTC)"
    assert_match pattern, "You've hit your weekly limit · resets Jan 15, 6pm (UTC)"
    assert_match pattern, "You've hit your 5-hour limit · resets 9pm (UTC)"

    # Should NOT match transient rate limit messages — these never carry an
    # explicit reset time, so they must keep flowing through retry-with-backoff.
    assert_no_match pattern, "API Error: Rate limit reached"
    assert_no_match pattern, "429 Too Many Requests"
    assert_no_match pattern, "Rate limit exceeded, please try again later"
  end

  test "quota limit detection advances api_error_last_checked_line" do
    setup_transcript_with_api_error(
      "You've hit your limit · resets 5pm (UTC)",
      error_type: "rate_limit_error"
    )

    service = create_service
    result = service.attempt_retry("/tmp/test-clone")

    assert_equal :quota_exceeded, result

    @session.reload
    assert_not_nil @session.metadata["api_error_last_checked_line"],
      "Should advance api_error_last_checked_line on quota limit so old entries are not re-scanned"
    assert @session.metadata["api_error_last_checked_line"] > 0,
      "api_error_last_checked_line should be positive after quota detection"
  end

  # Regression test: reproduces the exact production scenario from session 2464 where
  # a burst rate limit ("API Error: Rate limit reached") was misclassified as a quota
  # limit because the previous quota entry was re-scanned (api_error_last_checked_line
  # was not advanced on the quota_exceeded path).
  test "burst rate limit after previous quota limit is retried, not treated as quota" do
    setup_transcript_directory

    # Simulate production scenario: first a quota limit, then session resumes and hits burst rate limit.
    # Note: production transcripts use error_type "rate_limit" (not "rate_limit_error") — this matches
    # actual data from session 2464. Detection works via RATE_LIMIT_ERROR_PATTERNS regex fallback.
    transcript_content = <<~JSONL
      {"type": "user", "message": {"content": [{"type": "text", "text": "Hello"}]}}
      {"type": "assistant", "message": {"content": [{"type": "text", "text": "Working..."}]}}
      #{api_error_json("You've hit your limit · resets 7pm (UTC)", error_type: "rate_limit")}
    JSONL
    @mock_file_system.write(@transcript_file, transcript_content)

    # Step 1: First detection finds quota limit
    service1 = create_service
    result1 = service1.attempt_retry("/tmp/test-clone")
    assert_equal :quota_exceeded, result1

    # Verify api_error_last_checked_line was advanced past the quota entry
    @session.reload
    checked_line = @session.metadata["api_error_last_checked_line"]
    assert_not_nil checked_line, "Should have advanced api_error_last_checked_line"

    # Step 2: Session resumes, new lines added (follow-up prompt + burst rate limit)
    transcript_content += <<~JSONL
      {"type": "user", "message": {"content": [{"type": "text", "text": "Continue"}]}}
      {"type": "assistant", "message": {"content": [{"type": "text", "text": "Resuming..."}]}}
      #{api_error_json("API Error: Rate limit reached", error_type: "rate_limit")}
    JSONL
    @mock_file_system.write(@transcript_file, transcript_content)

    # Step 3: New detection should find the burst rate limit, NOT the old quota limit
    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service2 = create_service
    service2.define_singleton_method(:sleep) { |_| }

    result2 = service2.attempt_retry("/tmp/test-clone")

    assert_equal :success, result2,
      "Burst rate limit should be retried with backoff, not treated as quota limit"
    assert_equal 1, @mock_cli_adapter.resumed_sessions.length,
      "Should spawn a retry process for the burst rate limit"
  end

  # ===========================================================================
  # Last-Error-Wins Detection Tests (scan uses most recent error, not first)
  # ===========================================================================

  # Regression test for session 2531: when api_error_last_checked_line is cleared
  # on follow-up/resume, the scan restarts from line 0. If the transcript contains
  # an old quota limit followed by a newer transient rate limit, the scanner must
  # use the MOST RECENT error to classify the situation — not the first match.
  test "uses most recent error when scan position is cleared after follow-up" do
    setup_transcript_directory

    # Transcript has old quota limit AND newer transient rate limit
    transcript_content = <<~JSONL
      {"type": "user", "message": {"content": [{"type": "text", "text": "Hello"}]}}
      #{api_error_json("You've hit your limit · resets 1am (UTC)", error_type: "rate_limit_error")}
      {"type": "user", "message": {"content": [{"type": "text", "text": "Continue"}]}}
      {"type": "assistant", "message": {"content": [{"type": "text", "text": "Resuming..."}]}}
      #{api_error_json("API Error: Rate limit reached", error_type: "rate_limit_error")}
    JSONL
    @mock_file_system.write(@transcript_file, transcript_content)

    # Simulate: api_error_last_checked_line was cleared (as happens on follow-up)
    @session.update!(metadata: @session.metadata.except("api_error_last_checked_line"))

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    service = create_service
    service.define_singleton_method(:sleep) { |_| }

    result = service.attempt_retry("/tmp/test-clone")

    assert_equal :success, result,
      "Should retry transient rate limit even when old quota limit exists earlier in transcript"
    assert_equal 1, @mock_cli_adapter.resumed_sessions.length,
      "Should spawn a retry process based on the most recent error"
  end

  test "uses most recent error when transcript has multiple error types" do
    setup_transcript_directory

    # Old server error, then quota limit, then transient rate limit
    transcript_content = <<~JSONL
      {"type": "user", "message": {"content": [{"type": "text", "text": "Hello"}]}}
      #{api_error_json("Internal server error", error_type: "api_error")}
      #{api_error_json("You've hit your limit · resets 5pm (UTC)", error_type: "rate_limit_error")}
      #{api_error_json("API Error: Rate limit reached", error_type: "rate_limit_error")}
    JSONL
    @mock_file_system.write(@transcript_file, transcript_content)

    service = create_service
    assert service.retryable_api_error_detected?("/tmp/test-clone")

    # Should classify based on LAST error (transient rate limit), not first
    assert_not service.instance_variable_get(:@detected_quota_limit),
      "Should NOT flag as quota limit when the most recent error is a transient rate limit"
    assert service.instance_variable_get(:@detected_rate_limit),
      "Should flag as rate limit based on the most recent error"
  end

  test "detects quota limit when it is the most recent error" do
    setup_transcript_directory

    # Old transient rate limit followed by quota limit (quota IS the most recent)
    transcript_content = <<~JSONL
      {"type": "user", "message": {"content": [{"type": "text", "text": "Hello"}]}}
      #{api_error_json("API Error: Rate limit reached", error_type: "rate_limit_error")}
      #{api_error_json("You've hit your limit · resets 5pm (UTC)", error_type: "rate_limit_error")}
    JSONL
    @mock_file_system.write(@transcript_file, transcript_content)

    service = create_service
    result = service.attempt_retry("/tmp/test-clone")

    assert_equal :quota_exceeded, result,
      "Should correctly identify quota limit when it is the most recent error"
  end

  # ===========================================================================
  # Scan Position Preservation Tests
  # ===========================================================================

  test "api_error_last_checked_line is not in STALE_RETRY_METADATA_KEYS" do
    assert_not_includes Session::STALE_RETRY_METADATA_KEYS, "api_error_last_checked_line",
      "api_error_last_checked_line should not be cleared on resume/follow-up to prevent re-detection of old errors"
  end

  test "api_error_retry_count IS in STALE_RETRY_METADATA_KEYS" do
    assert_includes Session::STALE_RETRY_METADATA_KEYS, "api_error_retry_count",
      "Retry count should be cleared on resume to give fresh retry budget"
  end

  # ===========================================================================
  # Constants Tests
  # ===========================================================================

  test "defines rate limit error patterns" do
    assert_kind_of Array, ApiErrorRetryService::RATE_LIMIT_ERROR_PATTERNS
    assert ApiErrorRetryService::RATE_LIMIT_ERROR_PATTERNS.any? { |p| "rate limit".match?(p) },
      "Should have pattern matching 'rate limit'"
    assert ApiErrorRetryService::RATE_LIMIT_ERROR_PATTERNS.any? { |p| "429".match?(p) },
      "Should have pattern matching '429'"
  end

  test "defines rate limit error types" do
    assert_includes ApiErrorRetryService::RATE_LIMIT_ERROR_TYPES, "rate_limit_error"
  end

  test "RETRYABLE_ERROR_TYPES combines server and rate limit types" do
    assert_includes ApiErrorRetryService::RETRYABLE_ERROR_TYPES, "api_error"
    assert_includes ApiErrorRetryService::RETRYABLE_ERROR_TYPES, "rate_limit_error"
    assert_includes ApiErrorRetryService::RETRYABLE_ERROR_TYPES, "overloaded_error"
  end
end
