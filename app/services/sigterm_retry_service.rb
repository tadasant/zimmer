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
  include RespawnScaffold

  # The SIGTERM budget: how many attempts, which metadata keys they live in, and when
  # a stable process wins them back. Declared once in RetryBudget.
  BUDGET = RetryBudget::SIGTERM

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
    current_retry_count = BUDGET.count_for(session)
    sigterm_retry_timestamps = session.metadata&.dig("sigterm_retry_timestamps") || []

    # Check if we've exhausted all retry attempts
    if BUDGET.exhausted?(session)
      add_log("SIGTERM retry limit reached (#{BUDGET.max} attempts)", level: "warning")
      return :exhausted
    end

    # Record this SIGTERM event in the global tracker
    rate_limit_tracker.record_event

    # Get adaptive delay based on global rate limit pressure
    retry_delay = rate_limit_tracker.recommended_delay(attempt: current_retry_count)
    retry_attempt = BUDGET.next_attempt(session)

    # Log rate limit pressure status for visibility
    if rate_limit_tracker.under_pressure?
      recent_count = rate_limit_tracker.recent_event_count
      add_log(
        "System under rate limit pressure (#{recent_count} events in last 5 min) - using escalated delays",
        level: "warning"
      )
    end

    add_log(
      "Claude CLI exited with SIGTERM (exit code 143) - attempting auto-retry #{retry_attempt}/#{BUDGET.max}" +
        (retry_delay.positive? ? " after #{retry_delay}s delay" : ""),
      level: "warning"
    )
    log_buffer.flush

    # Wait for the retry delay, checking session status periodically for long delays
    # The pending prompt is read again at the spawn, where it is consumed; here it
    # only decides whether this wait may end in a respawn at all.
    abort_result = wait_with_status_checks(
      retry_delay,
      resume_prompt: session.metadata&.dig("pending_follow_up_prompt").presence || AutomatedPrompts::SYSTEM_RECOVERY
    )
    return :aborted if abort_result == :aborted

    # Record retry attempt in metadata
    sigterm_retry_timestamps << Time.current.iso8601
    with_db_retry do
      BUDGET.record!(
        session,
        attempt: retry_attempt,
        extra: { "sigterm_retry_timestamps" => sigterm_retry_timestamps }
      )
    end

    spawn_and_verify_retry(working_directory, retry_attempt)
  end

  private

  # The noun the shared respawn log sentences interpolate.
  def recovery_label = "SIGTERM retry"

  # The scaffold's rescue reads this to tell an intermediate failure from the final one.
  def recovery_attempt_limit = BUDGET.max

  # Back to the top of the loop: SIGTERM retries re-run the whole attempt,
  # including the budget check, because each one spends an attempt.
  def next_recovery_attempt(working_directory)
    attempt_retry(working_directory)
  end

  # Spawn a new process and verify it stays running
  # @param working_directory [String] The working directory
  # @param retry_attempt [Integer] Current retry attempt number
  # @return [Symbol] :success, :exhausted, :aborted, or recursive call result
  def spawn_and_verify_retry(working_directory, retry_attempt)
    # Read before the status check rather than inside the spawn below, because
    # the check has to be told which prompt this respawn will actually carry —
    # for a status-summary fork interrupted before it consumed its prompt, this
    # pending one IS the summary request, and refusing it would cost a blurb
    # every time a deploy landed mid-generation. Read only; it is still consumed
    # and cleared where it is used. Reading it here also fixes the value across
    # the `session.reload` that `check_session_status` performs, which is why it
    # is captured by the block rather than re-read inside it.
    pending_prompt = session.metadata&.dig("pending_follow_up_prompt")

    # The scaffold makes the final status check immediately before spawning, to
    # prevent the race where a user sends a follow-up prompt between
    # wait_with_status_checks and here — the last opportunity to abort before
    # spawning an automated recovery process that would race with it.
    respawn_and_verify(
      working_directory,
      retry_attempt,
      resume_prompt: pending_prompt.presence || AutomatedPrompts::SYSTEM_RECOVERY
    ) { spawn_retry_process(working_directory, pending_prompt) }
  end

  # The one thing SIGTERM retry does differently from the other three recovery
  # services: it may have nothing to resume. If the original process was killed
  # before producing any assistant response there is no conversation on disk, and
  # resuming would fail with "No conversation found" — so it starts fresh with the
  # original prompt instead.
  #
  # @param working_directory [String] The working directory
  # @param pending_prompt [String, nil] a follow-up the user sent that the job
  #   never got to process, read before the scaffold's status check
  # @return [Hash] the adapter's spawn result
  def spawn_retry_process(working_directory, pending_prompt)
    unless conversation_exists?(working_directory)
      # Regenerate system prompt for retry consistency
      system_prompt = OrchestratorSystemPromptBuilder.build(
        session: session,
        working_directory: session.working_directory
      )

      add_log("No existing conversation found, starting fresh with original prompt", level: "info")
      return cli_adapter.execute(
        prompt: session.prompt,
        session_id: session.session_id,
        working_dir: working_directory,
        mcp_config_path: session.metadata&.dig("mcp_config_path"),
        append_system_prompt: system_prompt,
        model: session.config&.dig("model"),
        auto_compact_window: session.auto_compact_window
      )
    end

    # Check for pending follow-up prompt that was lost due to race condition.
    # This happens when the user sends a follow-up, the job is enqueued, but
    # SIGTERM retry kicks in before the job processes the prompt.
    resume_prompt = if pending_prompt.present?
      add_log("Using pending follow-up prompt instead of automated recovery prompt", level: "info")
      # Clear the pending prompt and sent_at now that we're using it
      with_db_retry do
        session.remove_metadata!(%w[pending_follow_up_prompt pending_follow_up_sent_at])
      end
      pending_prompt
    else
      AutomatedPrompts::SYSTEM_RECOVERY
    end

    add_log("Resuming existing conversation", level: "debug")
    resume_for_recovery(working_directory, prompt: resume_prompt)
  end

  # Check if a valid conversation exists in the transcript
  # A valid conversation has at least one assistant message (not just queue operations)
  # @param working_directory [String] The working directory for finding the transcript
  # @return [Boolean] true if conversation exists, false otherwise
  def conversation_exists?(working_directory)
    # `transcript_source.locate`, not the scaffold's `find_transcript_path`: that
    # one answers nil for a transcript it cannot read, and nil here means "start
    # fresh", which would replay the original prompt over a conversation that
    # exists. A transcript that cannot be read must raise and be counted as a
    # failed attempt instead.
    transcript_file = transcript_source.locate(session: session, working_directory: working_directory)
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
end
