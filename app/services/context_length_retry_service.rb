# Service for handling context length errors with automatic /compact command
#
# When Claude Code CLI encounters a "prompt is too long" error (context length
# exceeded), this service implements an automatic recovery mechanism by sending
# the /compact command to reduce context size.
#
# The service follows the same pattern as SigtermRetryService:
# - Detects context length errors from stderr logs OR transcript API errors
# - Tracks retry attempts in session metadata
# - Spawns a new Claude CLI process with /compact command
# - Verifies the new process stays running
#
# Context length errors can appear in three places:
# 1. stderr log file (when Claude CLI writes the error to stderr)
# 2. Transcript JSONL file (when the Claude API returns the error and it's
#    recorded as a synthetic API error message with isApiErrorMessage: true)
# 3. Transcript JSONL file as a regular assistant message (when Claude CLI
#    emits "Prompt is too long" without isApiErrorMessage — process stays
#    alive but idle in this case)
#
# Usage:
#   service = ContextLengthRetryService.new(
#     session,
#     cli_adapter: ClaudeCliAdapter.new,
#     process_manager: SystemProcessManager.new,
#     log_buffer: log_buffer,
#     file_system: RealFileSystemAdapter.new
#   )
#   result = service.attempt_recovery(working_directory, stderr_log_path)
#   # Returns :success, :exhausted, or :not_applicable
#
class ContextLengthRetryService
  include DatabaseRetry

  # Maximum compact attempts per session
  # After 2 attempts, we assume compaction isn't helping and fail the session
  MAX_RETRIES = 2

  # Minimum time (seconds) a process must run before recovery is considered successful
  SUCCESS_THRESHOLD = 5

  # Error patterns that indicate context length exceeded
  # These patterns match various Claude API error messages for context overflow
  CONTEXT_LENGTH_ERROR_PATTERNS = [
    /prompt is too long/i,
    /context.*length.*exceeded/i,
    /context.*limit.*exceeded/i,
    /token.*limit.*exceeded/i,
    /maximum.*context.*length/i,
    /input.*too.*long/i
  ].freeze

  attr_reader :session, :cli_adapter, :process_manager, :log_buffer, :file_system

  def initialize(session, cli_adapter:, process_manager:, log_buffer:, file_system: nil)
    @session = session
    @cli_adapter = cli_adapter
    @process_manager = process_manager
    @log_buffer = log_buffer
    @file_system = file_system || RealFileSystemAdapter.new
    @logger = StructuredLogger.new({ session_id: session.id, service: "ContextLengthRetryService" })
  end

  # Attempt to recover from a context length error by sending /compact
  #
  # @param working_directory [String] The working directory for the session
  # @param stderr_log_path [String] Path to the stderr log file
  # @return [Symbol] :success if recovery succeeded, :exhausted if all retries failed,
  #                  :not_applicable if no context length error was detected,
  #                  :aborted if session state changed (e.g., user paused)
  def attempt_recovery(working_directory, stderr_log_path)
    # Check if this is actually a context length error (in stderr or transcript)
    return :not_applicable unless context_length_error_detected?(stderr_log_path, working_directory)

    current_retry_count = session.metadata&.dig("compact_retry_count") || 0

    # Check if we've exhausted all retry attempts
    if current_retry_count >= MAX_RETRIES
      add_log("Context length compact limit reached (#{MAX_RETRIES} attempts)", level: "warning")
      return :exhausted
    end

    retry_attempt = current_retry_count + 1

    add_log(
      "Context length error detected - attempting auto-compact #{retry_attempt}/#{MAX_RETRIES}",
      level: "warning"
    )
    log_buffer.flush

    # Get current transcript line count to mark as processed
    # This prevents re-detecting the same error message after /compact completes
    transcript_line_count = get_transcript_line_count(working_directory)

    # Record retry attempt in metadata and mark that we need continuation after /compact
    # The pending_compact_continuation flag tells ProcessLifecycleManager to
    # automatically continue with a follow-up prompt after /compact completes
    # instead of transitioning to needs_input
    #
    # Also record the current transcript line count so that subsequent checks
    # for context length errors in the transcript skip already-processed lines
    with_db_retry do
      session.update!(
        metadata: (session.metadata || {}).merge(
          "compact_retry_count" => retry_attempt,
          "last_compact_at" => Time.current.iso8601,
          "pending_compact_continuation" => true,
          "context_length_last_checked_line" => transcript_line_count
        )
      )
    end

    spawn_and_verify_recovery(working_directory, retry_attempt)
  end

  private

  # Check if stderr or transcript contains a context length error pattern
  #
  # Context length errors can appear in three places:
  # 1. stderr log file - when Claude CLI writes the error directly
  # 2. Transcript file (API error) - when the Claude API returns an error that's recorded
  #    as a synthetic API error message with isApiErrorMessage: true
  # 3. Transcript file (assistant message) - when Claude CLI emits "Prompt is too long"
  #    as a regular assistant message (no isApiErrorMessage flag)
  #
  # @param stderr_log_path [String] Path to the stderr log file
  # @param working_directory [String] Working directory for locating transcript
  # @return [Boolean] true if context length error was detected
  def context_length_error_detected?(stderr_log_path, working_directory = nil)
    # Check stderr first (original behavior)
    return true if context_length_error_in_stderr?(stderr_log_path)

    # Check transcript for API errors (for issue #615)
    return true if context_length_error_in_transcript?(working_directory)

    # Check transcript for regular assistant messages (for prompt-too-long hang detection)
    return true if context_length_error_in_assistant_message?(working_directory)

    false
  end

  # Check if stderr contains a context length error pattern
  #
  # @param stderr_log_path [String] Path to the stderr log file
  # @return [Boolean] true if context length error was detected in stderr
  def context_length_error_in_stderr?(stderr_log_path)
    return false unless stderr_log_path
    return false unless file_system.exists?(stderr_log_path)

    content = file_system.read(stderr_log_path)
    return false if content.blank?

    CONTEXT_LENGTH_ERROR_PATTERNS.any? { |pattern| content.match?(pattern) }
  rescue => e
    @logger.error("Error checking stderr for context length error", error: e.message)
    false
  end

  # Check if transcript contains API error messages indicating context length error
  #
  # When the Claude API returns a "Prompt is too long" error, Claude Code CLI
  # records it in the transcript as a synthetic message with:
  # - type: "assistant"
  # - isApiErrorMessage: true
  # - error: "invalid_request"
  # - message.content containing the error text
  #
  # IMPORTANT: This method only checks for NEW error messages that appeared after
  # the last context length error was processed. Without this filtering, old error
  # messages in the transcript would cause infinite compact loops:
  # 1. Context length error → message added to transcript
  # 2. /compact runs → message still in transcript
  # 3. Continuation exits → old error detected → triggers compact again → LOOP
  #
  # We track the last processed line count in session metadata as
  # "context_length_last_checked_line" to skip already-processed errors.
  #
  # @param working_directory [String] Working directory for locating transcript
  # @return [Boolean] true if context length error was detected in transcript
  def context_length_error_in_transcript?(working_directory)
    return false unless working_directory

    transcript_path = find_transcript_path(working_directory)
    return false unless transcript_path
    return false unless file_system.exists?(transcript_path)

    content = file_system.read(transcript_path)
    return false if content.blank?

    # Get the line count from which we should start checking
    # This prevents detecting old context length errors that we've already handled
    last_checked_line = session.metadata&.dig("context_length_last_checked_line") || 0
    lines = content.lines
    current_line_number = 0

    # Parse JSONL and look for API error messages, starting from the last checked position
    lines.each do |line|
      current_line_number += 1
      # Skip lines we've already checked
      next if current_line_number <= last_checked_line
      next if line.strip.blank?

      begin
        entry = JSON.parse(line)

        # Check for API error message format
        next unless entry["isApiErrorMessage"] == true

        # Check for invalid_request error type (context length errors use this)
        next unless entry["error"] == "invalid_request"

        # Extract message content and check for context length error patterns
        message_content = extract_message_text(entry)
        next if message_content.blank?

        if CONTEXT_LENGTH_ERROR_PATTERNS.any? { |pattern| message_content.match?(pattern) }
          @logger.info("Context length error detected in transcript API error", line_number: current_line_number)
          return true
        end
      rescue JSON::ParserError
        # Skip malformed lines
        next
      end
    end

    false
  rescue => e
    @logger.error("Error checking transcript for context length error", error: e.message)
    false
  end

  # Check if transcript contains a regular assistant message (not API error)
  # indicating context length error.
  #
  # This handles the case where Claude CLI emits "Prompt is too long" as a
  # regular assistant message and stays alive but idle. The monitoring loop
  # detects the hang and terminates the process, then routes here for recovery.
  #
  # Uses the same line-tracking as context_length_error_in_transcript? to
  # avoid re-detecting old messages.
  #
  # @param working_directory [String] Working directory for locating transcript
  # @return [Boolean] true if context length error found in regular assistant message
  def context_length_error_in_assistant_message?(working_directory)
    return false unless working_directory

    transcript_path = find_transcript_path(working_directory)
    return false unless transcript_path
    return false unless file_system.exists?(transcript_path)

    content = file_system.read(transcript_path)
    return false if content.blank?

    last_checked_line = session.metadata&.dig("context_length_last_checked_line") || 0
    lines = content.lines
    current_line_number = 0

    lines.each do |line|
      current_line_number += 1
      next if current_line_number <= last_checked_line
      next if line.strip.blank?

      begin
        entry = JSON.parse(line)

        # Only check regular assistant messages (not API errors - those are handled above)
        next unless entry["type"] == "assistant"
        next if entry["isApiErrorMessage"] == true

        message_text = extract_message_text(entry)
        next if message_text.blank?

        if CONTEXT_LENGTH_ERROR_PATTERNS.any? { |pattern| message_text.match?(pattern) }
          @logger.info("Context length error detected in regular assistant message", line_number: current_line_number)
          return true
        end
      rescue JSON::ParserError
        next
      end
    end

    false
  rescue => e
    @logger.error("Error checking assistant messages for context length error", error: e.message)
    false
  end

  # Find the transcript file path for the session
  #
  # Uses TranscriptFileLocator to find the main transcript file in the
  # Claude projects directory.
  #
  # @param working_directory [String] Working directory for the session
  # @return [String, nil] Path to transcript file, or nil if not found
  def find_transcript_path(working_directory)
    transcript_dir = calculate_transcript_directory(working_directory)
    return nil unless transcript_dir
    return nil unless file_system.directory?(transcript_dir)

    TranscriptFileLocator.find_main_transcript(session, transcript_dir, file_system: file_system)
  rescue => e
    @logger.error("Error finding transcript path", error: e.message)
    nil
  end

  # Calculate the transcript directory path from working directory
  #
  # Claude Code stores transcripts in ~/.claude/projects/<sanitized-path>/
  #
  # @param working_directory [String] The working directory
  # @return [String, nil] The transcript directory path
  def calculate_transcript_directory(working_directory)
    return nil unless working_directory

    home_dir = File.expand_path("~")
    claude_projects_dir = File.join(home_dir, ".claude", "projects")
    sanitized_path = PathSanitizer.sanitize(working_directory)
    File.join(claude_projects_dir, sanitized_path)
  rescue => e
    @logger.error("Error calculating transcript directory", error: e.message)
    nil
  end

  # Extract text content from a transcript message entry
  #
  # API error messages have the structure:
  # {
  #   "message": {
  #     "content": [{"type": "text", "text": "Prompt is too long"}]
  #   }
  # }
  #
  # @param entry [Hash] The transcript entry
  # @return [String] The extracted text content
  def extract_message_text(entry)
    message = entry["message"]
    return "" unless message.is_a?(Hash)

    content = message["content"]
    return "" unless content.is_a?(Array)

    content.filter_map do |block|
      block["text"] if block.is_a?(Hash) && block["type"] == "text"
    end.join(" ")
  end

  # Get the current line count of the transcript file
  #
  # Used to track which lines have been processed for context length errors,
  # preventing re-detection of the same error messages.
  #
  # @param working_directory [String] Working directory for locating transcript
  # @return [Integer] Number of lines in the transcript, or 0 if file not found
  def get_transcript_line_count(working_directory)
    transcript_path = find_transcript_path(working_directory)
    return 0 unless transcript_path
    return 0 unless file_system.exists?(transcript_path)

    content = file_system.read(transcript_path)
    return 0 if content.blank?

    content.lines.count
  rescue => e
    @logger.error("Error getting transcript line count", error: e.message)
    0
  end

  # Spawn a new process with /compact command and verify it stays running
  #
  # @param working_directory [String] The working directory
  # @param retry_attempt [Integer] Current retry attempt number
  # @return [Symbol] :success, :exhausted, :aborted, or recursive call result
  def spawn_and_verify_recovery(working_directory, retry_attempt)
    # Final status check immediately before spawning to prevent race condition
    # where user sends a follow-up prompt between attempt_recovery and here.
    # This is the last opportunity to abort before spawning a "/compact" process
    # that would race with the user's follow-up prompt.
    abort_result = check_session_status
    return :aborted if abort_result == :aborted

    # Send /compact command to reduce context
    add_log("Sending /compact command to reduce context size", level: "info")

    # Regenerate system prompt for compact operation consistency
    system_prompt = OrchestratorSystemPromptBuilder.build(
      session: session,
      clone_path: session.metadata&.dig("clone_path")
    )

    spawn_result = cli_adapter.resume(
      session_id: session.session_id,
      prompt: "/compact",
      working_dir: working_directory,
      append_system_prompt: system_prompt,
      model: session.config&.dig("model"),
      auto_compact_window: session.auto_compact_window
    )

    new_pid = spawn_result[:pid]

    add_log(
      "Spawned Claude CLI process with PID #{new_pid} for compact attempt #{retry_attempt}",
      level: "info"
    )

    # Update session metadata with new process PID
    with_db_retry do
      session.update!(
        metadata: (session.metadata || {}).merge("process_pid" => new_pid)
      )
    end

    # Verify the process stays running for the threshold period
    if verify_process_running(new_pid, retry_attempt)
      add_log(
        "Context length compact #{retry_attempt} successful - process #{new_pid} verified running for #{SUCCESS_THRESHOLD}s",
        level: "info"
      )
      log_buffer.flush
      @logger.info("Context length compact successful", retry_attempt: retry_attempt, new_pid: new_pid)
      return :success
    end

    # Process died during verification - continue to next retry attempt
    attempt_recovery_retry(working_directory)
  rescue => e
    if retry_attempt >= MAX_RETRIES
      # Final attempt failed and no retries remain — this is a genuine failure,
      # so log at error (which surfaces to GlitchTip, with a backtrace).
      add_log(
        "Error during context length compact attempt #{retry_attempt}: #{e.message}",
        level: "error"
      )
      log_buffer.flush
      @logger.error("Error during context length compact", retry_attempt: retry_attempt, error: e.message, exception: e)
      return :exhausted
    end

    # Intermediate attempt failed but retries remain; this is expected/transient
    # and will self-resolve on the next attempt, so log at info (no alert).
    add_log(
      "Error during context length compact attempt #{retry_attempt}: #{e.message}",
      level: "info"
    )
    log_buffer.flush
    @logger.info("Error during context length compact", retry_attempt: retry_attempt, error: e.message)
    attempt_recovery_retry(working_directory)
  end

  # Attempt the next recovery retry
  #
  # @param working_directory [String] The working directory
  # @return [Symbol] :success, :exhausted, or recursive call result
  def attempt_recovery_retry(working_directory)
    current_retry_count = session.reload.metadata&.dig("compact_retry_count") || 0

    if current_retry_count >= MAX_RETRIES
      add_log("All compact attempts exhausted", level: "warning")
      return :exhausted
    end

    retry_attempt = current_retry_count + 1

    add_log(
      "Retrying compact after process failure - attempt #{retry_attempt}/#{MAX_RETRIES}",
      level: "warning"
    )

    # Get current transcript line count to mark as processed
    transcript_line_count = get_transcript_line_count(working_directory)

    # Record retry attempt in metadata and preserve the pending_compact_continuation flag
    # The flag must be preserved through retries so that when /compact eventually succeeds,
    # ProcessLifecycleManager knows to automatically continue with the user's task
    #
    # Also update the transcript line count to prevent re-detecting old errors
    with_db_retry do
      session.update!(
        metadata: (session.metadata || {}).merge(
          "compact_retry_count" => retry_attempt,
          "last_compact_at" => Time.current.iso8601,
          "pending_compact_continuation" => true,
          "context_length_last_checked_line" => transcript_line_count
        )
      )
    end

    spawn_and_verify_recovery(working_directory, retry_attempt)
  end

  # Verify a process stays running for the success threshold
  #
  # We check every 0.5s to detect failures quickly, but only return success
  # after the full threshold period to ensure the process is stable.
  #
  # @param pid [Integer] Process ID to verify
  # @param retry_attempt [Integer] Current retry attempt number
  # @return [Boolean] true if process is verified running, false if it died
  def verify_process_running(pid, retry_attempt)
    process_start_time = Time.current

    loop do
      elapsed = Time.current - process_start_time

      unless process_manager.running?(pid)
        add_log(
          "Compact attempt #{retry_attempt} failed - process #{pid} died after #{elapsed.round(1)}s",
          level: "warning"
        )
        return false
      end

      return true if elapsed >= SUCCESS_THRESHOLD

      sleep(0.5)
    end
  end

  # Add log entry via log buffer
  def add_log(content, level: "info")
    log_buffer.add(content, level: level)
  end

  # Check if session is still running
  # @return [Symbol, nil] :aborted if session state changed, nil if still running
  def check_session_status
    session.reload
    unless session.running?
      add_log(
        "Session state changed to #{session.status} during compact recovery, aborting",
        level: "warning"
      )
      return :aborted
    end
    nil
  end
end
