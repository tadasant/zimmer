# frozen_string_literal: true

# The one liveness check that keeps working when the GoodJob queue executes nothing.
#
# WHY THIS EXISTS
# ---------------
# Every other health-and-recovery mechanism in Zimmer is itself an ActiveJob running
# on the GoodJob queue it is supposed to watch -- SystemHealthMonitorJob (pollers),
# ZombieReaperJob, the trigger health checks, EgressHealthCheckJob, and the rest of
# app/jobs/. That is fine when the queue is merely busy, but it means a queue that is
# executing *nothing at all* disables its own recovery: during the 2026-08-13 outage
# (tadasant/zimmer#426) the worker container could not open a database connection, so
# GoodJob executed nothing for ~10 hours, and every one of those watchdogs was
# unrunnable for exactly the same reason everything else was. Six sessions sat
# untouched and a user message went unanswered for 1h46m; what finally restored
# service was a human noticing and deploying, not the system. A watchdog that shares a
# failure domain with the thing it watches is not a watchdog (tadasant/zimmer#427).
#
# SystemHealthMonitorJob already *computes* the condition -- HealthMonitorService's
# `execution_stall` reads "no job has finished anywhere in ten minutes, and either a
# fast lane has picked nothing up or no worker is reporting a heartbeat" -- and its own
# comment admits the hole: "In the total-outage case this job cannot run either -- it
# is on `pollers`, which is exactly the hole the external Grafana rule covers." That
# external Grafana rule lives in tadasant-internal, a different repo owned by a
# different agent root. This watchdog is the in-repo half.
#
# WHERE IT RUNS
# -------------
# QueueLivenessSupervisor runs this on a plain background thread inside the **web
# (Puma) process** -- a separate process, in a separate container, from the worker.
# The web process stayed up throughout #426 and could still reach the database (every
# reading on /health, GET /api/v1/health and get_system_health was served correctly
# the whole time). So a check driven from the web process survives the exact failure
# that silenced the queue: it does not depend on GoodJob executing anything, because it
# is not a GoodJob job.
#
# WHAT IT DOES, AND DELIBERATELY DOES NOT, PAGE ON
# ------------------------------------------------
# It pages on ONE condition: the `execution_stalled` critical status -- the queue is
# alive-or-not question. It deliberately does NOT page on a deep backlog or a wedged
# lane. Those are questions about an *alive* queue, and SystemHealthMonitorJob (which
# CAN run when the queue is merely busy) already pages on them; paging on them here too
# would double-page under ordinary saturation. The clean split is: this watchdog asks
# "is the queue executing anything at all?", the worker's monitor asks "is the (alive)
# queue healthy?". In the total-outage case only this watchdog can fire, which is the
# gap it closes.
#
# It respects a deliberate halt for the same reason HealthMonitorService does: queue
# recovery mode reports a stall it explains as a `warning`, not a `critical`
# (`execution_stalled:paused`), so gating on `critical?` excludes it -- paging an
# operator for the silence they asked for would put a lock on the escape hatch.
#
# It ALERTS; it does not remediate. Automated worker replacement or a self-dispatched
# deploy is a materially bigger question (#427 flags it), and this stops at the smaller,
# out-of-band-observability version that matches Zimmer's existing model.
#
# NOISE CONTROL
# -------------
# Hysteresis: the stall must read critical on CONSECUTIVE_STALLS_TO_ALERT consecutive
# checks before the first page, so a brief blip during a deploy cutover never pages. A
# single healthy check resets the streak. The streak is held in memory on the single
# long-lived watchdog instance rather than in Redis -- there is exactly one watchdog
# thread, so no cross-process coordination is needed, and keeping it in memory means
# the watchdog depends on nothing but the database it reads and the log pipeline it
# writes, both of which the web process still had during #426.
#
# Once confirmed, it re-logs every tick while the stall persists, on purpose: the
# Grafana rule pages on *recent* ERROR records, so a single log line ten hours ago
# would not keep an alert firing through the outage. GlitchTip dedupes the repeats to a
# single issue that notifies once. This mirrors SystemHealthMonitorJob's own behaviour.
#
# A failed READ carries its own separate streak, under the same confirmation count, so a
# database blip lasting a tick does not page either. A failed read never resets the stall
# streak: it is "unknown", not "healthy".
class QueueLivenessWatchdog
  # Consecutive stall observations required before the first page. With the supervisor's
  # default 60-second interval this is ~2 minutes of confirmed silence, on top of the
  # ten minutes of no completions that `execution_stall` itself requires, so time to
  # first page is ~12 minutes after the queue goes dark -- against the ~10 hours the
  # gap cost in #426. Matches SystemHealthMonitorJob::CONSECUTIVE_CRITICAL_TO_ALERT.
  CONSECUTIVE_STALLS_TO_ALERT = 2

  # A stable GlitchTip title so every firing groups as one issue rather than paging per
  # tick. Distinct from SystemHealthMonitorJob's "Nothing is executing" so the two
  # sources stay separate issues -- this one is the out-of-band confirmation that fired
  # when the in-band monitor could not.
  ALERT_TITLE = "Queue executing nothing (out-of-band watchdog)"

  # @param health_monitor [#system_health, nil] nil means "build a fresh
  #   HealthMonitorService for every tick", which is what production does.
  #   HealthMonitorService memoises per instance and documents itself as built per
  #   request; this is its first long-lived caller, so holding one across ticks would
  #   freeze the watchdog's view the moment anything under `system_health` starts
  #   memoising. Construction is a SystemProcessManager and a logger -- cheap beside the
  #   dozen queries a tick already runs. Tests inject a fake.
  def initialize(health_monitor: nil)
    @health_monitor = health_monitor
    @consecutive_stalls = 0
    @consecutive_errors = 0
  end

  # Evaluate the queue's liveness once and page if it has been executing nothing for
  # long enough and often enough. Never raises: this is the last line of defence, and a
  # watchdog that dies on a transient read is no watchdog. A failure to read is itself
  # logged at ERROR -- which pages via the same Grafana rule -- so the check degrades
  # loud, not silent.
  #
  # @return [Symbol] :stalled (paged or building the streak), :healthy, or :error
  def check!
    health = health_monitor.system_health
    status = health[:status]
    @consecutive_errors = 0

    if stalled?(status)
      observe_stall(health, status)
    else
      @consecutive_stalls = 0
      :healthy
    end
  rescue => e
    observe_error(e)
  end

  # Exposed for tests and for `system_health`'s reading; not part of paging.
  attr_reader :consecutive_stalls, :consecutive_errors

  private

  def health_monitor
    @health_monitor || HealthMonitorService.new
  end

  # The critical execution-stall status, and only that. The `:paused` variant is a
  # `warning` (a deliberate halt under queue recovery mode), so `critical?` excludes it;
  # a backlog or a wedged lane carries a different code and is the worker monitor's to
  # page on.
  def stalled?(status)
    status.critical? && status.code == HealthMonitorService::EXECUTION_STALL_CODE
  end

  # The read itself failed -- most likely the web process cannot reach the database.
  # That is a different failure domain from "the queue is dead", but it is still an
  # outage this process can see and nothing else here would, so it pages too.
  #
  # It gets the SAME confirmation the stall path gets, and for the same reason: a
  # Postgres failover, a `db:prepare` hiccup or a checkout timeout off the web's
  # five-slot pool is over in a tick or two, and paging on the first one would fire the
  # "any non-staging ERROR record" Grafana rule for a condition that had already cleared.
  # Without the streak a persistent raise would also emit 1,440 ERROR records a day.
  #
  # The stall streak is deliberately left ALONE here rather than reset: a failed read is
  # "unknown", not "healthy", and a stall either side of one transient error is still two
  # consecutive observations of a stall. Only a successful read that comes back
  # not-stalled clears it.
  def observe_error(error)
    @consecutive_errors += 1
    return :error if @consecutive_errors < CONSECUTIVE_STALLS_TO_ALERT

    Rails.logger.error(
      "[QueueLivenessWatchdog] Liveness read failed: #{error.class}: #{error.message} " \
      "(#{@consecutive_errors} consecutive check(s))"
    )
    ErrorReporter.report_exception(
      error,
      level: :error,
      context: {
        source: "QueueLivenessWatchdog",
        note: "liveness read failed -- the out-of-band watchdog cannot see the queue",
        consecutive_checks: @consecutive_errors
      }
    )
    :error
  end

  def observe_stall(health, status)
    @consecutive_stalls += 1
    return :stalled if @consecutive_stalls < CONSECUTIVE_STALLS_TO_ALERT

    page(health, status)
    :stalled
  end

  def page(health, status)
    stats = health[:queue_stats] || {}
    workers = health.dig(:worker_stats, :active_workers)

    # .error IS the page: it is what trips the "any non-staging Zimmer ERROR record"
    # Grafana rule, from the web process -- the process that stayed up in #426. The
    # message carries the observation because on a phone the message is all a responder
    # sees; the GlitchTip title stays fixed so every firing groups as one issue.
    Rails.logger.error(
      "[QueueLivenessWatchdog] #{status.message} " \
      "(#{workers.inspect} worker(s) with a live heartbeat, " \
      "last finished #{stats[:seconds_since_last_finished].inspect}s ago, " \
      "for #{@consecutive_stalls} consecutive check(s)) -- reported out-of-band from the web process"
    )

    ErrorReporter.report_message(
      ALERT_TITLE,
      level: :error,
      context: {
        source: "QueueLivenessWatchdog",
        details: build_details(status),
        status_code: status.code.presence,
        active_workers: workers,
        seconds_since_last_finished: stats[:seconds_since_last_finished],
        consecutive_checks: @consecutive_stalls
      }
    )
  end

  def build_details(status)
    [
      status.message,
      "",
      "This alert was raised by the web (Puma) process, NOT by a GoodJob job. Every other " \
        "health-and-recovery check in Zimmer runs on the queue it watches, so a queue that is " \
        "executing nothing at all (tadasant/zimmer#426: the worker could not open a database " \
        "connection for ~10 hours) silences all of them at once. This watchdog runs in a " \
        "separate process that does not depend on the queue, so it still fires.",
      "",
      "What to check: is the worker container up and able to reach the database? " \
        "`good_job_processes` empty and `last_finished_at` stale together is the signature of a " \
        "worker that cannot register or claim anything. A deploy that replaces the worker " \
        "container is the in-band recovery; this watchdog only reports, it does not remediate."
    ].join("\n")
  end
end
