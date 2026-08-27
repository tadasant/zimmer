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
# 1. Detect an authentication failure as the most recent API-error entry in the
#    transcript (auth_error_detected?) — by the entry's structured `error` type
#    first, and by its prose second. See AUTH_ERROR_TYPES.
# 2. Ask AuthRecoveryCoordinator what to do about it. Recovery used to mean
#    "re-inject the current active account" unconditionally, which re-spawned
#    into the identical wall whenever that account was itself the problem. The
#    coordinator instead decides, under a pool-wide lock, between adopting a
#    rotation someone else already ran, re-seeding a stale session-scoped child,
#    rotating the pool itself, waiting out a rotation in flight, and giving up
#    with the park reason the pool's shape justifies. Its class docs carry the
#    full decision tree.
# 3. Re-spawn the session via resume and verify the new process stays running.
#
# Bounded by MAX_RECOVERY_ATTEMPTS attempts within CONSECUTIVE_WINDOW, so a
# long-running session that legitimately survives many account rotations over its
# lifetime is never killed by a lifetime cap — only a tight loop of back-to-back
# failed recoveries is.
#
# An adoption is exempt from that budget: it is another session's rotation doing
# this one a favour, not an attempt this session made, and charging for it would
# park a healthy long-running session for the fleet's activity. Adoptions are
# separately capped at MAX_FREE_ADOPTIONS per window so a pool churning under a
# session can't buy it unlimited free re-spawns.
#
# == Why the bound is time-based and not success-based ==
#
# A re-spawned process staying alive is NOT evidence that recovery worked. A
# Claude Code process spends its first 10-15 seconds connecting MCP servers
# before it makes the API call that reports "Not logged in", so it clears any
# short liveness bar every single time — including when the injected credentials
# are dead. Resetting the attempt counter on that signal makes it oscillate
# 0 → 1 → 0, putting MAX_RECOVERY_ATTEMPTS permanently out of reach: production
# session 684 logged "retrying 1/3" 115 times over 35 minutes, re-spawning the
# CLI into the same auth wall roughly every 18 seconds.
#
# So liveness only gates whether monitoring continues (a process that dies
# instantly is retried sooner); the elapsed time since the last attempt is what
# decides whether this is a fresh incident or the same one looping. The counter
# is cleared by a genuinely completed turn, in SessionStateMachine's pause
# callback — the one place that knows the process got past the wall.
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
#   # Returns :success, :exhausted, :unrecoverable, :pool_quota_exhausted,
#   #         :aborted, or :not_applicable
class AuthRecoveryService
  include DatabaseRetry

  # Maximum recovery attempts within CONSECUTIVE_WINDOW before giving up.
  MAX_RECOVERY_ATTEMPTS = 3

  # Maximum budget-free adoptions (see class docs) within CONSECUTIVE_WINDOW.
  # Beyond this an adoption starts costing budget: a session adopting this often
  # means the pool is churning under it, and a free retry that never converges is
  # the exact shape of the loop MAX_RECOVERY_ATTEMPTS exists to stop.
  MAX_FREE_ADOPTIONS = 3

  # Attempts further apart than this are treated as separate incidents and the
  # counter starts over. Sized well above a single recovery cycle (a couple of
  # seconds of settle plus however long the re-spawned process survives) so a
  # tight loop always accumulates, while a session that hits an unrelated
  # rotation an hour later gets a fresh budget.
  CONSECUTIVE_WINDOW = 15.minutes

  # Short settle delay (seconds) before re-spawning. Unlike API/rate-limit
  # backoff, the corrective action (re-writing credentials) is already complete
  # by the time we re-spawn, so there is nothing to wait out — a brief pause just
  # lets filesystem writes settle.
  RETRY_DELAY = 2

  # Minimum time (seconds) a re-spawned process must stay running before the
  # recovery is considered successful.
  SUCCESS_THRESHOLD = 5

  # The error TYPES Claude Code stamps on a transcript entry when a turn dies for
  # an authentication reason. This is the machine-readable half of the signature,
  # and the half that does not move when the prose does.
  #
  # Reading it is the fix for the 2026-08-20 incident (session 6412): the runtime
  # recorded
  #
  #   {"isApiErrorMessage":true,"error":"authentication_failed",
  #    "message":{"content":[{"type":"text",
  #      "text":"Failed to authenticate: OAuth session expired and could not be refreshed"}]}}
  #
  # whose text matched none of the prose below, so no classifier claimed it, and
  # the turn — a human's unanswered message — was parked as if it had completed.
  AUTH_ERROR_TYPES = %w[authentication_failed oauth_error].freeze

  # Prose fallback, for entries the runtime records with an EMPTY error type —
  # which is how "Not logged in · Please run /login" is recorded. Each
  # alternative is one half of a known signature rather than a whole sentence,
  # because the wording around it is a moving target.
  #
  # This net is deliberately secondary, and deliberately wide: it answers "should
  # this session rotate accounts?", where a false positive costs one rotation and
  # a false negative costs a lost turn. Do not borrow it for a question with the
  # opposite cost profile — SessionStatusSummaryHarvestJob spells out its own two
  # patterns for exactly that reason. A pattern over Anthropic's prose is the
  # thing that went stale in the 2026-08-20 incident, and
  # ApiErrorRetryService#terminal_api_error is the backstop for the next time.
  AUTH_RECOVERABLE_ERROR_PATTERN = Regexp.union(
    /not logged in/i,
    /please run\s*\/login/i,
    /failed to authenticate/i,
    /authentication[ _]failed/i,
    /(?:oauth|refresh|access|session)[ _](?:session|token)\b.{0,40}\b(?:expired|invalid|revoked)/i,
    /invalid_grant/i
  ).freeze

  # Whether a transcript API-error entry is an authentication failure this service
  # can act on.
  #
  # Takes the entry's error TYPE and its TEXT separately so a caller cannot ask
  # with only the half that moves. Also used by ApiErrorRetryService to answer
  # "is this accounted for by a sibling classifier?".
  #
  # @param error_type [String, nil] the entry's `error` field
  # @param message_text [String, nil] the entry's rendered text content
  def self.auth_error?(error_type, message_text)
    return true if AUTH_ERROR_TYPES.include?(error_type.to_s.strip.downcase)

    # The structured type wins both ways. An entry the API typed as retryable is
    # a transient upstream failure whatever its prose says, and "Authentication
    # failed: 401 from gateway" on an `api_error` must go to backoff retry rather
    # than spend an account rotation. Only entries the runtime left untyped — the
    # ones the prose net exists for — are matched on wording.
    return false if ApiErrorRetryService::RETRYABLE_ERROR_TYPES.include?(error_type.to_s.strip.downcase)

    "#{error_type} #{message_text}".match?(AUTH_RECOVERABLE_ERROR_PATTERN)
  end

  attr_reader :session, :cli_adapter, :process_manager, :log_buffer, :file_system

  def initialize(session, cli_adapter:, process_manager:, log_buffer:, file_system: nil, auth_provider: nil, coordinator: nil)
    @session = session
    @cli_adapter = cli_adapter
    @process_manager = process_manager
    @log_buffer = log_buffer
    @file_system = file_system || RealFileSystemAdapter.new
    @auth_provider = auth_provider
    @coordinator = coordinator
    @logger = StructuredLogger.new({ session_id: session.id, service: "AuthRecoveryService" })
  end

  # Attempt to recover the session after a rotation-induced auth failure.
  #
  # @param working_directory [String] The working directory for the session
  # @return [Symbol] :success if the re-spawn was verified running,
  #                  :exhausted if MAX_RECOVERY_ATTEMPTS consecutive tries failed,
  #                  :unrecoverable if the pool has no usable credentials at all,
  #                  :pool_quota_exhausted if the pool is drained but recoverable
  #                    on a quota reset,
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
    last_api_error = nil

    content.lines.each do |line|
      current_line_number += 1
      next if current_line_number <= last_checked_line
      next if line.strip.blank?

      begin
        entry = JSON.parse(line)
        next unless entry["isApiErrorMessage"] == true

        # Track the most recent API error (regardless of kind) so a later
        # non-auth error correctly shadows an earlier auth one. Type and text are
        # kept apart because the type is the durable half of the signature.
        last_api_error = { type: entry["error"].to_s, text: extract_message_text(entry) }
      rescue JSON::ParserError
        next
      end
    end

    return false if last_api_error.nil?

    if self.class.auth_error?(last_api_error[:type], last_api_error[:text])
      @logger.info("Recoverable auth error detected in transcript (most recent API error)",
        line_number: current_line_number, error_type: last_api_error[:type].presence)
      return true
    end

    false
  rescue => e
    @logger.error("Error checking transcript for auth error", error: e.message)
    false
  end

  private

  # Shared recovery logic: check budget, resolve the identity against the pool,
  # wait briefly, then spawn.
  #
  # The budget is checked BEFORE the coordinator runs, so an out-of-budget
  # session parks without first burning an account on a rotation it has no
  # remaining attempts to use.
  #
  # @param working_directory [String] The working directory
  # @return [Symbol] :success, :exhausted, :unrecoverable, :pool_quota_exhausted, :aborted
  def execute_recovery(working_directory)
    current_count = consecutive_recovery_count

    if current_count >= MAX_RECOVERY_ATTEMPTS
      add_log("Auth recovery limit reached (#{MAX_RECOVERY_ATTEMPTS} attempts) — failing", level: "warning")
      log_buffer.flush
      @logger.warn("Auth recovery limit reached", attempts: current_count)
      return :exhausted
    end

    plan = coordinator.resolve!(working_directory)

    case plan.outcome
    when :quota_exhausted
      add_log(
        "Not logged in, and every account in the pool is over its quota — nothing to rotate into. " \
          "Parking until the quota window resets rather than retrying into the same wall.",
        level: "warning"
      )
      log_buffer.flush
      @logger.warn("Auth recovery: pool drained by quota")
      advance_checked_line(working_directory)
      return :pool_quota_exhausted
    when :unusable
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

    charge_budget = plan.consumes_budget? || free_adoptions_spent?
    retry_attempt = charge_budget ? current_count + 1 : current_count

    add_log(recovery_message(plan, retry_attempt, charge_budget), level: "warning")
    log_buffer.flush
    @logger.info("Auth recovery: identity resolved, retrying",
      outcome: plan.outcome, retry_attempt: retry_attempt, account: plan.account&.email)

    abort_result = wait_with_status_checks(RETRY_DELAY)
    return :aborted if abort_result == :aborted

    # Record the attempt and advance the line marker so this auth entry isn't
    # re-detected after the re-spawn.
    record_attempt!(working_directory, retry_attempt, charge_budget)

    spawn_and_verify_recovery(working_directory, retry_attempt)
  end

  # The user-facing line. Naming which of the three branches fired is the whole
  # point of the fix — "refreshed on-disk identity to X" read identically whether
  # X was a new account or the same dead one.
  def recovery_message(plan, retry_attempt, charge_budget)
    budget = charge_budget ? "retrying #{retry_attempt}/#{MAX_RECOVERY_ATTEMPTS}" : "retrying (no attempt charged)"

    case plan.outcome
    when :adopted
      "Not logged in — the account pool already rotated to #{plan.account.email} while this session was " \
        "running. Adopted it and #{budget}."
    when :reseeded
      "Not logged in — #{plan.detail}. #{budget.capitalize}."
    when :rotated
      "Not logged in — the runtime rejected the active account, so Zimmer #{plan.detail} rather than " \
        "re-injecting credentials that just failed. #{budget.capitalize}."
    else
      "Not logged in — another session's account rotation is still in flight. Waiting for it rather than " \
        "starting a second one, #{budget}."
    end
  end

  # The two clocks are deliberately independent: a run of free adoptions must not
  # keep an old auth_recovery_count alive past CONSECUTIVE_WINDOW (that would let
  # other sessions' rotations park this one), and a run of charged attempts must
  # not keep the adoption cap alive either.
  #
  # The accepted consequence: a pool churning slower than CONSECUTIVE_WINDOW ages
  # the adoption cap out between adoptions, so such a session adopts for free
  # indefinitely. That is the intended reading — an adoption every 16 minutes is a
  # session riding genuine rotations, which is exactly what must not be charged.
  def record_attempt!(working_directory, retry_attempt, charge_budget)
    updates = { "auth_error_last_checked_line" => get_transcript_line_count(working_directory) }

    if charge_budget
      updates["auth_recovery_count"] = retry_attempt
      updates["last_auth_recovery_at"] = Time.current.iso8601
    else
      updates["auth_recovery_adoptions"] = consecutive_adoption_count + 1
      updates["last_auth_adoption_at"] = Time.current.iso8601
    end

    with_db_retry do
      session.update!(metadata: (session.metadata || {}).merge(updates))
    end
  end

  # The number of recovery attempts that belong to the CURRENT incident: the
  # stored counter if the last attempt was recent, zero otherwise. Reading the
  # timestamp rather than resetting the counter on a liveness check is what keeps
  # a genuinely stuck session from looping forever (see class docs).
  def consecutive_recovery_count
    metadata = session.reload.metadata || {}
    count = metadata["auth_recovery_count"].to_i
    return 0 if count.zero?

    last_attempt = parse_time(metadata["last_auth_recovery_at"])
    return count if last_attempt.nil?
    return 0 if last_attempt < CONSECUTIVE_WINDOW.ago

    count
  end

  def parse_time(value)
    return nil if value.blank?

    Time.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end

  # Decides adopt / rotate / wait / park for this session's dead on-disk
  # identity. Injectable so tests can drive each branch without a real pool.
  def coordinator
    @coordinator ||= AuthRecoveryCoordinator.new(session, auth_provider: @auth_provider, logger: @logger)
  end

  # Adoptions that belong to the CURRENT incident, aged out on the same window as
  # the charged attempts.
  def consecutive_adoption_count
    metadata = session.reload.metadata || {}
    count = metadata["auth_recovery_adoptions"].to_i
    return 0 if count.zero?

    last = parse_time(metadata["last_auth_adoption_at"])
    return count if last.nil?
    return 0 if last < CONSECUTIVE_WINDOW.ago

    count
  end

  def free_adoptions_spent?
    consecutive_adoption_count >= MAX_FREE_ADOPTIONS
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
      session.record_agent_process!(new_pid)
    end

    if verify_process_running(new_pid, retry_attempt)
      # Deliberately NOT a "recovery succeeded" signal, and deliberately NOT a
      # reason to reset auth_recovery_count: the process surviving
      # SUCCESS_THRESHOLD seconds only means it got as far as starting up. It
      # may still be about to report the identical auth error on its first API
      # call. The counter is aged out by CONSECUTIVE_WINDOW instead, so a
      # re-spawn that fails the same way is the NEXT attempt, not a fresh first
      # one. Returning :success here means only "monitoring can continue".
      add_log(
        "Auth recovery #{retry_attempt} re-spawned — process #{new_pid} running after #{SUCCESS_THRESHOLD}s, resuming monitoring",
        level: "info"
      )
      log_buffer.flush
      @logger.info("Auth recovery re-spawn verified running", retry_attempt: retry_attempt, new_pid: new_pid)
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
