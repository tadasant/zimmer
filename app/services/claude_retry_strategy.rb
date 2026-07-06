# frozen_string_literal: true

# ClaudeRetryStrategy classifies Claude CLI process exits so that
# ProcessLifecycleManager can decide which recovery path to take.
#
# These classifiers are Claude-specific: they recognize Claude CLI's stderr
# strings ("No conversation found with session ID"), Claude's context-length
# error patterns, and Anthropic API error envelopes recorded in the transcript.
# Other runtimes (e.g. Codex, see #3777) provide their own strategy via their
# adapter's #retry_strategy factory.
#
# Generic, OS-level exit classification (e.g. SIGTERM detection) stays in
# ProcessLifecycleManager because it applies to every runtime.
#
# The detection logic delegates to ContextLengthRetryService / ApiErrorRetryService
# for transcript parsing so there is a single source of truth for those patterns;
# the *recovery* execution (spawning the /compact or retry process) remains in
# ProcessLifecycleManager.
class ClaudeRetryStrategy
  # Claude CLI exits 0 even when --resume fails because the session ID doesn't
  # exist on Anthropic's servers (e.g. the original process was killed before the
  # conversation persisted). The only signal is this stderr line.
  FAILED_RESUME_PATTERN = /No conversation found with session ID/i

  def initialize(cli_adapter:, session:, file_system:, process_manager:, rate_limit_tracker:, logger: Rails.logger)
    @cli_adapter = cli_adapter
    @session = session
    @file_system = file_system
    @process_manager = process_manager
    @rate_limit_tracker = rate_limit_tracker
    @logger = logger
  end

  # Claude CLI exits with code 1 (not 0) when the agent finishes its turn and
  # pauses to await user input. That is a normal "conversation paused" state, not
  # a failure, so ProcessLifecycleManager treats such an exit the same as exit 0
  # and transitions the session to needs_input.
  #
  # This is a Claude-specific convention. Other runtimes use exit 1 to signal a
  # genuine error (e.g. Codex), so each runtime's strategy answers this for itself
  # rather than ProcessLifecycleManager hardcoding `exitstatus == 1`.
  def normal_completion_exit?(status)
    status.exitstatus == 1
  end

  # Check if stderr or transcript indicates a context length error.
  #
  # Context length errors can appear in two places (see ContextLengthRetryService):
  # 1. stderr log file - when Claude CLI writes the error directly
  # 2. Transcript file - when the Claude API returns an error that's recorded
  #    as a synthetic API error message with isApiErrorMessage: true
  def context_length_error?(stderr_log_path:)
    return true if context_length_error_in_stderr?(stderr_log_path)
    return true if context_length_error_in_transcript?

    false
  end

  # Check if the process exit was a failed resume attempt.
  #
  # Without this check, the session enters a zombie loop: every follow-up prompt
  # spawns a resume that instantly exits 0 with no work done, transitioning back
  # to needs_input indefinitely.
  def failed_resume_recovery_needed?(stderr_log_path:)
    return false unless stderr_log_path
    return false unless @file_system.exists?(stderr_log_path)

    content = @file_system.read(stderr_log_path)
    return false if content.blank?

    content.match?(FAILED_RESUME_PATTERN)
  rescue => e
    @logger.error("Error checking stderr for failed resume", error: e.message)
    false
  end

  # Check if the transcript contains a retryable API error (server error or rate limit).
  def api_error_for_retry?(working_dir:)
    return false unless working_dir

    temp_service = ApiErrorRetryService.new(
      @session,
      cli_adapter: @cli_adapter,
      process_manager: @process_manager,
      log_buffer: NullLogBuffer.new,
      file_system: @file_system,
      rate_limit_tracker: @rate_limit_tracker
    )

    temp_service.retryable_api_error_detected?(working_dir)
  rescue => e
    @logger.error("Error checking transcript for API error", error: e.message)
    false
  end

  # Check if the transcript's most recent API error is the rotation-induced
  # "Not logged in / Please run /login" signature — a recoverable auth failure
  # (the active account was rotated out from under an in-flight session) that is
  # fixed by re-writing the current account's credentials and resuming.
  #
  # Delegates to AuthRecoveryService so the detection pattern lives in one place,
  # mirroring how #api_error_for_retry? delegates to ApiErrorRetryService.
  def auth_recovery_needed?(working_dir:)
    return false unless working_dir

    temp_service = AuthRecoveryService.new(
      @session,
      cli_adapter: @cli_adapter,
      process_manager: @process_manager,
      log_buffer: NullLogBuffer.new,
      file_system: @file_system
    )

    temp_service.auth_error_detected?(working_dir)
  rescue => e
    @logger.error("Error checking transcript for auth error", error: e.message)
    false
  end

  private

  # Check if stderr contains a context length error.
  def context_length_error_in_stderr?(stderr_log_path)
    return false unless stderr_log_path
    return false unless @file_system.exists?(stderr_log_path)

    content = @file_system.read(stderr_log_path)
    return false if content.blank?

    ContextLengthRetryService::CONTEXT_LENGTH_ERROR_PATTERNS.any? do |pattern|
      content.match?(pattern)
    end
  rescue => e
    @logger.error("Error checking stderr for context length error", error: e.message)
    false
  end

  # Check if the transcript contains an API error indicating a context length error.
  #
  # Delegates to ContextLengthRetryService for the actual transcript parsing
  # since it has the same logic and we want to avoid duplication.
  def context_length_error_in_transcript?
    working_directory = @session.metadata&.dig("working_directory")
    return false unless working_directory

    # Create a temporary service instance just for the transcript check.
    # We use a minimal log buffer that discards logs since we don't need them here.
    temp_service = ContextLengthRetryService.new(
      @session,
      cli_adapter: @cli_adapter,
      process_manager: @process_manager,
      log_buffer: NullLogBuffer.new,
      file_system: @file_system
    )

    temp_service.send(:context_length_error_in_transcript?, working_directory)
  rescue => e
    @logger.error("Error checking transcript for context length error", error: e.message)
    false
  end
end
