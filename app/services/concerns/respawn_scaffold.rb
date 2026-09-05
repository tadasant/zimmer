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
# Hosts must provide `session`, `process_manager` and `log_buffer` readers, and a
# private `recovery_label`.
module RespawnScaffold
  extend ActiveSupport::Concern

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
end
