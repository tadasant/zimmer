# frozen_string_literal: true

require "automated_prompts"

# Service for handling SIGTERM (exit code 143) retries with adaptive backoff
#
# When Claude Code CLI exits with SIGTERM while actively running, this service
# implements an automatic retry mechanism with adaptive backoff based on global
# rate limit pressure. This handles transient issues where Claude Code terminates
# itself for internal reasons (e.g., API 529 rate limits, resource management).
#
# The service uses GlobalRateLimitTracker to monitor recent SIGTERM events across
# all sessions. When many sessions are experiencing SIGTERMs (indicating system-wide
# rate limiting), delays are escalated to allow recovery:
#
# Normal delays:    5s, 10s, 20s
# Escalated delays: 60s (1 min), 180s (3 min), 300s (5 min)
#
# Usage:
#   service = SigtermRetryService.new(
#     session,
#     cli_adapter: ClaudeCliAdapter.new,
#     process_manager: SystemProcessManager.new,
#     log_buffer: log_buffer
#   )
#   result = service.attempt_retry(working_directory)
#   # Returns :success, :exhausted, or :aborted
#
# When the original process was killed before producing any assistant response,
# the service falls back to a fresh spawn with the original prompt instead of
# trying to resume (which would fail with "No conversation found").
#
class SigtermRetryService
  include DatabaseRetry

  # Maximum retry attempts for SIGTERM exits
  MAX_RETRIES = 3

  # Interval (seconds) for checking session status during long delays
  # For delays > 30s, we check status periodically to avoid wasting time
  # if the user archives/corrupts the session during the wait
  STATUS_CHECK_INTERVAL = 10

  # Minimum time (seconds) a process must run before retry is considered successful.
  # This threshold ensures we don't count a transient spawn as success - the process
  # must demonstrate stability by running continuously for this duration.
  SUCCESS_THRESHOLD = 5

  attr_reader :session, :cli_adapter, :process_manager, :log_buffer, :rate_limit_tracker, :file_system

  def initialize(session, cli_adapter:, process_manager:, log_buffer:, rate_limit_tracker: nil, file_system: nil)
    @session = session
    @cli_adapter = cli_adapter
    @process_manager = process_manager
    @log_buffer = log_buffer
    @rate_limit_tracker = rate_limit_tracker || GlobalRateLimitTracker.new
    @file_system = file_system || RealFileSystemAdapter.new
    @logger = StructuredLogger.new({ session_id: session.id, service: "SigtermRetryService" })
  end

  # Attempt to retry the session after SIGTERM
  # @param working_directory [String] The working directory for the session
  # @return [Symbol] :success if retry succeeded, :exhausted if all retries failed, :aborted if session state changed
  def attempt_retry(working_directory)
    current_retry_count = session.metadata&.dig("sigterm_retry_count") || 0
    sigterm_retry_timestamps = session.metadata&.dig("sigterm_retry_timestamps") || []

    # Check if we've exhausted all retry attempts
    if current_retry_count >= MAX_RETRIES
      add_log("SIGTERM retry limit reached (#{MAX_RETRIES} attempts)", level: "warning")
      return :exhausted
    end

    # Record this SIGTERM event in the global tracker
    rate_limit_tracker.record_event

    # Get adaptive delay based on global rate limit pressure
    retry_delay = rate_limit_tracker.recommended_delay(attempt: current_retry_count)
    retry_attempt = current_retry_count + 1

    # Log rate limit pressure status for visibility
    if rate_limit_tracker.under_pressure?
      recent_count = rate_limit_tracker.recent_event_count
      add_log(
        "System under rate limit pressure (#{recent_count} events in last 5 min) - using escalated delays",
        level: "warning"
      )
    end

    add_log(
      "Claude CLI exited with SIGTERM (exit code 143) - attempting auto-retry #{retry_attempt}/#{MAX_RETRIES}" +
        (retry_delay.positive? ? " after #{retry_delay}s delay" : ""),
      level: "warning"
    )
    log_buffer.flush

    # Wait for the retry delay, checking session status periodically for long delays
    abort_result = wait_with_status_checks(retry_delay)
    return :aborted if abort_result == :aborted

    # Record retry attempt in metadata
    sigterm_retry_timestamps << Time.current.iso8601
    with_db_retry do
      session.update!(
        metadata: (session.metadata || {}).merge(
          "sigterm_retry_count" => retry_attempt,
          "sigterm_retry_timestamps" => sigterm_retry_timestamps,
          "last_sigterm_at" => Time.current.iso8601
        )
      )
    end

    spawn_and_verify_retry(working_directory, retry_attempt)
  end

  private

  # Spawn a new process and verify it stays running
  # @param working_directory [String] The working directory
  # @param retry_attempt [Integer] Current retry attempt number
  # @return [Symbol] :success, :exhausted, :aborted, or recursive call result
  def spawn_and_verify_retry(working_directory, retry_attempt)
    # Final status check immediately before spawning to prevent race condition
    # where user sends a follow-up prompt between wait_with_status_checks and here.
    # This is the last opportunity to abort before spawning an automated recovery
    # process that would race with the user's follow-up prompt.
    abort_result = check_session_status
    return :aborted if abort_result == :aborted

    # Check if there's an existing conversation to resume
    # If the original process was killed before producing any assistant response,
    # we need to start fresh instead of trying to resume
    spawn_result = if conversation_exists?(working_directory)
      # Check for pending follow-up prompt that was lost due to race condition.
      # This happens when the user sends a follow-up, the job is enqueued, but
      # SIGTERM retry kicks in before the job processes the prompt.
      pending_prompt = session.metadata&.dig("pending_follow_up_prompt")
      resume_prompt = if pending_prompt.present?
        add_log("Using pending follow-up prompt instead of automated recovery prompt", level: "info")
        # Clear the pending prompt and sent_at now that we're using it
        with_db_retry do
          session.update!(
            metadata: session.metadata.except("pending_follow_up_prompt", "pending_follow_up_sent_at")
          )
        end
        pending_prompt
      else
        AutomatedPrompts::SYSTEM_RECOVERY
      end

      # Regenerate system prompt for retry consistency
      system_prompt = OrchestratorSystemPromptBuilder.build(
        session: session,
        clone_path: session.metadata&.dig("clone_path")
      )

      add_log("Resuming existing conversation", level: "debug")
      cli_adapter.resume(
        session_id: session.session_id,
        prompt: resume_prompt,
        working_dir: working_directory,
        append_system_prompt: system_prompt,
        model: session.config&.dig("model"),
        auto_compact_window: session.auto_compact_window
      )
    else
      # Regenerate system prompt for retry consistency
      system_prompt = OrchestratorSystemPromptBuilder.build(
        session: session,
        clone_path: session.metadata&.dig("clone_path")
      )

      add_log("No existing conversation found, starting fresh with original prompt", level: "info")
      cli_adapter.execute(
        prompt: session.prompt,
        session_id: session.session_id,
        working_dir: working_directory,
        mcp_config_path: session.metadata&.dig("mcp_config_path"),
        append_system_prompt: system_prompt,
        model: session.config&.dig("model"),
        auto_compact_window: session.auto_compact_window
      )
    end

    new_pid = spawn_result[:pid]

    add_log(
      "Spawned new Claude CLI process with PID #{new_pid} for retry attempt #{retry_attempt}",
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
        "SIGTERM retry #{retry_attempt} successful - process #{new_pid} verified running for #{SUCCESS_THRESHOLD}s",
        level: "info"
      )
      log_buffer.flush
      @logger.info("SIGTERM retry successful", retry_attempt: retry_attempt, new_pid: new_pid)
      return :success
    end

    # Process died during verification - continue to next retry attempt
    attempt_retry(working_directory)
  rescue => e
    if retry_attempt >= MAX_RETRIES
      # Final attempt failed and no retries remain — this is a genuine failure,
      # so log at error (which surfaces to GlitchTip, with a backtrace).
      add_log(
        "Error during SIGTERM retry attempt #{retry_attempt}: #{e.message}",
        level: "error"
      )
      log_buffer.flush
      @logger.error("Error during SIGTERM retry", retry_attempt: retry_attempt, error: e.message, exception: e)
      return :exhausted
    end

    # Intermediate attempt failed but retries remain; this is expected/transient
    # and will self-resolve on the next attempt, so log at info (no alert).
    add_log(
      "Error during SIGTERM retry attempt #{retry_attempt}: #{e.message}",
      level: "info"
    )
    log_buffer.flush
    @logger.info("Error during SIGTERM retry", retry_attempt: retry_attempt, error: e.message)
    attempt_retry(working_directory)
  end

  # Verify a process stays running for the success threshold
  #
  # We check every 0.5s to detect failures quickly, but only return success
  # after the full threshold period to ensure the process is stable and not
  # just experiencing a transient spawn before crashing.
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
          "Retry attempt #{retry_attempt} failed - process #{pid} died after #{elapsed.round(1)}s",
          level: "warning"
        )
        return false
      end

      return true if elapsed >= SUCCESS_THRESHOLD

      sleep(0.5)
    end
  end

  # Wait for the specified delay, checking session status periodically for long delays
  #
  # For delays > 30s, we check session status every STATUS_CHECK_INTERVAL seconds
  # to avoid wasting time if the user archives/corrupts the session during the wait.
  #
  # @param delay [Integer] Total delay in seconds
  # @return [Symbol, nil] :aborted if session state changed, nil otherwise
  def wait_with_status_checks(delay)
    return nil unless delay.positive?

    # For short delays, just sleep without status checks
    if delay <= 30
      sleep(delay)
      return check_session_status
    end

    # For long delays, check status periodically
    remaining = delay
    while remaining.positive?
      sleep_time = [ remaining, STATUS_CHECK_INTERVAL ].min
      sleep(sleep_time)
      remaining -= sleep_time

      # Check session status periodically
      abort_result = check_session_status
      return abort_result if abort_result == :aborted
    end

    nil
  end

  # Check if session is still running
  # @return [Symbol, nil] :aborted if session state changed, nil if still running
  def check_session_status
    session.reload
    unless session.running?
      add_log(
        "Session state changed to #{session.status} during retry delay, aborting retry",
        level: "warning"
      )
      return :aborted
    end
    nil
  end

  # Add log entry via log buffer
  def add_log(content, level: "info")
    log_buffer.add(content, level: level)
  end

  # Check if a valid conversation exists in the transcript
  # A valid conversation has at least one assistant message (not just queue operations)
  # @param working_directory [String] The working directory for finding the transcript
  # @return [Boolean] true if conversation exists, false otherwise
  def conversation_exists?(working_directory)
    transcript_dir = get_transcript_directory(working_directory)
    return false unless transcript_dir && file_system.directory?(transcript_dir)

    transcript_file = TranscriptFileLocator.find_main_transcript(session, transcript_dir, file_system: file_system)
    return false unless transcript_file && file_system.exists?(transcript_file)

    transcript_content = file_system.read(transcript_file)
    return false if transcript_content.blank?

    # Parse transcript and check for assistant messages
    transcript_content.lines.any? do |line|
      entry = JSON.parse(line.strip)
      entry["type"] == "assistant"
    rescue JSON::ParserError
      false
    end
  end

  # Get the transcript directory for the working directory
  # @param working_directory [String] The working directory
  # @return [String, nil] The transcript directory path or nil
  def get_transcript_directory(working_directory)
    return nil unless working_directory.present?

    require "path_sanitizer"
    home_dir = File.expand_path("~")
    claude_projects_dir = File.join(home_dir, ".claude", "projects")
    sanitized_path = PathSanitizer.sanitize(working_directory)
    File.join(claude_projects_dir, sanitized_path)
  rescue => e
    @logger.error("Failed to get transcript directory", error: e.message)
    nil
  end
end
