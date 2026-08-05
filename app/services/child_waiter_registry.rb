# frozen_string_literal: true

# Process-wide record of which child pids this Ruby process has a *live waiter* for.
#
# Why this exists (#273): ZombieReaperJob runs on a cron inside the same worker
# process as AgentSessionJob's monitoring loop and the pollers, so it cannot reap
# with `Process.waitpid(-1, …)` — that takes ANY child, including one another
# thread is actively waiting on, and consumes its exit status. The thread that
# needed that status gets `Errno::ECHILD` and loses it. This registry is how the
# reaper tells the two kinds of child apart.
#
# A "live waiter" here means: some thread spawned this pid through
# SystemProcessManager and is still calling `SystemProcessManager#wait` on it.
# SystemProcessManager claims the pid at spawn and heartbeats it on every wait, so
# "claimed AND heartbeated recently" is the reaper's test for "another thread owns
# this child's exit status; leave it alone".
#
# The heartbeat is the part that matters most. A bare claim would protect a pid
# forever — including one whose waiter is gone — and its zombie would never be
# collected, which is the failure mode that produced the original incident
# (pulsemcp/pulsemcp#3549: 6,032 zombies over ~2 days). The heartbeat lets
# the reaper distinguish "someone is waiting" from "someone was supposed to be
# waiting and is gone", and reap only the latter.
#
# Timestamps use CLOCK_MONOTONIC so a wall-clock adjustment (NTP step, container
# clock skew) cannot make a live waiter look stale or vice versa.
#
# Thread-safe. There is exactly one instance per Ruby process (`.instance`);
# `SystemProcessManager` writes to it and `ZombieReaperJob` reads it.
class ChildWaiterRegistry
  # Cap on the diagnostic command string kept per claim. Long enough to identify
  # a caller, short enough that a warn line stays readable.
  MAX_COMMAND_LENGTH = 200

  # Cap on a single retained flag name. A "flag" is any argument starting with
  # `-`, and an argument VALUE can start with one too, so this bounds what a
  # value masquerading as a flag can put into a log line.
  MAX_FLAG_LENGTH = 40

  Waiter = Struct.new(:pid, :command, :claimed_at, :last_waited_at, keyword_init: true) do
    # Seconds since this waiter last called wait on the pid.
    def idle_seconds(now = ChildWaiterRegistry.monotonic_now)
      now - last_waited_at
    end
  end

  class << self
    # Guards construction only. Two threads racing here would each get their own
    # registry, and claims written to the loser would be invisible to the reaper —
    # which is exactly the "unclaimed pid" case that gets reaped.
    INSTANCE_MUTEX = Mutex.new

    def instance
      @instance || INSTANCE_MUTEX.synchronize { @instance ||= new }
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Test seam: drop the process-wide instance so a test can start from empty.
    def reset!
      INSTANCE_MUTEX.synchronize { @instance = nil }
    end
  end

  def initialize
    @waiters = {}
    @mutex = Mutex.new
  end

  # Record that this process has spawned `pid` and intends to wait on it.
  # Called immediately after Process.spawn returns, i.e. before the child can
  # possibly have exited and become a zombie.
  #
  # @param pid [Integer]
  # @param command [String, Array, nil] for diagnostics only
  # @param at [Float] monotonic timestamp (injectable for tests)
  # @return [Waiter]
  def claim(pid, command: nil, at: self.class.monotonic_now)
    waiter = Waiter.new(
      pid: pid,
      command: normalize_command(command),
      claimed_at: at,
      last_waited_at: at
    )
    @mutex.synchronize { @waiters[pid] = waiter }
    waiter
  end

  # Record that a waiter just called wait on `pid`. Upserts deliberately: a thread
  # actively waiting on a pid we have no claim for still deserves protection, and
  # claiming late is safer than not claiming at all.
  #
  # @return [Waiter]
  def heartbeat(pid, at: self.class.monotonic_now)
    @mutex.synchronize do
      existing = @waiters[pid]
      if existing
        existing.last_waited_at = at
        existing
      else
        @waiters[pid] = Waiter.new(pid: pid, command: nil, claimed_at: at, last_waited_at: at)
      end
    end
  end

  # Drop the claim for `pid` — its waiter reaped it, or gave up on it.
  # @return [Waiter, nil] the removed waiter
  def release(pid)
    @mutex.synchronize { @waiters.delete(pid) }
  end

  # @return [Waiter, nil]
  def waiter(pid)
    @mutex.synchronize { @waiters[pid] }
  end

  # Does `pid` have a waiter that has checked in within `stale_after` seconds?
  #
  # False for an unknown pid (nobody claimed it) and false for a claimed pid whose
  # waiter has gone quiet (orphaned). Both are safe to reap.
  def live?(pid, stale_after:, now: self.class.monotonic_now)
    entry = @mutex.synchronize { @waiters[pid] }
    return false unless entry

    entry.idle_seconds(now) <= stale_after
  end

  # Forget claims for pids that no longer exist in the process table at all.
  # Bounds memory when a waiter dies without releasing and the pid is later
  # collected by someone else.
  #
  # @param existing_pids [Enumerable<Integer>] every pid currently on the box
  # @return [Array<Integer>] pids that were forgotten
  def prune!(existing_pids)
    alive = {}
    existing_pids.each { |pid| alive[pid] = true }
    @mutex.synchronize do
      gone = @waiters.keys.reject { |pid| alive.key?(pid) }
      gone.each { |pid| @waiters.delete(pid) }
      gone
    end
  end

  # @return [Hash<Integer, Waiter>]
  def all
    @mutex.synchronize { @waiters.dup }
  end

  def count
    @mutex.synchronize { @waiters.size }
  end

  def clear
    @mutex.synchronize { @waiters.clear }
  end

  private

  # Reduce a spawn's argv to something safe to put in a log line.
  #
  # Only the program name and its flag NAMES survive. Process.spawn's optional
  # leading env hash is dropped, and so is every argument VALUE — this string is
  # logged at warn level when a claim turns out to be orphaned, and spawn
  # arguments here routinely carry prompts, working-directory paths and
  # credentials. Flag names alone still separate one caller from another
  # (`claude -p` from the session adapter's `claude --print --output-format`),
  # which is all the diagnostic has to do.
  def normalize_command(command)
    parts = case command
    when nil then []
    when Array then command.flatten
    else [ command ]
    end

    parts = parts.reject { |part| part.is_a?(Hash) }.map(&:to_s)
    return nil if parts.empty?

    # Process.spawn also accepts a single shell-command STRING, in which case
    # parts.first is the whole command line — arguments and all. Split on
    # whitespace first so that shape reduces to a program name like the argv
    # shape does, instead of passing the entire command through untouched.
    program = File.basename(parts.first.split(/\s+/).first.to_s)
    flags = parts.drop(1)
                 .select { |part| part.start_with?("-") }
                 .map { |flag| flag.split("=").first.to_s[0, MAX_FLAG_LENGTH] }

    ([ program ] + flags).join(" ").truncate(MAX_COMMAND_LENGTH)
  end
end
