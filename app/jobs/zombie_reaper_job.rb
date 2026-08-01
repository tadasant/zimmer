# frozen_string_literal: true

# Reaps zombie subprocesses left behind by code that spawned a child and never
# waited on it.
#
# See tadasant/zimmer-catalog#3549 for the original incident: 6,032 zombies
# accumulated under the worker over ~2 days, degrading session startup until the
# worker container was restarted.
#
# This job used to describe itself as "defense in depth alongside the tini init
# shim (`init: true` in deploy*.yml)", implying it should normally find nothing.
# That premise was wrong, and it is why the reaps in #273 looked mysterious: tini
# only reaps processes REPARENTED to pid 1. A direct child of the Ruby worker is
# never reparented while the worker is alive, so tini can never collect it. Every
# child this process spawns and does not wait on is permanently this job's
# problem — the init shim covers grandchildren orphaned by an exiting `gh`/`air`
# /`claude`, nothing more.
#
# == Why this job is pid-aware (#273)
#
# This cron runs in the SAME process as AgentSessionJob's monitoring loop and the
# pollers. It used to call `Process.waitpid(-1, Process::WNOHANG)` in a loop,
# which reaps *any* child — including one another thread is actively waiting on —
# and consumes its exit status. Two things broke as a result:
#
#   1. `Open3.capture3`'s wait thread got `Errno::ECHILD` and `wait_thr.value`
#      returned nil, so a `gh` result already in hand was thrown away (#271).
#   2. `ProcessLifecycleManager#wait_nonblock` got `Errno::ECHILD` on a tracked
#      agent pid, so AgentSessionJob fell through to its signal-based fallback
#      (search "Fallback process detection using signal 0") and called
#      `session.pause!` directly — bypassing handle_exit's SIGTERM retry,
#      /compact retry, API-error backoff and failure_reason mapping. A session
#      that should have auto-retried landed in needs_input with no explanation.
#
# So this job now reaps *named* pids, and only ones nothing else is waiting on.
#
# == How a pid qualifies for reaping
#
# A pid is reaped only if all three hold:
#
#   a. it is a zombie AND a direct child of this process (ZombieChildScanner);
#   b. it was still a zombie CONFIRMATION_DELAY seconds later. A live waiter
#      blocked in `waitpid` — every `Open3.capture3`/`popen3` wait thread — reaps
#      its child within microseconds of exit, so anything still defunct seconds
#      later has no such waiter. This is what protects waiters we cannot see in
#      the registry;
#   c. ChildWaiterRegistry has no live waiter for it — either nothing claimed it,
#      or its claimant has not called wait within LIVE_WAITER_STALE_AFTER and is
#      therefore gone. This is what protects the polling waiters we CAN see.
#
# == The two cases that are easy to get silently wrong
#
# *TOCTOU.* Condition (c) is checked immediately before `waitpid`, and that is
# sufficient: a zombie holds its pid until it is reaped, so no newly spawned
# process can claim that pid in the window between the check and the call. The
# only registry write that can land in that window is a `heartbeat` for the very
# same dead pid — and a heartbeat means someone IS waiting, which is exactly the
# case condition (c) already rejected a moment earlier. Re-checking narrows the
# window; nothing can reuse the pid to widen it.
#
# *Orphaned waiters.* A claim whose waiter died without reaping must NOT protect
# its pid forever, or zombies accumulate again exactly as they did in the original
# incident. That is what the heartbeat in ChildWaiterRegistry is for: a live
# monitoring loop calls wait every 0.5s, so a claim that has gone quiet for
# LIVE_WAITER_STALE_AFTER is orphaned and gets reaped — and logged loudly, with
# the command, because an orphaned claim is a real upstream leak worth naming.
class ZombieReaperJob < ApplicationJob
  queue_as :default

  # How long a zombie must persist across two observations before we accept that
  # nothing is blocked in waitpid on it. Generous relative to the microseconds a
  # Process.detach thread needs, cheap relative to a 5-minute cron.
  CONFIRMATION_DELAY = 2

  # A claim whose waiter has not called wait within this many seconds is treated
  # as orphaned. AgentSessionJob's monitoring loop polls every 0.5s, so this is
  # ~600x the expected heartbeat interval — deliberately far to the "leave it
  # alone" side, because a wrongly reaped exit status strands a live session while
  # a late-reaped zombie merely lingers for one more cron tick.
  LIVE_WAITER_STALE_AFTER = 300

  def perform
    scanner = ZombieChildScanner.new
    registry = ChildWaiterRegistry.instance

    first_pass = scanner.snapshot
    unless first_pass
      Rails.logger.warn "[ZombieReaperJob] Could not read the process table — reaped nothing this tick"
      return
    end

    registry.prune!(first_pass.pids)

    if first_pass.zombie_child_pids.empty?
      Rails.logger.info "[ZombieReaperJob] No zombies to reap"
      return
    end

    # Second observation: anything with a waiter blocked in waitpid is gone by now.
    sleep CONFIRMATION_DELAY
    second_pass = scanner.snapshot
    unless second_pass
      Rails.logger.warn "[ZombieReaperJob] Could not confirm zombies on the second pass — reaped nothing this tick"
      return
    end

    candidates = first_pass.zombie_child_pids & second_pass.zombie_child_pids
    reap(candidates, registry)
  end

  private

  def reap(candidates, registry)
    reaped = []
    orphaned = []
    skipped = []

    candidates.each do |pid|
      waiter = registry.waiter(pid)

      # Re-checked here, immediately before waitpid, rather than up front — see
      # the TOCTOU note in this file's header for why that is sufficient.
      if registry.live?(pid, stale_after: LIVE_WAITER_STALE_AFTER)
        skipped << pid
        next
      end

      begin
        if Process.waitpid(pid, Process::WNOHANG)
          reaped << pid
          orphaned << waiter if waiter
        end
      rescue Errno::ECHILD, Errno::ESRCH
        # Something else collected it between our two passes. Nothing to do.
      ensure
        registry.release(pid)
      end
    end

    log_outcome(reaped, orphaned, skipped)
  end

  def log_outcome(reaped, orphaned, skipped)
    if skipped.any?
      Rails.logger.info "[ZombieReaperJob] Left #{skipped.size} defunct child(ren) to their live waiters: #{skipped.join(', ')}"
    end

    orphaned.each do |waiter|
      Rails.logger.warn "[ZombieReaperJob] Reaped pid #{waiter.pid} whose waiter went quiet " \
        "#{waiter.idle_seconds.round}s ago (claimed for: #{waiter.command || 'unknown command'}). " \
        "Something spawned this child and stopped waiting on it — this is an upstream leak, not a reaper problem."
    end

    if reaped.any?
      Rails.logger.warn "[ZombieReaperJob] Reaped #{reaped.size} abandoned zombie subprocess(es): #{reaped.join(', ')}. " \
        "Nothing in this process was waiting on them, so something spawned children it never reaped — investigate."
    elsif skipped.empty?
      Rails.logger.info "[ZombieReaperJob] No zombies to reap"
    end
  end
end
