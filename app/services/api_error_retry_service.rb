# frozen_string_literal: true

require "automated_prompts"

# Service for handling API errors (server errors, rate limits, etc.) with adaptive backoff
#
# When Claude Code CLI encounters an API error (500 Internal Server Error,
# 529 Overloaded, 429 Rate Limit, etc.), the error is recorded in the transcript
# as a synthetic API error message with isApiErrorMessage: true. The CLI process
# may exit after encountering these errors.
#
# This service detects API errors in the transcript and retries with adaptive
# backoff using GlobalRateLimitTracker. Under normal conditions, it uses fixed
# exponential backoff delays. When the system is under rate limit pressure
# (multiple rate limit events across sessions), delays are escalated to allow
# recovery.
#
# Normal backoff: 5s, 15s, 30s, 60s, 120s, 300s
# Escalated backoff (under pressure): 60s, 180s, 300s (then 300s for remaining)
#
# The service follows the same pattern as SigtermRetryService:
# - Detects API errors from transcript (server errors + rate limits)
# - Records rate limit events in GlobalRateLimitTracker for cross-session awareness
# - Tracks retry attempts in session metadata
# - Spawns a new Claude CLI process via resume
# - Verifies the new process stays running
#
# Usage:
#   service = ApiErrorRetryService.new(
#     session,
#     cli_adapter: ClaudeCliAdapter.new,
#     process_manager: SystemProcessManager.new,
#     log_buffer: log_buffer,
#     file_system: RealFileSystemAdapter.new
#   )
#   result = service.attempt_retry(working_directory)
#   # Returns :success, :exhausted, :aborted, :not_applicable, or :quota_exceeded
#
# Quota limits vs transient rate limits:
#   The service distinguishes between transient burst rate limits (429s that clear
#   in minutes) and daily/weekly account quota limits (that require hours of waiting).
#   Transient rate limits are retried with backoff. Quota limits are NOT retried —
#   the service returns :quota_exceeded so the caller can fail the session immediately
#   with a clear message instead of wasting retry attempts.
#
class ApiErrorRetryService
  include DatabaseRetry

  # Maximum retry attempts for API errors
  MAX_RETRIES = 6

  # Exponential backoff delays (seconds) for each retry attempt under normal conditions
  # Total worst-case: 5 + 15 + 30 + 60 + 120 + 300 = 530s (~9 min across all retries)
  # But each retry may succeed, so typical case is much shorter.
  RETRY_DELAYS = [ 5, 15, 30, 60, 120, 300 ].freeze

  # Maximum delay for a single retry (5 minutes)
  MAX_SINGLE_DELAY = 300

  # Minimum time (seconds) a process must run before retry is considered successful
  SUCCESS_THRESHOLD = 5

  # Interval (seconds) for checking session status during long delays
  STATUS_CHECK_INTERVAL = 10

  # Error patterns that indicate API server errors (transient, retryable)
  # These match various API error types from the Anthropic API that indicate
  # server-side issues rather than client-side problems.
  API_SERVER_ERROR_PATTERNS = [
    /api_error/i,
    /internal.server.error/i,
    /overloaded/i,
    /\b529\b/,
    /\b500\b/,
    /\b502\b/,
    /\b503\b/,
    /service.unavailable/i,
    /bad.gateway/i,
    /gateway.timeout/i
  ].freeze

  # Error patterns that indicate rate limiting (transient, retryable with longer backoff)
  # These are distinct from server errors - they indicate the client is sending
  # too many requests and needs to slow down.
  RATE_LIMIT_ERROR_PATTERNS = [
    /rate.limit/i,
    /too.many.requests/i,
    /\b429\b/,
    /request.limit/i
  ].freeze

  # Pattern for account usage limits (session / weekly / overall) that should NOT
  # be retried. These errors require hours of waiting (until the reset time) —
  # retrying after seconds is pointless and wastes retry attempts. The caller
  # rotates to another account on :quota_exceeded, so each account's independent
  # limit window is used before the session fails.
  #
  # The Claude CLI's limit wording is a moving target (see
  # docs/CLAUDE_CODE_OAUTH_ASSUMPTIONS.md → "Usage-limit message formats"). It has
  # introduced a descriptor word between "your" and "limit" ("session", "weekly"),
  # so the pattern must NOT require the literal "hit your limit". The bug this
  # guards against: "You've hit your session limit · resets 5:50pm (UTC)" failed
  # the old /hit your limit.*resets/i regex, was misclassified as a transient
  # rate limit, retried 6× and failed the session without ever rotating
  # (prod incident 2026-06-14, sessions 8093/8106/8154/8161-8165).
  #
  # Known message formats from production:
  #   "You've hit your limit · resets 5pm (UTC)"
  #   "You've hit your limit · resets Jan 15, 6pm (UTC)"
  #   "You've hit your session limit · resets 5:50pm (UTC)"
  #   "You've hit your weekly limit · resets Jan 15, 6pm (UTC)"
  #
  # Anchored on "hit your … limit … resets" so transient rate-limit messages
  # ("Rate limit reached", "429 Too Many Requests") — which never carry an
  # explicit reset time — keep flowing through the retry-with-backoff path.
  ACCOUNT_QUOTA_LIMIT_PATTERN = /hit your\b.*\blimit\b.*\bresets\b/i

  # Error types from the API that indicate server errors (as opposed to client errors)
  API_SERVER_ERROR_TYPES = %w[api_error overloaded_error server_error].freeze

  # Error types from the API that indicate rate limiting
  RATE_LIMIT_ERROR_TYPES = %w[rate_limit_error].freeze

  # Combined error types for detection (server errors + rate limits)
  RETRYABLE_ERROR_TYPES = (API_SERVER_ERROR_TYPES + RATE_LIMIT_ERROR_TYPES).freeze

  attr_reader :session, :cli_adapter, :process_manager, :log_buffer, :file_system, :rate_limit_tracker

  def initialize(session, cli_adapter:, process_manager:, log_buffer:, file_system: nil, rate_limit_tracker: nil)
    @session = session
    @cli_adapter = cli_adapter
    @process_manager = process_manager
    @log_buffer = log_buffer
    @file_system = file_system || RealFileSystemAdapter.new
    @rate_limit_tracker = rate_limit_tracker || GlobalRateLimitTracker.new
    @logger = StructuredLogger.new({ session_id: session.id, service: "ApiErrorRetryService" })
    @detected_rate_limit = false
    @detected_quota_limit = false
  end

  # Attempt to retry the session after a retryable API error (server error or rate limit)
  #
  # @param working_directory [String] The working directory for the session
  # @return [Symbol] :success if retry succeeded, :exhausted if all retries failed,
  #                  :aborted if session state changed, :not_applicable if no API error detected,
  #                  :quota_exceeded if daily/weekly account quota limit detected
  def attempt_retry(working_directory)
    return :not_applicable unless retryable_api_error_detected?(working_directory)

    # If a daily/weekly quota limit was detected, do NOT retry — it requires hours of waiting
    if @detected_quota_limit
      add_log(
        "Account quota limit detected (not a transient rate limit) — retrying would be futile. " \
          "The quota resets at the time indicated in the error message. Skipping retry.",
        level: "warning"
      )
      log_buffer.flush
      @logger.warn("Account quota limit detected, skipping retry",
        session_id: session.id)

      # Record the quota limit event in session metadata for health dashboard visibility.
      # IMPORTANT: Also advance api_error_last_checked_line so that when the session is
      # resumed later, the detection scan starts AFTER this quota limit entry. Without this,
      # the old quota entry would be re-detected on the next run, causing any subsequent
      # transient rate limit to be misclassified as a quota limit (because the scan hits
      # the old quota entry first).
      with_db_retry do
        session.update!(
          metadata: (session.metadata || {}).merge(
            "last_quota_limit_at" => Time.current.iso8601,
            "last_quota_limit_message" => @detected_quota_message,
            "quota_limit_count" => (session.metadata&.dig("quota_limit_count") || 0) + 1,
            "api_error_last_checked_line" => get_transcript_line_count(working_directory)
          )
        )
      end

      return :quota_exceeded
    end

    execute_retry(working_directory)
  end

  # Check if the transcript contains a retryable API error (server error or rate limit)
  #
  # This is exposed as a public method so ProcessLifecycleManager can check
  # for API errors before deciding to invoke this service.
  #
  # Scans ALL lines after api_error_last_checked_line and uses the LAST (most
  # recent) API error for classification. This prevents old quota limit entries
  # from shadowing newer transient rate limit errors — which would cause the
  # service to skip retries when it should be retrying.
  #
  # @param working_directory [String] Working directory for locating transcript
  # @return [Boolean] true if a retryable API error was detected in the transcript
  def retryable_api_error_detected?(working_directory)
    return false unless working_directory

    transcript_path = find_transcript_path(working_directory)
    return false unless transcript_path
    return false unless file_system.exists?(transcript_path)

    content = file_system.read(transcript_path)
    return false if content.blank?

    # Only check lines after the last checked position to avoid re-detecting old errors
    last_checked_line = session.metadata&.dig("api_error_last_checked_line") || 0
    lines = content.lines
    current_line_number = 0

    # Track the most recent API error found (not the first) so that old errors
    # don't shadow newer ones. For example, an old quota limit at line 500 should
    # not prevent retrying a new transient rate limit at line 900.
    last_match = nil

    lines.each do |line|
      current_line_number += 1
      next if current_line_number <= last_checked_line
      next if line.strip.blank?

      begin
        entry = JSON.parse(line)

        # Check for API error messages (isApiErrorMessage: true)
        next unless entry["isApiErrorMessage"] == true

        # Check if the error type indicates a retryable error
        error_type = entry["error"].to_s
        message_text = extract_message_text(entry)

        # Match retryable error types OR error patterns in the message
        if retryable_error?(error_type, message_text)
          is_rate_limit = rate_limit_error?(error_type, message_text)
          is_quota_limit = account_quota_limit?(message_text)

          last_match = {
            line_number: current_line_number,
            error_type: error_type,
            is_rate_limit: is_rate_limit,
            is_quota_limit: is_quota_limit,
            message_text: message_text
          }
        end
      rescue JSON::ParserError
        next
      end
    end

    if last_match
      error_category = if last_match[:is_quota_limit]
        "account_quota_limit"
      elsif last_match[:is_rate_limit]
        "rate_limit"
      else
        "server_error"
      end

      @logger.info("API #{error_category} detected in transcript (most recent match)",
        line_number: last_match[:line_number], error_type: last_match[:error_type])
      @detected_rate_limit = last_match[:is_rate_limit] && !last_match[:is_quota_limit]
      @detected_quota_limit = last_match[:is_quota_limit]
      @detected_quota_message = last_match[:message_text] if last_match[:is_quota_limit]
      return true
    end

    false
  rescue => e
    @logger.error("Error checking transcript for API error", error: e.message)
    false
  end

  private

  # Spawn a new process and verify it stays running
  #
  # @param working_directory [String] The working directory
  # @param retry_attempt [Integer] Current retry attempt number
  # @return [Symbol] :success, :exhausted, :aborted
  def spawn_and_verify_retry(working_directory, retry_attempt)
    # Final status check before spawning
    abort_result = check_session_status
    return :aborted if abort_result == :aborted

    add_log("Resuming session after API error", level: "info")

    # Always resume (not fresh start) - API errors only occur during active conversations
    # since they require at least one API call to have been made.
    # Regenerate system prompt for retry consistency
    system_prompt = OrchestratorSystemPromptBuilder.build(
      session: session,
      clone_path: session.metadata&.dig("clone_path")
    )

    spawn_result = cli_adapter.resume(
      session_id: session.session_id,
      prompt: AutomatedPrompts::SYSTEM_RECOVERY,
      working_dir: working_directory,
      append_system_prompt: system_prompt,
      model: session.config&.dig("model"),
      auto_compact_window: session.auto_compact_window
    )

    new_pid = spawn_result[:pid]

    add_log(
      "Spawned new Claude CLI process with PID #{new_pid} for API error retry attempt #{retry_attempt}",
      level: "info"
    )

    # Update session metadata with new process PID
    with_db_retry do
      session.update!(
        metadata: (session.metadata || {}).merge("process_pid" => new_pid)
      )
    end

    # Verify the process stays running
    if verify_process_running(new_pid, retry_attempt)
      add_log(
        "API error retry #{retry_attempt} successful - process #{new_pid} verified running for #{SUCCESS_THRESHOLD}s",
        level: "info"
      )
      log_buffer.flush
      @logger.info("API error retry successful", retry_attempt: retry_attempt, new_pid: new_pid)
      return :success
    end

    # Process died during verification - try next retry
    attempt_next_retry(working_directory)
  rescue => e
    if retry_attempt >= MAX_RETRIES
      # Final attempt failed and no retries remain — this is a genuine failure,
      # so log at error (which surfaces to GlitchTip, with a backtrace).
      add_log(
        "Error during API error retry attempt #{retry_attempt}: #{e.message}",
        level: "error"
      )
      log_buffer.flush
      @logger.error("Error during API error retry", retry_attempt: retry_attempt, error: e.message, exception: e)
      return :exhausted
    end

    # Intermediate attempt failed but retries remain; this is expected/transient
    # and will self-resolve on the next attempt, so log at info (no alert).
    add_log(
      "Error during API error retry attempt #{retry_attempt}: #{e.message}",
      level: "info"
    )
    log_buffer.flush
    @logger.info("Error during API error retry", retry_attempt: retry_attempt, error: e.message)
    attempt_next_retry(working_directory)
  end

  # Continue to next retry (skips detection since we already know there's an error)
  #
  # @param working_directory [String] The working directory
  # @return [Symbol] :success, :exhausted, :aborted
  def attempt_next_retry(working_directory)
    execute_retry(working_directory)
  end

  # Shared retry logic: check count, wait with backoff, update metadata, spawn
  #
  # Uses GlobalRateLimitTracker for adaptive delays. When rate limit errors are
  # detected, the event is recorded in the tracker. When the system is under
  # rate limit pressure (multiple events across sessions), delays are escalated.
  #
  # @param working_directory [String] The working directory
  # @return [Symbol] :success, :exhausted, :aborted
  def execute_retry(working_directory)
    current_retry_count = session.reload.metadata&.dig("api_error_retry_count") || 0

    if current_retry_count >= MAX_RETRIES
      add_log("API error retry limit reached (#{MAX_RETRIES} attempts)", level: "warning")
      return :exhausted
    end

    retry_attempt = current_retry_count + 1

    # Record event in global rate limit tracker only for actual rate limit errors
    # Server errors (500/502/503) should not escalate delays for other sessions
    rate_limit_tracker.record_event if @detected_rate_limit

    # Use adaptive delay: if system is under rate limit pressure, use escalated delays
    # from the global tracker; otherwise use fixed exponential backoff
    retry_delay = if rate_limit_tracker.under_pressure?
      rate_limit_tracker.recommended_delay(attempt: current_retry_count)
    else
      RETRY_DELAYS[current_retry_count] || MAX_SINGLE_DELAY
    end

    # Determine error category for logging
    error_category = @detected_rate_limit ? "Rate limit" : "API server error"

    # Log rate limit pressure status for visibility
    if rate_limit_tracker.under_pressure?
      recent_count = rate_limit_tracker.recent_event_count
      add_log(
        "System under rate limit pressure (#{recent_count} events in last 5 min) - using escalated delays",
        level: "warning"
      )
    end

    add_log(
      "#{error_category} detected - attempting auto-retry #{retry_attempt}/#{MAX_RETRIES}" \
        " after #{retry_delay}s delay",
      level: "warning"
    )
    log_buffer.flush

    # Wait with periodic session status checks
    abort_result = wait_with_status_checks(retry_delay)
    return :aborted if abort_result == :aborted

    # Record retry attempt in metadata
    with_db_retry do
      session.update!(
        metadata: (session.metadata || {}).merge(
          "api_error_retry_count" => retry_attempt,
          "last_api_error_retry_at" => Time.current.iso8601,
          "api_error_last_checked_line" => get_transcript_line_count(working_directory)
        )
      )
    end

    spawn_and_verify_retry(working_directory, retry_attempt)
  end

  # Verify a process stays running for the success threshold
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
          "API error retry attempt #{retry_attempt} failed - process #{pid} died after #{elapsed.round(1)}s",
          level: "warning"
        )
        return false
      end

      return true if elapsed >= SUCCESS_THRESHOLD

      sleep(0.5)
    end
  end

  # Wait for the specified delay, checking session status periodically
  #
  # @param delay [Integer] Total delay in seconds
  # @return [Symbol, nil] :aborted if session state changed, nil otherwise
  def wait_with_status_checks(delay)
    return nil unless delay.positive?

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
        "Session state changed to #{session.status} during API error retry, aborting",
        level: "warning"
      )
      return :aborted
    end
    nil
  end

  # Find the transcript file path for the session
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
  def calculate_transcript_directory(working_directory)
    return nil unless working_directory

    require "path_sanitizer"
    home_dir = File.expand_path("~")
    claude_projects_dir = File.join(home_dir, ".claude", "projects")
    sanitized_path = PathSanitizer.sanitize(working_directory)
    File.join(claude_projects_dir, sanitized_path)
  rescue => e
    @logger.error("Error calculating transcript directory", error: e.message)
    nil
  end

  # Extract text content from a transcript message entry
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

  # Check if an error is retryable (server error or rate limit)
  #
  # @param error_type [String] The error type from the transcript entry
  # @param message_text [String] The message text from the transcript entry
  # @return [Boolean] true if the error is retryable
  def retryable_error?(error_type, message_text)
    # Check retryable error types (server errors + rate limits)
    return true if RETRYABLE_ERROR_TYPES.include?(error_type)

    # Check server error patterns in message or error type
    return true if API_SERVER_ERROR_PATTERNS.any? { |pattern| message_text.match?(pattern) }
    return true if API_SERVER_ERROR_PATTERNS.any? { |pattern| error_type.match?(pattern) }

    # Check rate limit patterns in message or error type
    return true if RATE_LIMIT_ERROR_PATTERNS.any? { |pattern| message_text.match?(pattern) }
    return true if RATE_LIMIT_ERROR_PATTERNS.any? { |pattern| error_type.match?(pattern) }

    false
  end

  # Check if the error is specifically a rate limit error (vs server error)
  #
  # @param error_type [String] The error type from the transcript entry
  # @param message_text [String] The message text from the transcript entry
  # @return [Boolean] true if the error is a rate limit error
  def rate_limit_error?(error_type, message_text)
    return true if RATE_LIMIT_ERROR_TYPES.include?(error_type)
    return true if RATE_LIMIT_ERROR_PATTERNS.any? { |pattern| message_text.match?(pattern) }
    return true if RATE_LIMIT_ERROR_PATTERNS.any? { |pattern| error_type.match?(pattern) }

    false
  end

  # Check if the error is an account usage limit (session / weekly / overall),
  # as opposed to a transient rate limit. These require hours of waiting and must
  # NOT be retried with short backoff — see ACCOUNT_QUOTA_LIMIT_PATTERN for the
  # known message formats and the moving-target history.
  #
  # @param message_text [String] The message text from the transcript entry
  # @return [Boolean] true if the error is an account usage limit
  def account_quota_limit?(message_text)
    message_text.match?(ACCOUNT_QUOTA_LIMIT_PATTERN)
  end

  # Add log entry via log buffer
  def add_log(content, level: "info")
    log_buffer.add(content, level: level)
  end
end
