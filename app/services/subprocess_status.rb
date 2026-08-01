# frozen_string_literal: true

# Nil-safe reading of the `Process::Status` returned by `Open3.capture3` /
# `BoundedSubprocess.run`.
#
# **That status can be nil, and a nil status is a failed call — never a success.**
#
# Open3's `wait_thr` is a `Process.detach` thread. If anything else reaps the
# child before that thread's own `waitpid` runs, the waitpid gets `ECHILD` and
# `wait_thr.value` returns nil, so `capture3` returns `[stdout, stderr, nil]`.
# In Zimmer that "anything else" is `ZombieReaperJob`, which runs
# `Process.waitpid(-1, Process::WNOHANG)` in a loop — a blanket reaper, on the
# `*/5 * * * *` cron, in the same worker process as the GitHub pollers, which
# shell out to `gh` every 30 s. The two collide, and before this helper existed
# the collision crashed the tick with `undefined method 'success?' for nil`.
#
# Two distinctions this helper exists to preserve:
#
#   - Nil status means "we never learned the exit code", NOT "the command
#     returned non-zero". Logging the former as the latter turns a lost race
#     into a phantom command failure that nobody can reproduce. #describe_failure
#     says which one happened.
#   - On the reaped path the command may well have succeeded, and stderr is
#     often populated — the *exit code* is the only thing lost. Callers still
#     treat it as a failure, because a result we cannot vouch for is not a
#     result. For the pollers that means "this attempt failed, retry next tick",
#     which is exactly what they already do for a non-zero exit.
module SubprocessStatus
  # Reason text for the nil-status case, kept in one place so log greps and
  # tests have a stable string to match.
  REAPED_DESCRIPTION = "no exit status (child reaped before its waiter; exit code unknown)"

  module_function

  # @param status [Process::Status, nil]
  # @return [Boolean] true only when the command demonstrably exited 0
  def success?(status)
    return false if status.nil?

    status.success?
  end

  # True when we never learned how the command ended. Callers that retry use this
  # to classify the attempt as transient: a lost race is the most retryable
  # failure there is, and on a path with no "next tick" (a clone, an `air
  # prepare`) treating it as permanent fails a session over a result we simply
  # did not read.
  #
  # @param status [Process::Status, nil]
  # @return [Boolean]
  def unknown?(status)
    status.nil?
  end

  # Nil-safe `#exitstatus`. Returns nil when the status is nil (unknown) — so
  # comparisons against a specific code (`exit_code(status) == 8`) correctly
  # fall through to the failure branch instead of raising.
  #
  # @param status [Process::Status, nil]
  # @return [Integer, nil]
  def exit_code(status)
    status&.exitstatus
  end

  # One-line explanation of why a call is being treated as failed, suitable for
  # interpolating into a log line or an exception message.
  #
  # Runs on the failure path, so it takes care not to add a failure of its own:
  # a signaled child has a nil `#exitstatus` (BoundedSubprocess SIGKILLs whole
  # process groups on timeout, so that is reachable), and interpolating it would
  # print "exit status " and reproduce in miniature the unreadable log line this
  # module exists to prevent.
  #
  # @param status [Process::Status, nil]
  # @param stderr [String, nil] the command's stderr, appended when present
  # @return [String]
  def describe_failure(status, stderr = nil)
    detail = stderr.to_s.strip.presence
    detail ? "#{failure_reason(status)}: #{detail}" : failure_reason(status)
  end

  def failure_reason(status)
    return REAPED_DESCRIPTION if unknown?(status)
    return "killed by signal #{status.termsig}" if status.signaled?

    "exit status #{status.exitstatus}"
  end
end
