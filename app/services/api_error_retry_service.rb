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
# Malformed tool calls:
#   Not every entry the CLI writes with isApiErrorMessage: true is the API talking.
#   A tool call the model emitted that will not parse is reported the same way, with
#   no error type at all — and it belongs in the same transient category, because a
#   fresh draw usually parses. See MALFORMED_TOOL_CALL_PATTERNS.
#
class ApiErrorRetryService
  include DatabaseRetry

  # The API-error budget: attempts, metadata keys, and the stable stretch that wins
  # them back. Declared once in RetryBudget.
  BUDGET = RetryBudget::API_ERROR

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
  # https://docs.zimmer.tadasant.com/auth/harness/ → "Usage-limit message formats"). It has
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

  # The CLI's own report that the model emitted a tool call it could not parse.
  #
  # This one is not the API talking. When a tool call will not parse, Claude Code
  # re-prompts the model in-turn ("Your tool call was malformed and could not be
  # parsed. Please retry."), and if the second attempt also fails it synthesises
  # an assistant entry of its own — +model: "<synthetic>"+, +isApiErrorMessage:
  # true+, and **no +error+ field at all** — then exits with its turn-finished
  # convention. So the entry is untyped by construction: no amount of reading
  # +error+ classifies it, and only the prose can.
  #
  # Known message format from production:
  #   "The model's tool call could not be parsed (retry also failed)."
  #
  # It is retryable because a tool call that will not parse is a **sampling
  # artifact, not a permanent condition** — the same category as a 5xx, arrived
  # at from the other end. The CLI's in-turn retry does not settle that: it
  # re-prompts the same model with the same context, which is the worst
  # conditions for escaping the failure mode. A respawn is a materially
  # different draw.
  #
  # What it does NOT rule out is a deterministically unparseable payload — a
  # multi-megabyte base64 argument that fails identically every time. MAX_RETRIES
  # bounds that, and ProcessLifecycleManager alerts on a malformed tool call that
  # the ladder did not clear, so a repeating failure fails loudly rather than
  # being retried into silence.
  #
  # Production incident 2026-08-25 (session 8878, issue #668): the entry matched
  # no classifier, `handle_exit`'s terminal-API-error backstop failed the session
  # as an unknown failure mode, and a finished deliverable was lost on the upload
  # step one respawn would probably have cleared.
  MALFORMED_TOOL_CALL_PATTERNS = [
    /tool call could not be parsed/i,
    /tool call was malformed/i
  ].freeze

  # Error types from the API that indicate server errors (as opposed to client errors)
  API_SERVER_ERROR_TYPES = %w[api_error overloaded_error server_error].freeze

  # Error types from the API that indicate rate limiting
  RATE_LIMIT_ERROR_TYPES = %w[rate_limit_error].freeze

  # Combined error types for detection (server errors + rate limits)
  RETRYABLE_ERROR_TYPES = (API_SERVER_ERROR_TYPES + RATE_LIMIT_ERROR_TYPES).freeze

  # Transcript entry types that are the conversation itself. Everything else the
  # runtime writes into the same file — +queue-operation+, +attachment+,
  # +atis-latch+, +last-prompt+ — is bookkeeping, and routinely lands AFTER the
  # final message of a turn. See #terminal_api_error.
  CONVERSATIONAL_ENTRY_TYPES = %w[user assistant].freeze

  # The API error a turn died on. +recognized+ says whether some classifier owns
  # the wording — it gates alerting, never the verdict. +line+ identifies the
  # transcript entry, so the caller can refuse to fail the same dead turn twice.
  TerminalApiError = Data.define(:text, :recognized, :line) do
    def recognized? = recognized
  end

  attr_reader :session, :cli_adapter, :process_manager, :log_buffer, :file_system, :rate_limit_tracker

  # Whether the error this service is retrying is a CLI-synthesised malformed
  # tool call (see MALFORMED_TOOL_CALL_PATTERNS). Set by
  # #retryable_api_error_detected? and read by ProcessLifecycleManager once the
  # retry budget is spent: a turn that dies this way with no retries left is no
  # longer a plausible sampling artifact, and that is news worth alerting on.
  def detected_malformed_tool_call? = @detected_malformed_tool_call

  # Whether some error text is the CLI's report of a tool call that would not
  # parse. A class method because ProcessLifecycleManager asks the same question
  # of a TerminalApiError, where no instance of this service is in hand — one
  # definition of the pattern match, two callers.
  #
  # @param message_text [String] the message text from a transcript entry
  # @return [Boolean] true if the error is a malformed tool call
  def self.malformed_tool_call?(message_text)
    MALFORMED_TOOL_CALL_PATTERNS.any? { |pattern| message_text.to_s.match?(pattern) }
  end

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
    @detected_malformed_tool_call = false
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
            is_malformed_tool_call: self.class.malformed_tool_call?(message_text),
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
      elsif last_match[:is_malformed_tool_call]
        "malformed_tool_call"
      else
        "server_error"
      end

      @logger.info("API #{error_category} detected in transcript (most recent match)",
        line_number: last_match[:line_number], error_type: last_match[:error_type])
      @detected_rate_limit = last_match[:is_rate_limit] && !last_match[:is_quota_limit]
      @detected_quota_limit = last_match[:is_quota_limit]
      @detected_malformed_tool_call = last_match[:is_malformed_tool_call] && !last_match[:is_quota_limit]
      @detected_quota_message = last_match[:message_text] if last_match[:is_quota_limit]
      return true
    end

    false
  rescue => e
    @logger.error("Error checking transcript for API error", error: e.message)
    false
  end

  # The most recent API-error entry in the transcript that NO classifier
  # recognized, or nil when every API error present is accounted for.
  #
  # "Accounted for" means: retryable here (server error / rate limit / account
  # quota), or owned by a sibling classifier — a context-length error
  # (ContextLengthRetryService) or the rotation-induced "Not logged in"
  # signature (AuthRecoveryService). Those two are excluded deliberately: they
  # ARE classified, just not by this service, and reporting them as unknown
  # would be a false alarm on an entirely ordinary recovery.
  #
  # What is left is the interesting case — the CLI recorded an API error whose
  # wording matches nothing Zimmer knows. ProcessLifecycleManager reads this on
  # the unclassified failure path so the alert carries the actual unmatched
  # prose instead of just an exit code.
  #
  # This is extraction only: it never alerts on its own. Detection runs on every
  # normal turn completion, so alerting from here would fire repeatedly for a
  # session whose transcript simply contains an old unrecognized entry. The one
  # place that knows the session is genuinely dying — and therefore the one
  # place that alerts — is the failure path in ProcessLifecycleManager.
  #
  # @param working_directory [String] Working directory for locating transcript
  # @return [String, nil] the unmatched error text
  def unclassified_api_error_text(working_directory)
    return nil unless working_directory

    transcript_path = find_transcript_path(working_directory)
    return nil unless transcript_path
    return nil unless file_system.exists?(transcript_path)

    content = file_system.read(transcript_path)
    return nil if content.blank?

    last_checked_line = session.metadata&.dig("api_error_last_checked_line") || 0
    unmatched = nil

    content.lines.each_with_index do |line, index|
      next if (index + 1) <= last_checked_line
      next if line.strip.blank?

      begin
        entry = JSON.parse(line)
      rescue JSON::ParserError
        next
      end

      next unless entry["isApiErrorMessage"] == true

      error_type = entry["error"].to_s
      message_text = extract_message_text(entry)
      next if retryable_error?(error_type, message_text)
      next if classified_elsewhere?(error_type, message_text)

      unmatched = [ error_type.presence, message_text.presence ].compact.join(": ")
    end

    unmatched.presence
  rescue => e
    @logger.error("Error extracting unclassified API error", error: e.message)
    nil
  end

  # The API error this turn DIED on: the last conversational entry in the
  # transcript being an isApiErrorMessage.
  #
  # A stronger question than #unclassified_api_error_text asks. That one answers
  # "is there an unrecognized API error anywhere in the transcript"; this one
  # answers "is an API error the LAST thing the conversation contains" — which is
  # only ever true of a turn that stopped because of it.
  #
  # == Why it does not filter by classifier ==
  #
  # ProcessLifecycleManager asks this LAST on the normal-completion path, after
  # every specific classifier has already looked at the same exit and declined to
  # act. So a terminal error reaching here means nobody is handling this dead
  # turn, whatever its wording — including the case where a classifier DOES
  # recognize the wording but has already spent its cursor on it. That case is
  # reachable: a 5xx is retried, +api_error_last_checked_line+ advances past it,
  # the respawn writes nothing and exits 1, and every classifier now says "not
  # mine" about a transcript whose last word is still that 5xx.
  #
  # +recognized+ records which of the two it was. It changes only whether the
  # failure is *alerted* as an unknown wording — not whether the turn is allowed
  # to look finished, which it never is.
  #
  # Only +user+ and +assistant+ entries count. The runtime writes bookkeeping
  # entries (+last-prompt+, +atis-latch+, +attachment+, +queue-operation+) after
  # the final message, and those are not the conversation making progress.
  # Sidechain (subagent) entries are skipped for the mirror-image reason: a
  # subagent's API error does not end the main turn.
  #
  # @param working_directory [String] Working directory for locating the transcript
  # @return [TerminalApiError, nil] nil when the turn ended on real output or on
  #   nothing at all
  def terminal_api_error(working_directory)
    return nil unless working_directory

    transcript_path = find_transcript_path(working_directory)
    return nil unless transcript_path
    return nil unless file_system.exists?(transcript_path)

    content = file_system.read(transcript_path)
    return nil if content.blank?

    # Walk backwards and stop at the first conversational entry: it is the last
    # thing the conversation contains, and the only one the question is about.
    # Forwards would JSON-parse every line of a transcript that can run to tens
    # of thousands, on every normal exit of every session.
    lines = content.lines
    offset_from_end = 0
    terminal = lines.reverse_each.lazy.filter_map { |line|
      offset_from_end += 1
      next if line.strip.blank?

      begin
        entry = JSON.parse(line)
      rescue JSON::ParserError
        next
      end

      # A line that parses to a bare scalar ("null", "42") is valid JSON and not
      # an entry; asking it for ["type"] would raise past the lazy block.
      next unless entry.is_a?(Hash)
      next unless CONVERSATIONAL_ENTRY_TYPES.include?(entry["type"])
      next if entry["isSidechain"] == true

      [ entry, lines.length - offset_from_end + 1 ]
    }.first

    # No conversational entry at all, or the turn ended on real output rather
    # than on an error — either way, nothing died here.
    return nil unless terminal && terminal.first["isApiErrorMessage"] == true

    entry, line_number = terminal
    error_type = entry["error"].to_s
    message_text = extract_message_text(entry)

    TerminalApiError.new(
      text: [ error_type.presence, message_text.presence ].compact.join(": ").presence || "(no error text)",
      recognized: retryable_error?(error_type, message_text) || classified_elsewhere?(error_type, message_text),
      line: line_number
    )
  rescue => e
    @logger.error("Error checking transcript for a terminal API error", error: e.message)
    nil
  end

  private

  # Whether this error belongs to a classifier other than this service. Keeps the
  # "unclassified" signal honest — an ordinary compact recovery or auth recovery
  # must never be reported as an unknown failure mode.
  #
  # Asked with the error TYPE as well as the text, because that is how
  # AuthRecoveryService recognizes an authentication failure whose prose it has
  # never seen.
  def classified_elsewhere?(error_type, message_text)
    return true if ContextLengthRetryService::CONTEXT_LENGTH_ERROR_PATTERNS.any? { |p| message_text.match?(p) }
    return true if AuthRecoveryService.auth_error?(error_type, message_text)

    false
  end

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
      session.record_agent_process!(new_pid)
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
    if retry_attempt >= BUDGET.max
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
    session.reload
    current_retry_count = BUDGET.count_for(session)

    if BUDGET.exhausted?(session)
      add_log("API error retry limit reached (#{BUDGET.max} attempts)", level: "warning")
      return :exhausted
    end

    retry_attempt = BUDGET.next_attempt(session)

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
    error_category = if @detected_rate_limit
      "Rate limit"
    elsif @detected_malformed_tool_call
      "Malformed tool call"
    else
      "API server error"
    end

    # Log rate limit pressure status for visibility
    if rate_limit_tracker.under_pressure?
      recent_count = rate_limit_tracker.recent_event_count
      add_log(
        "System under rate limit pressure (#{recent_count} events in last 5 min) - using escalated delays",
        level: "warning"
      )
    end

    add_log(
      "#{error_category} detected - attempting auto-retry #{retry_attempt}/#{BUDGET.max}" \
        " after #{retry_delay}s delay",
      level: "warning"
    )
    log_buffer.flush

    # Wait with periodic session status checks
    abort_result = wait_with_status_checks(retry_delay)
    return :aborted if abort_result == :aborted

    # Record retry attempt in metadata
    with_db_retry do
      BUDGET.record!(
        session,
        attempt: retry_attempt,
        extra: { "api_error_last_checked_line" => get_transcript_line_count(working_directory) }
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
    source = TranscriptRuntime.source_for(session, file_system: file_system)
    transcript_dir = source.transcript_directory(working_directory: working_directory)
    return nil unless transcript_dir
    return nil unless file_system.directory?(transcript_dir)

    source.find_main_transcript(transcript_directory: transcript_dir, session: session)
  rescue => e
    @logger.error("Error finding transcript path", error: e.message)
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

    # The CLI's own untyped report of a tool call it could not parse. Prose only,
    # because the entry it is written on carries no error type at all.
    return true if self.class.malformed_tool_call?(message_text)

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
