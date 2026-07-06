# frozen_string_literal: true

require "automated_prompts"

# Service for recovering an in-flight session after its on-disk login identity
# was invalidated mid-run — typically by Zimmer rotating the active Claude account
# (e.g. on quota exhaustion via AccountRotationService) while this session's CLI
# process was still running.
#
# == The failure this recovers ==
#
# Zimmer keeps one active account's credentials written to the runtime's canonical
# filesystem location. When Zimmer rotates accounts, any session whose CLI is
# mid-turn makes its next API call against credentials that are no longer valid
# for it, and Claude Code records a synthetic API error in the transcript:
#
#   {"type":"assistant","isApiErrorMessage":true,
#    "message":{"content":[{"type":"text","text":"Not logged in · Please run /login"}]}}
#
# The CLI then exits. This text matches none of ApiErrorRetryService's retryable
# patterns (it is not a 5xx / 429 / quota message), so without this service the
# session falls through to a permanent :failed — even though the fix is simply to
# re-write the current active account's credentials to disk and resume.
#
# == How recovery works ==
#
# 1. Detect the "Not logged in / Please run /login" signature as the most recent
#    API-error entry in the transcript (auth_error_detected?).
# 2. Reconcile the worker's on-disk identity to the current active account via
#    RuntimeAuthProvider#inject_for_session! — the same seam AuthWarmupService
#    uses before every spawn. If that returns nil, NO valid account is available;
#    this is genuinely unrecoverable, so we fail cleanly (:unrecoverable) without
#    looping rather than re-spawning into the same error forever.
# 3. Re-spawn the session via resume and verify the new process stays running.
#
# Bounded by MAX_RECOVERY_ATTEMPTS consecutive failures. The counter is reset to
# zero on a verified success so a long-running session that legitimately survives
# many account rotations over its lifetime is never killed by a lifetime cap —
# only a tight loop of back-to-back failed recoveries is.
#
# This mirrors ApiErrorRetryService's structure (transcript detection + bounded
# retry + spawn/verify + line-marker tracking) deliberately: the auth error is
# recorded the same way (isApiErrorMessage: true), so detection is a sibling of
# that service rather than folded into it — keeping the carefully tuned API
# backoff/quota logic untouched.
#
# Usage:
#   service = AuthRecoveryService.new(
#     session,
#     cli_adapter: ClaudeCliAdapter.new,
#     process_manager: SystemProcessManager.new,
#     log_buffer: log_buffer,
#     file_system: RealFileSystemAdapter.new
#   )
#   result = service.attempt_recovery(working_directory)
#   # Returns :success, :exhausted, :unrecoverable, :aborted, or :not_applicable
class AuthRecoveryService
  include DatabaseRetry

  # Maximum consecutive recovery attempts before giving up. Reset to zero on a
  # verified success (see class docs) so the cap bounds tight failure loops, not
  # a session's lifetime count of legitimate rotations.
  MAX_RECOVERY_ATTEMPTS = 3

  # Short settle delay (seconds) before re-spawning. Unlike API/rate-limit
  # backoff, the corrective action (re-writing credentials) is already complete
  # by the time we re-spawn, so there is nothing to wait out — a brief pause just
  # lets filesystem writes settle.
  RETRY_DELAY = 2

  # Minimum time (seconds) a re-spawned process must stay running before the
  # recovery is considered successful.
  SUCCESS_THRESHOLD = 5

  # Pattern identifying the rotation-induced auth failure. Claude Code renders the
  # CLI's "Not logged in" state as a synthetic API error; the message text is a
  # moving target, so match either half of the signature independently:
  #   "Not logged in · Please run /login"
  AUTH_RECOVERABLE_ERROR_PATTERN = /not logged in|please run\s*\/login/i

  attr_reader :session, :cli_adapter, :process_manager, :log_buffer, :file_system

  def initialize(session, cli_adapter:, process_manager:, log_buffer:, file_system: nil, auth_provider: nil)
    @session = session
    @cli_adapter = cli_adapter
    @process_manager = process_manager
    @log_buffer = log_buffer
    @file_system = file_system || RealFileSystemAdapter.new
    @auth_provider = auth_provider
    @logger = StructuredLogger.new({ session_id: session.id, service: "AuthRecoveryService" })
  end

  # Attempt to recover the session after a rotation-induced auth failure.
  #
  # @param working_directory [String] The working directory for the session
  # @return [Symbol] :success if the re-spawn was verified running,
  #                  :exhausted if MAX_RECOVERY_ATTEMPTS consecutive tries failed,
  #                  :unrecoverable if no valid account is available to recover to,
  #                  :aborted if the session state changed mid-recovery,
  #                  :not_applicable if no auth error is present in the transcript
  def attempt_recovery(working_directory)
    return :not_applicable unless auth_error_detected?(working_directory)

    execute_recovery(working_directory)
  end

  # Check whether the MOST RECENT API-error entry in the transcript is the
  # recoverable "Not logged in / Please run /login" signature.
  #
  # Exposed as a public method so ClaudeRetryStrategy#auth_recovery_needed? can
  # gate on it before ProcessLifecycleManager routes to this service.
  #
  # We consider only the LAST isApiErrorMessage entry (after the line marker) so
  # that "most recent error wins": a stale auth entry followed by a newer 5xx is
  # NOT treated as an auth failure (ApiErrorRetryService handles the 5xx), and a
  # newer auth entry following an older 5xx IS treated as an auth failure.
  #
  # @param working_directory [String] Working directory for locating the transcript
  # @return [Boolean] true if the latest API error is a recoverable auth error
  def auth_error_detected?(working_directory)
    return false unless working_directory

    transcript_path = find_transcript_path(working_directory)
    return false unless transcript_path
    return false unless file_system.exists?(transcript_path)

    content = file_system.read(transcript_path)
    return false if content.blank?

    last_checked_line = session.metadata&.dig("auth_error_last_checked_line") || 0
    current_line_number = 0
    last_api_error_text = nil

    content.lines.each do |line|
      current_line_number += 1
      next if current_line_number <= last_checked_line
      next if line.strip.blank?

      begin
        entry = JSON.parse(line)
        next unless entry["isApiErrorMessage"] == true

        # Track the most recent API error's text (regardless of kind) so a later
        # non-auth error correctly shadows an earlier auth one.
        last_api_error_text = "#{entry["error"]} #{extract_message_text(entry)}"
      rescue JSON::ParserError
        next
      end
    end

    return false if last_api_error_text.nil?

    if last_api_error_text.match?(AUTH_RECOVERABLE_ERROR_PATTERN)
      @logger.info("Recoverable auth error detected in transcript (most recent API error)",
        line_number: current_line_number)
      return true
    end

    false
  rescue => e
    @logger.error("Error checking transcript for auth error", error: e.message)
    false
  end

  private

  # The auth provider for this session's runtime. Lazily resolved so tests can
  # inject a fake; production resolves the real provider for the runtime.
  def auth_provider
    @auth_provider ||= RuntimeAuthProvider.for(session.agent_runtime)
  end

  # Shared recovery logic: check count, refresh identity, wait briefly, then spawn.
  #
  # @param working_directory [String] The working directory
  # @return [Symbol] :success, :exhausted, :unrecoverable, :aborted
  def execute_recovery(working_directory)
    current_count = session.reload.metadata&.dig("auth_recovery_count") || 0

    if current_count >= MAX_RECOVERY_ATTEMPTS
      add_log("Auth recovery limit reached (#{MAX_RECOVERY_ATTEMPTS} attempts) — failing", level: "warning")
      log_buffer.flush
      @logger.warn("Auth recovery limit reached", attempts: current_count)
      return :exhausted
    end

    retry_attempt = current_count + 1

    # Reconcile the worker's on-disk identity to the current active account. nil
    # means no valid account is available — genuinely unrecoverable, so fail
    # cleanly WITHOUT re-spawning into the same error.
    account = refresh_identity!(working_directory)
    unless account
      add_log(
        "Not logged in and no valid account available to recover — failing cleanly " \
          "(re-authenticate an account to restore service). No retry attempted.",
        level: "warning"
      )
      log_buffer.flush
      @logger.warn("Auth recovery unrecoverable: no valid account available")
      # Advance the marker so a later manual resume doesn't immediately
      # re-detect this same entry and loop.
      advance_checked_line(working_directory)
      return :unrecoverable
    end

    add_log(
      "Not logged in detected (active account likely rotated mid-session) — " \
        "refreshed on-disk identity to #{account.email}, retrying #{retry_attempt}/#{MAX_RECOVERY_ATTEMPTS}",
      level: "warning"
    )
    log_buffer.flush
    @logger.info("Auth recovery: identity refreshed, retrying", retry_attempt: retry_attempt, account: account.email)

    abort_result = wait_with_status_checks(RETRY_DELAY)
    return :aborted if abort_result == :aborted

    # Record the attempt and advance the line marker so this auth entry isn't
    # re-detected after the re-spawn.
    with_db_retry do
      session.update!(
        metadata: (session.metadata || {}).merge(
          "auth_recovery_count" => retry_attempt,
          "last_auth_recovery_at" => Time.current.iso8601,
          "auth_error_last_checked_line" => get_transcript_line_count(working_directory)
        )
      )
    end

    spawn_and_verify_recovery(working_directory, retry_attempt)
  end

  # Re-write the active account's credentials to disk via the runtime auth
  # provider. Returns the account on success, nil if none is available.
  def refresh_identity!(working_directory)
    auth_provider.inject_for_session!(session, working_directory)
  rescue => e
    @logger.error("Auth recovery: identity refresh raised", error: e.message)
    add_log("Failed to refresh login identity during auth recovery: #{e.message}", level: "warning")
    nil
  end

  # Spawn a new process and verify it stays running.
  #
  # @param working_directory [String] The working directory
  # @param retry_attempt [Integer] Current attempt number
  # @return [Symbol] :success, :exhausted, :unrecoverable, :aborted
  def spawn_and_verify_recovery(working_directory, retry_attempt)
    abort_result = check_session_status
    return :aborted if abort_result == :aborted

    add_log("Resuming session after refreshing login identity", level: "info")

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
      "Spawned new CLI process with PID #{new_pid} for auth recovery attempt #{retry_attempt}",
      level: "info"
    )

    with_db_retry do
      session.update!(
        metadata: (session.metadata || {}).merge("process_pid" => new_pid)
      )
    end

    if verify_process_running(new_pid, retry_attempt)
      add_log(
        "Auth recovery #{retry_attempt} successful — process #{new_pid} verified running for #{SUCCESS_THRESHOLD}s",
        level: "info"
      )
      # Reset the consecutive-failure counter so future independent rotations over
      # this session's lifetime each get a fresh recovery budget.
      with_db_retry do
        session.update!(
          metadata: (session.metadata || {}).merge("auth_recovery_count" => 0)
        )
      end
      log_buffer.flush
      @logger.info("Auth recovery successful", retry_attempt: retry_attempt, new_pid: new_pid)
      return :success
    end

    # Process died during verification — try again (bounded by the count check).
    execute_recovery(working_directory)
  rescue => e
    if retry_attempt >= MAX_RECOVERY_ATTEMPTS
      add_log("Error during auth recovery attempt #{retry_attempt}: #{e.message}", level: "error")
      log_buffer.flush
      @logger.error("Error during auth recovery", retry_attempt: retry_attempt, error: e.message, exception: e)
      return :exhausted
    end

    add_log("Error during auth recovery attempt #{retry_attempt}: #{e.message}", level: "info")
    log_buffer.flush
    @logger.info("Error during auth recovery (will retry)", retry_attempt: retry_attempt, error: e.message)
    execute_recovery(working_directory)
  end

  # Verify a process stays running for the success threshold.
  def verify_process_running(pid, retry_attempt)
    process_start_time = Time.current

    loop do
      elapsed = Time.current - process_start_time

      unless process_manager.running?(pid)
        add_log(
          "Auth recovery attempt #{retry_attempt} failed — process #{pid} died after #{elapsed.round(1)}s",
          level: "warning"
        )
        return false
      end

      return true if elapsed >= SUCCESS_THRESHOLD

      sleep(0.5)
    end
  end

  # Wait for the delay, checking session status periodically.
  def wait_with_status_checks(delay)
    return nil unless delay.positive?

    sleep(delay)
    check_session_status
  end

  # Check if the session is still running.
  def check_session_status
    session.reload
    unless session.running?
      add_log("Session state changed to #{session.status} during auth recovery, aborting", level: "warning")
      return :aborted
    end
    nil
  end

  # Advance the auth line marker to the current transcript length without
  # re-spawning. Used on the unrecoverable path so a later manual resume doesn't
  # re-detect the same entry.
  def advance_checked_line(working_directory)
    with_db_retry do
      session.update!(
        metadata: (session.metadata || {}).merge(
          "auth_error_last_checked_line" => get_transcript_line_count(working_directory)
        )
      )
    end
  rescue => e
    @logger.error("Error advancing auth line marker", error: e.message)
  end

  # Find the transcript file path for the session.
  def find_transcript_path(working_directory)
    transcript_dir = calculate_transcript_directory(working_directory)
    return nil unless transcript_dir
    return nil unless file_system.directory?(transcript_dir)

    TranscriptFileLocator.find_main_transcript(session, transcript_dir, file_system: file_system)
  rescue => e
    @logger.error("Error finding transcript path", error: e.message)
    nil
  end

  # Calculate the transcript directory path from the working directory.
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

  # Extract text content from a transcript message entry.
  def extract_message_text(entry)
    message = entry["message"]
    return "" unless message.is_a?(Hash)

    content = message["content"]
    return "" unless content.is_a?(Array)

    content.filter_map do |block|
      block["text"] if block.is_a?(Hash) && block["type"] == "text"
    end.join(" ")
  end

  # Get the current line count of the transcript file.
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

  # Add a log entry via the log buffer.
  def add_log(content, level: "info")
    log_buffer.add(content, level: level)
  end
end
