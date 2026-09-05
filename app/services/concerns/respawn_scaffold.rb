# frozen_string_literal: true

# The re-spawn-and-verify mechanics shared by every auto-recovery service.
#
# Four services answer the same question — "the agent process died or errored; is the
# replacement actually alive?" — and each one used to carry its own verbatim copy of
# the verification loop, the delay-with-status-checks loop, the abort check and the
# log shim:
#
#   SigtermRetryService          the process took a SIGTERM
#   ApiErrorRetryService         the transcript holds an Anthropic API error
#   ContextLengthRetryService    the context window overflowed
#   AuthRecoveryService          the runtime reported it is not logged in
#
# This is the code that runs when a session is already in trouble, which makes it the
# code least likely to get a second reader. Four copies means a fix lands in one of
# them, and the symptom — one recovery path behaving unlike the other three — reads as
# anything but a duplication bug.
#
# What genuinely differs between the four stays on the concrete classes: their
# detection predicate, their retry budget and delay schedule, and `recovery_label`,
# the noun the shared log sentences interpolate.
#
# Hosts must provide `session`, `process_manager` and `log_buffer` readers, and a
# private `recovery_label`.
module RespawnScaffold
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
  # ContextLengthRetryService deliberately never calls this. Its corrective action is
  # the `/compact` prompt itself rather than waiting out a transient, so it has no delay
  # schedule and re-spawns immediately; `wait_with_status_checks(0)` would return
  # without checking anything. The abort check it does need — session state changing
  # between detection and spawn — it makes directly via `check_session_status` right
  # before spawning, the same way the other three do. So the absence is a missing
  # *delay*, not a missing check, and nothing changes by inheriting the method unused.
  #
  # @param delay [Integer] Total delay in seconds
  # @return [Symbol, nil] :aborted if session state changed, nil otherwise
  def wait_with_status_checks(delay)
    return nil unless delay.positive?

    if delay <= 30
      sleep(delay)
      return check_session_status
    end

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

  # Check whether the session is still running.
  #
  # @return [Symbol, nil] :aborted if session state changed, nil if still running
  def check_session_status
    session.reload
    unless session.running?
      add_log(
        "Session state changed to #{session.status} during #{recovery_label}, aborting",
        level: "warning"
      )
      return :aborted
    end
    nil
  end

  # Add a log entry via the log buffer.
  def add_log(content, level: "info")
    log_buffer.add(content, level: level)
  end
end
