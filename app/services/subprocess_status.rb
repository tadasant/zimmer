# frozen_string_literal: true

# Nil-safe reading of the `Process::Status` returned by `Open3.capture3` /
# `BoundedSubprocess.run`.
#
# **That status can be nil, and a nil status is a failed call — never a success.**
#
# Open3's `wait_thr` is a `Process.detach` thread. If anything else reaps the
# child before that thread's own `waitpid` runs, the waitpid gets `ECHILD` and
# `wait_thr.value` returns nil, so `capture3` returns `[stdout, stderr, nil]`.
# In Zimmer that "anything else" was `ZombieReaperJob` reaping `waitpid(-1)` on
# the `*/5 * * * *` cron, in the same worker process as the GitHub pollers, which
# shell out to `gh` every 30 s. The two collided and crashed the tick with
# `undefined method 'success?' for nil` (#271).
#
# ZombieReaperJob now reaps named pids and leaves claimed ones alone (#273), so
# that particular collision is rare. This module is not thereby obsolete: the
# reaper's protection for waiters it cannot see in `ChildWaiterRegistry` rests on
# a two-second confirmation delay, which is a timing argument rather than a
# guarantee, and a nil `wait_thr.value` is part of Open3's contract regardless of
# who does the reaping. Reading a status is the wrong place to assume nobody ever
# will.
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
  REAPED_DESCRIPTION = "no exit code (child reaped before its waiter, so the exit code was never read)"

  module_function

  # @param status [Process::Status, nil]
  # @return [Boolean] true only when the command demonstrably exited 0
  def success?(status)
    # Plain truthiness rather than `#nil?`: this is called with test doubles as
    # well as real statuses, and a bare `Minitest::Mock` undefines `#nil?`, so
    # asking would be an unexpected invocation on the one object that exists to
    # stand in for a status. Truthiness needs no method at all.
    return false unless status

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
    # Asked from nil's side on purpose. `status.nil?` and `!status` both dispatch
    # to the status object, and a bare Minitest::Mock — the shape much of the
    # suite uses to stand in for a Process::Status — undefines `#nil?` and `#!`
    # alike, so either would blow up on a double rather than answer a question
    # about it. `nil.equal?` touches only nil.
    nil.equal?(status)
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
  # Runs on the failure path, so it takes care not to add a failure of its own.
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

    code = status.exitstatus
    return "exit status #{code}" if code

    # A real Process::Status reports a nil #exitstatus only for a child killed by
    # a signal — reachable here, since BoundedSubprocess SIGKILLs whole process
    # groups on timeout. Interpolating it would print "exit status " and
    # reproduce in miniature the unreadable log line this module exists to
    # prevent. #termsig is asked for only on this branch, so a status double that
    # reports a real exit code never has to answer it.
    signal = status.termsig
    signal ? "killed by signal #{signal}" : "no exit code reported"
  end
end
