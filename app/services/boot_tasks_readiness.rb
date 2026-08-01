# frozen_string_literal: true

# The gate between a container's background boot tasks and the first session it spawns.
#
# `bin/docker-entrypoint` updates the Claude CLI (`claude update`) and the Playwright
# browsers in a backgrounded block, so that Rails boots immediately and Kamal's health
# check passes instead of timing out behind a 30s+ npm download. The cost of that choice
# is a window: `~/.local` is a named volume that survives the deploy and shadows the
# binary baked into the new image, so until `claude update` finishes, the CLI on disk is
# the *previous* deploy's version. A session spawned inside that window runs against it,
# silently, with nothing in the log to say so.
#
# The entrypoint now writes a marker file when the background block finishes — whatever
# the outcome — and exports its path as `ZIMMER_BOOT_TASKS_MARKER`. `#await` blocks on
# that marker, and the spawn path calls it immediately before launching the runtime CLI.
#
# Three properties are deliberate, because each of their opposites is worse than the bug:
#
#   - **The gate is off unless the entrypoint armed it.** Development, test, and
#     `bin/dev` never run the entrypoint, so `ZIMMER_BOOT_TASKS_MARKER` is unset and
#     `#await` returns `:disabled` without touching the filesystem. A gate that waited
#     for a marker nobody writes would hang every local spawn.
#
#   - **The wait is bounded, and bounded from process start rather than from the call.**
#     If `claude update` hangs, the marker never lands; after the deadline every spawn
#     proceeds anyway. Sessions running on a stale CLI is a bug. A worker that refuses
#     to spawn until a hung npm process returns is an outage. Because the deadline is
#     anchored to when this process booted, the whole mechanism is inert once the
#     container has been up longer than the timeout — a session started an hour into a
#     deploy never waits, and never can.
#
#   - **Nothing here blocks Rails boot.** This is read on the spawn path only. The web
#     process answers `/up` on schedule regardless of what the background block is doing.
#
# `AgentSessionJob` turns the result into a session log line, so a session that waited,
# or that spawned against a CLI whose update failed or never finished, says so.
module BootTasksReadiness
  module_function

  # Set (and exported) by `bin/docker-entrypoint`. Its presence is what arms the gate.
  MARKER_ENV = "ZIMMER_BOOT_TASKS_MARKER"

  # Operator override for the deadline, in seconds. `0` disables waiting entirely while
  # keeping the reporting, which is the escape hatch if the marker ever misbehaves.
  TIMEOUT_ENV = "ZIMMER_BOOT_TASKS_TIMEOUT_SECONDS"

  # Generous next to the ~30s the background block actually takes, because the cost of
  # waiting a little too long is a slow spawn and the cost of waiting too little is the
  # bug this exists to fix.
  DEFAULT_TIMEOUT_SECONDS = 120.0

  POLL_INTERVAL_SECONDS = 0.5

  # Marker contents the entrypoint writes when every background task succeeded.
  OK_STATUS = "ok"

  # Cap on how much of the marker we quote back into a log line.
  MAX_DETAIL_CHARS = 200

  # Monotonic reading from when this file was loaded. In production Rails eager-loads at
  # boot, so this is process start to within a second; in development and test the gate
  # is disabled and the value is never read.
  LOADED_AT = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # @!attribute state
  #   @return [Symbol] :disabled (gate not armed), :ready (boot tasks finished cleanly),
  #     :degraded (they finished, but something failed), :timed_out (deadline passed
  #     with no marker)
  Result = Struct.new(:state, :waited_seconds, :detail, keyword_init: true) do
    # True when the runtime CLI on disk is known to be the version this deploy intended.
    def ready?
      state == :ready || state == :disabled
    end

    # True when the caller should say something loud: we are spawning anyway, but the
    # CLI may not be what the deploy intended.
    def degraded?
      state == :degraded || state == :timed_out
    end

    def waited?
      waited_seconds.to_f >= 1.0
    end
  end

  # Block until the container's background boot tasks have finished, or the deadline
  # passes. Never raises: every failure mode resolves to a Result the caller can log.
  #
  # @param deadline_at [Float] monotonic clock reading to stop waiting at (injectable
  #   for testing; defaults to process start + the configured timeout)
  # @param sleeper [#call] receives the number of seconds to sleep (injectable)
  # @return [Result]
  def await(deadline_at: default_deadline_at, sleeper: method(:sleep))
    path = marker_path
    return Result.new(state: :disabled, waited_seconds: 0.0) if path.nil?

    started_at = monotonic_now
    until File.exist?(path)
      remaining = deadline_at - monotonic_now
      break if remaining <= 0

      sleeper.call([ POLL_INTERVAL_SECONDS, remaining ].min)
    end

    waited = monotonic_now - started_at
    # Re-check after the loop so a marker that landed during the final sleep counts.
    return read_marker(path, waited) if File.exist?(path)

    Result.new(state: :timed_out, waited_seconds: waited)
  end

  # @return [String, nil] the marker path, or nil when the gate is not armed
  def marker_path
    ENV[MARKER_ENV].to_s.strip.presence
  end

  # @return [Float] seconds after process start at which we stop waiting
  def timeout_seconds
    configured = ENV[TIMEOUT_ENV].to_s.strip.presence
    return DEFAULT_TIMEOUT_SECONDS if configured.nil?

    seconds = Float(configured, exception: false)
    return DEFAULT_TIMEOUT_SECONDS if seconds.nil? || seconds.negative?

    seconds
  end

  def default_deadline_at
    LOADED_AT + timeout_seconds
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # The marker's *presence* is the signal that the background block finished; its
  # contents only distinguish a clean finish from a failed one. An unreadable or empty
  # marker is therefore still "ready" — we know the block ran, we just can't say more.
  def read_marker(path, waited)
    contents = begin
      File.read(path, MAX_DETAIL_CHARS + 1).to_s.strip
    rescue SystemCallError, IOError
      ""
    end

    return Result.new(state: :ready, waited_seconds: waited) if contents.empty? || contents == OK_STATUS

    Result.new(state: :degraded, waited_seconds: waited, detail: contents[0, MAX_DETAIL_CHARS])
  end
end
