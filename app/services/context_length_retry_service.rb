require "automated_prompts"

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
  include RespawnScaffold

  # The context-length compact budget. After BUDGET.max attempts we assume compaction
  # isn't helping and fail the session. Declared once in RetryBudget.
  BUDGET = RetryBudget::CONTEXT_LENGTH

  # The runtime command this service resumes with. Named because
  # `check_session_status` is told which prompt the respawn will carry, and a
  # literal repeated in two places is the way those two drift apart.
  COMPACT_PROMPT = "/compact"

  # The prompt that resumes a runtime that compacts by itself on resume (see
  # RuntimeCliAdapter::ClassMethods#compacts_on_resume?). It is the recovery
  # nudge, not a compaction command: the runtime compacts before answering it,
  # so the task continues in the same turn.
  SELF_COMPACTING_RESUME_PROMPT = AutomatedPrompts.system_recovery(
    reason: "the conversation outgrew the model's context window, and resuming compacts it"
  )

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

    # Check if we've exhausted all retry attempts
    if BUDGET.exhausted?(session)
      add_log("Context length compact limit reached (#{BUDGET.max} attempts)", level: "warning")
      return :exhausted
    end

    retry_attempt = BUDGET.next_attempt(session)

    add_log(
      "Context length error detected - attempting auto-compact #{retry_attempt}/#{BUDGET.max}",
      level: "warning"
    )
    log_buffer.flush

    with_db_retry do
      BUDGET.record!(session, attempt: retry_attempt, extra: recovery_markers(working_directory))
    end

    spawn_and_verify_recovery(working_directory, retry_attempt)
  end

  private

  # The noun the shared respawn log sentences interpolate.
  def recovery_label = "context length compact"

  # Does the runtime compact on its own when resumed? See
  # RuntimeCliAdapter::ClassMethods#compacts_on_resume?.
  def runtime_compacts_on_resume?
    cli_adapter.compacts_on_resume?
  end

  # The prompt this recovery resumes the runtime with.
  def recovery_prompt
    runtime_compacts_on_resume? ? SELF_COMPACTING_RESUME_PROMPT : COMPACT_PROMPT
  end

  # What an attempt writes beside its budget, so the error it answers is not
  # re-detected after the respawn, and so the respawn's completion is continued
  # when there is a continuation to owe.
  #
  # `pending_compact_continuation` tells ProcessLifecycleManager to follow a
  # finished `/compact` turn with "Continue with the previous task" instead of
  # parking. A runtime that compacts on resume has no such second turn to owe —
  # the recovery prompt is already the continuation — so it is not set there.
  #
  # The line count is the Claude-envelope scan position; the recorded turn
  # error's id is the same marker for a runtime that records turn errors.
  def recovery_markers(working_directory)
    markers = { "context_length_last_checked_line" => get_transcript_line_count(working_directory) }
    markers["pending_compact_continuation"] = true unless runtime_compacts_on_resume?
    markers.merge(RecordedTurnError.handled_attributes(@turn_error))
  end

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
    # A runtime that records the error each turn ended on is asked that and
    # nothing else — its stderr is not Claude's, and its transcript carries no
    # isApiErrorMessage envelope for the scans below to find.
    if records_turn_errors?
      @turn_error = unhandled_turn_error(working_directory)
      return @turn_error&.kind == :context_length
    end

    # Check stderr first (original behavior)
    return true if context_length_error_in_stderr?(stderr_log_path)

    # Check transcript for API errors (for issue pulsemcp/agents#615)
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

  # Spawn a new process with /compact command and verify it stays running
  #
  # @param working_directory [String] The working directory
  # @param retry_attempt [Integer] Current retry attempt number
  # @return [Symbol] :success, :exhausted, :aborted, or recursive call result
  def spawn_and_verify_recovery(working_directory, retry_attempt)
    # The scaffold makes the final status check immediately before spawning, to
    # prevent the race where a user sends a follow-up prompt between
    # attempt_recovery and here — the last opportunity to abort before spawning a
    # "/compact" process that would race with it.
    prompt = recovery_prompt

    respawn_and_verify(working_directory, retry_attempt, resume_prompt: prompt) do
      if runtime_compacts_on_resume?
        add_log("Resuming so the runtime compacts the conversation before it continues", level: "info")
      else
        add_log("Sending /compact command to reduce context size", level: "info")
      end

      resume_for_recovery(working_directory, prompt: prompt)
    end
  end

  # The scaffold's rescue reads this to tell an intermediate failure from the final one.
  def recovery_attempt_limit = BUDGET.max

  # Back to the compact loop, which re-checks the budget on each pass.
  def next_recovery_attempt(working_directory)
    attempt_recovery_retry(working_directory)
  end

  # Attempt the next recovery retry
  #
  # @param working_directory [String] The working directory
  # @return [Symbol] :success, :exhausted, or recursive call result
  def attempt_recovery_retry(working_directory)
    session.reload

    if BUDGET.exhausted?(session)
      add_log("All compact attempts exhausted", level: "warning")
      return :exhausted
    end

    retry_attempt = BUDGET.next_attempt(session)

    add_log(
      "Retrying compact after process failure - attempt #{retry_attempt}/#{BUDGET.max}",
      level: "warning"
    )

    # The same markers as the first attempt: the pending continuation must survive
    # retries so that when /compact eventually succeeds ProcessLifecycleManager
    # still continues the user's task, and the scan position must move past the
    # error this loop is already answering.
    with_db_retry do
      BUDGET.record!(session, attempt: retry_attempt, extra: recovery_markers(working_directory))
    end

    spawn_and_verify_recovery(working_directory, retry_attempt)
  end
end
