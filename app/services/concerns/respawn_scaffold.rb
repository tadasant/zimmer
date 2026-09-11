# frozen_string_literal: true

# The re-spawn-and-verify mechanics every auto-recovery service shares.
#
# Four services answer one question — "the agent process died or errored; is the
# replacement actually alive?" — and this is the single answer they share:
#
#   SigtermRetryService          the process took a SIGTERM
#   ApiErrorRetryService         the transcript holds an Anthropic API error
#   ContextLengthRetryService    the context window overflowed
#   AuthRecoveryService          the runtime reported it is not logged in
#
# One copy matters here because this is the code that runs when a session is already
# in trouble, and so the code least likely to get a second reader. Split across four
# services, a fix lands in one of them and the symptom — one recovery path behaving
# unlike the other three — reads as anything but a duplication bug.
#
# What genuinely differs between the four stays on the concrete classes: their
# detection predicate, their retry budget and delay schedule, and `recovery_label`,
# the noun the shared log sentences interpolate.
#
# Hosts must provide `session`, `cli_adapter`, `process_manager`, `log_buffer` and
# `file_system` readers, a `@logger` StructuredLogger, and three private answers:
# `recovery_label`, `recovery_attempt_limit` and `next_recovery_attempt`.
module RespawnScaffold
  extend ActiveSupport::Concern

  # `respawn_and_verify` records the new pid through `with_db_retry`, so the
  # scaffold owns that dependency rather than leaving each host to remember it.
  include DatabaseRetry

  # Minimum time (seconds) a re-spawned process must stay up before the re-spawn counts
  # as successful. Checking every half second catches a fast crash quickly, but success
  # is only declared after the full stretch: a process that spawns and dies a second
  # later has demonstrated nothing.
  SUCCESS_THRESHOLD = 5

  # Interval (seconds) between session-status checks while waiting out a long delay, so
  # a session archived or corrupted mid-wait is noticed rather than slept through.
  STATUS_CHECK_INTERVAL = 10

  private

  # The name of this recovery loop, interpolated into the shared log sentences below.
  # Write it as it reads mid-sentence ("auth recovery"); the sentence that needs it
  # capitalized calls `upcase_first` itself.
  #
  # @return [String]
  def recovery_label
    raise NotImplementedError, "#{self.class} must define #recovery_label"
  end

  # How many attempts this recovery loop gets. The rescue below is the only
  # reader: it decides whether a failure is an intermediate one (another attempt
  # follows) or the final one (nothing left to recover it).
  #
  # Deliberately NOT lifted into this module. Three services read it off a
  # `RetryBudget`, `AuthRecoveryService` off its own `MAX_RECOVERY_ATTEMPTS`, and
  # `HealthMonitorService` reads two of them across the class boundary — the
  # budgets are genuinely per-service and stay where their owners can see them.
  #
  # @return [Integer]
  def recovery_attempt_limit
    raise NotImplementedError, "#{self.class} must define #recovery_attempt_limit"
  end

  # Run the next attempt of this recovery loop, after a re-spawn that died during
  # verification or an intermediate error. Each service reaches its own entry
  # point — some re-run detection, some deliberately skip it — so the scaffold
  # asks rather than assumes.
  #
  # @param working_directory [String]
  # @return [Symbol] whatever the host's loop returns
  def next_recovery_attempt(working_directory)
    raise NotImplementedError, "#{self.class} must define #next_recovery_attempt"
  end

  # Re-spawn the runtime, record the new process, and decide what the attempt was
  # worth — the loop all four services run once they have decided to act.
  #
  # The caller supplies the spawn itself as a block, because that is the one part
  # that genuinely differs: three services resume with a fixed prompt, and
  # `SigtermRetryService` chooses between resuming and a fresh start depending on
  # whether the dead process ever got as far as a conversation. Everything around
  # it — the last abort check before spawning, the pid bookkeeping, the
  # verification, the recursion into the next attempt, and the rescue — is the
  # same in all four, and was written out four times before.
  #
  # `resume_prompt` is passed separately rather than inferred from the block: it
  # is what `check_session_status` tests a status-summary fork against, and that
  # check has to happen BEFORE the block runs.
  #
  # @param working_directory [String] the cwd to re-spawn in
  # @param retry_attempt [Integer] this attempt's number, for the log lines
  # @param resume_prompt [String] the prompt the re-spawn will carry
  # @yieldreturn [Hash] the spawn result, whose `[:pid]` is the new process
  # @return [Symbol] :success, :exhausted, :aborted, or the next attempt's result
  def respawn_and_verify(working_directory, retry_attempt, resume_prompt:)
    abort_result = check_session_status(resume_prompt: resume_prompt)
    return :aborted if abort_result == :aborted

    new_pid = yield[:pid]

    add_log(
      "Spawned new agent process with PID #{new_pid} for #{recovery_label} attempt #{retry_attempt}",
      level: "info"
    )

    with_db_retry do
      session.record_agent_process!(new_pid)
    end

    if verify_process_running(new_pid, retry_attempt)
      log_respawn_verified(new_pid, retry_attempt)
      return :success
    end

    # The re-spawn died during verification — this attempt is spent, try the next.
    next_recovery_attempt(working_directory)
  rescue => e
    # WHY THE LEVEL DIFFERS between the final attempt and the ones before it. An
    # intermediate failure is expected and self-resolving: another attempt follows
    # immediately, so it logs at .info and raises no alert. The final one is a
    # genuine failure with nothing left to recover it, so it logs at .error —
    # which is what surfaces to GlitchTip, with a backtrace.
    #
    # That decision was written out four times, once per service, in four copies
    # of the same five-line comment. It lives here now, which is also why the next
    # such decision cannot be made in three services and forgotten in the fourth.
    if retry_attempt >= recovery_attempt_limit
      add_log("Error during #{recovery_label} attempt #{retry_attempt}: #{e.message}", level: "error")
      log_buffer.flush
      @logger.error("Error during #{recovery_label}", retry_attempt: retry_attempt, error: e.message, exception: e)
      return :exhausted
    end

    add_log("Error during #{recovery_label} attempt #{retry_attempt}: #{e.message}", level: "info")
    log_buffer.flush
    @logger.info("Error during #{recovery_label}", retry_attempt: retry_attempt, error: e.message)
    next_recovery_attempt(working_directory)
  end

  # Resume the session's runtime with a recovery prompt.
  #
  # The system prompt is rebuilt rather than reused so the re-spawn is told the
  # same things a fresh spawn would be: the session's goal, its root, its clone.
  # Every host used to carry a byte-identical copy of this call.
  #
  # @param working_directory [String] the cwd to resume in
  # @param prompt [String] the prompt to hand the resumed runtime
  # @return [Hash] the adapter's spawn result
  def resume_for_recovery(working_directory, prompt:)
    system_prompt = OrchestratorSystemPromptBuilder.build(
      session: session,
      working_directory: session.working_directory
    )

    cli_adapter.resume(
      session_id: session.session_id,
      prompt: prompt,
      working_dir: working_directory,
      append_system_prompt: system_prompt,
      model: session.config&.dig("model"),
      auto_compact_window: session.auto_compact_window
    )
  end

  # Announce a re-spawn that survived the success threshold.
  #
  # A hook rather than an inline sentence because `AuthRecoveryService` means
  # something weaker by it than the other three do, and says so — see its
  # override.
  #
  # @param new_pid [Integer] the verified process
  # @param retry_attempt [Integer] this attempt's number
  # @return [void]
  def log_respawn_verified(new_pid, retry_attempt)
    add_log(
      "#{recovery_label.upcase_first} #{retry_attempt} successful - " \
        "process #{new_pid} verified running for #{SUCCESS_THRESHOLD}s",
      level: "info"
    )
    log_buffer.flush
    @logger.info("#{recovery_label.upcase_first} successful", retry_attempt: retry_attempt, new_pid: new_pid)
  end

  # Verify a re-spawned process stays running for the success threshold.
  #
  # @param pid [Integer] Process ID to verify
  # @param retry_attempt [Integer] Current attempt number, for the log line
  # @return [Boolean] true if the process is verified running, false if it died
  def verify_process_running(pid, retry_attempt)
    process_start_time = Time.current

    loop do
      elapsed = Time.current - process_start_time

      unless process_manager.running?(pid)
        add_log(
          "#{recovery_label.upcase_first} attempt #{retry_attempt} failed — " \
            "process #{pid} died after #{elapsed.round(1)}s",
          level: "warning"
        )
        return false
      end

      return true if elapsed >= SUCCESS_THRESHOLD

      sleep(0.5)
    end
  end

  # Wait out a retry delay, checking session status periodically for long delays.
  #
  # Delays of 30s or less are slept through in one go and checked once at the end; past
  # that the wait is broken into STATUS_CHECK_INTERVAL slices so a session the user
  # archives mid-wait aborts promptly instead of at the end of a five-minute sleep.
  #
  # ContextLengthRetryService never calls this, deliberately. Its corrective action is
  # the `/compact` prompt itself rather than waiting out a transient, so it has no delay
  # schedule and re-spawns immediately — and `wait_with_status_checks(0)` returns
  # without checking anything anyway. The abort check it does need — session state
  # changing between detection and spawn — it makes directly via `check_session_status`
  # right before spawning, the same way the other three do. What it lacks is a delay,
  # not a check.
  #
  # @param delay [Integer] Total delay in seconds
  # @return [Symbol, nil] :aborted if session state changed, nil otherwise
  def wait_with_status_checks(delay, resume_prompt: nil)
    return nil unless delay.positive?

    if delay <= 30
      sleep(delay)
      return check_session_status(resume_prompt: resume_prompt)
    end

    remaining = delay
    while remaining.positive?
      sleep_time = [ remaining, STATUS_CHECK_INTERVAL ].min
      sleep(sleep_time)
      remaining -= sleep_time

      abort_result = check_session_status(resume_prompt: resume_prompt)
      return abort_result if abort_result == :aborted
    end

    nil
  end

  # Check whether the session is still running, and whether the prompt this
  # respawn is about to carry may be delivered to it at all.
  #
  # THE SECOND DOOR (#724). `AgentSessionJob#refuse_non_summary_fork_turn` closed
  # the one a status-summary fork is handed a fresh turn through. This is the other
  # one: the four services that mix this in respawn the RUNTIME inside a turn that
  # is already running, so they never reach that guard. A fork holds a copy of its
  # SOURCE's conversation, so a resume prompt that says "continue where you left
  # off" tells it to continue the source's task — and that is how one
  # `start_session` call became two sessions.
  #
  # THE TEST IS THE PROMPT, not the fork. It is deliberately the same one the
  # job-entry guard applies — `SessionStatusSummaryGenerator.fork_prompt?` — and
  # for the same reason: a turn that was NEVER SPENT arrives carrying the summary
  # request and must still run. `SigtermRetryService` is exactly that case, since
  # it prefers `pending_follow_up_prompt` over the recovery nudge, and for a fork
  # interrupted before it consumed its prompt that pending prompt IS the summary
  # request. Refusing on the fork alone would cost a blurb every time a deploy
  # landed mid-generation — the case the Status summary docs single out as one
  # that must be allowed to run.
  #
  # A fork whose respawn would replay its source is brought to rest instead: the
  # `pause` hook harvests it, and the blurb is re-driven without the fork ever
  # being told to carry on.
  #
  # @param resume_prompt [String, nil] the prompt this respawn will carry. nil
  #   means the caller has none to offer, which is not the summary request.
  # @return [Symbol, nil] :aborted if the session may not be resumed, nil if still running
  def check_session_status(resume_prompt: nil)
    session.reload
    unless session.running?
      add_log(
        "Session state changed to #{session.status} during #{recovery_label}, aborting",
        level: "warning"
      )
      return :aborted
    end
    if session.status_summary_fork? && !SessionStatusSummaryGenerator.fork_prompt?(resume_prompt)
      add_log(
        "Not resuming during #{recovery_label}: this is a status-summary fork of session " \
        "#{session.status_summary_source_id}, and the prompt this respawn carries would tell it to continue " \
        "that session's work rather than its own. Coming to rest so the summary is harvested instead.",
        level: "warning"
      )
      # Flushed before the pause, not after it. `pause!` writes "Session paused,
      # waiting for input" straight to the database, while a buffered line is
      # stamped at flush time — so without this the explanation lands after the
      # event it explains, on the one line a reader consults to find out why the
      # fork stopped.
      log_buffer&.flush
      # Brought to rest HERE, not left for the caller. `:aborted` means "somebody
      # else owns this exit", and every host maps it to an ExitDecision the job
      # logs and walks away from without transitioning anything — so returning it
      # on a fork nobody else owns would leave the fork `running` with a dead
      # process for a sweep to collect later, holding its clone meanwhile.
      # Pausing makes the claim true: it is the fork's own completion transition,
      # and the state machine's pause hook harvests it.
      #
      # `pause!` rather than `fail!`, matching AgentSessionJob's job-entry guard,
      # so a fork that had already written its blurb before the process died still
      # publishes it. One disposal rule for a summary fork that stops, wherever it
      # is stopped from. `running?` is established above, so `may_pause?` holds.
      session.pause!
      return :aborted
    end
    nil
  end

  # Add a log entry via the log buffer.
  def add_log(content, level: "info")
    log_buffer.add(content, level: level)
  end

  # --- Reading the transcript the symptom was found in --------------------------
  #
  # Three of the four services scan the session's transcript for the error that
  # triggers them, and each carried its own copy of these three helpers.
  #
  # WHY THEY LIVE HERE AND NOT ON `TranscriptSource`. What the copies actually
  # were is a runtime seam BYPASS: `find_transcript_path` re-implemented, line for
  # line, the body of `TranscriptSource#locate` — directory, `directory?` guard,
  # `find_main_transcript` — which every runtime source already answers for
  # itself. So the transcript half moves onto the seam (these now just call
  # `locate`), and what is left over is not transcript knowledge at all: it is
  # this module's ERROR POLICY. A recovery service is running because the session
  # is already in trouble, so a transcript it cannot read must never be what takes
  # the recovery down — it answers nil, or zero, and the loop carries on. That
  # policy belongs to respawning, and it is why these are three-line wrappers here
  # rather than three more methods on `TranscriptSource`.

  # The session's runtime transcript source, bound to this service's file system
  # adapter so tests drive it without touching disk.
  #
  # @return [TranscriptSource]
  def transcript_source
    TranscriptRuntime.source_for(session, file_system: file_system)
  end

  # Locate the session's main transcript file.
  #
  # @param working_directory [String] the cwd the runtime was spawned from
  # @return [String, nil] the transcript path, or nil when it cannot be found or read
  def find_transcript_path(working_directory)
    transcript_source.locate(session: session, working_directory: working_directory)
  rescue => e
    @logger.error("Error finding transcript path", error: e.message)
    nil
  end

  # Extract the plain text of a transcript message entry.
  #
  # The entries these services scan carry their prose in content blocks:
  #
  #   { "message" => { "content" => [ { "type" => "text", "text" => "Prompt is too long" } ] } }
  #
  # Anything else — a missing message, a string content, a tool_use block —
  # contributes nothing, so a malformed entry reads as "" rather than raising in
  # the middle of a recovery.
  #
  # @param entry [Hash] a parsed transcript entry
  # @return [String] the entry's text, or "" when it carries none
  def extract_message_text(entry)
    message = entry["message"]
    return "" unless message.is_a?(Hash)

    content = message["content"]
    return "" unless content.is_a?(Array)

    content.filter_map do |block|
      block["text"] if block.is_a?(Hash) && block["type"] == "text"
    end.join(" ")
  end

  # The transcript's current line count, which is how these services remember
  # which lines they have already judged: the marker they store is a line number,
  # so the same error entry is not re-detected after the re-spawn.
  #
  # @param working_directory [String] the cwd the runtime was spawned from
  # @return [Integer] the line count, or 0 when there is no readable transcript
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
end
