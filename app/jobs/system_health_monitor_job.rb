# frozen_string_literal: true

# Periodic monitor that turns the *detection* HealthMonitorService already does
# into an *alert a human actually sees*.
#
# Background: HealthMonitorService#system_health already computes a
# `status: :critical` ("Queue backlog critical: N jobs ready") once the ready GoodJob
# backlog crosses QUEUE_DEPTH_CRITICAL_THRESHOLD and stops draining
# (QUEUE_STALL_CRITICAL_AGE). That status was surfaced only in
# the on-demand health report — nothing paged on it — so a real backlog collapse
# (the SlackTriggerPollerJob thread-starvation incident) grew for ~5 hours before
# anyone noticed. This job closes that gap: it re-evaluates system health on a
# cron and raises an operational alert to #eng-alerts (via AlertService) when the
# backlog is critical.
#
# Queue placement — deliberately NOT `default`: a queue-backlog monitor must never
# run on the queue it is watching, or the very backlog it exists to report would
# starve it into silence. `pollers` is isolated (its own scheduler threads) and is
# where the other periodic monitors/pollers live, so the monitor keeps firing even
# when `default` is saturated (the exact incident this exists to catch).
#
# Caveat: this insulates the monitor from `default` saturation, not from `pollers`
# saturation. The now-singleton SlackTriggerPollerJob can occupy at most one of the
# `pollers` scheduler's threads, so the sub-second monitor still gets a thread — a
# `pollers` backlog would at worst *delay* an alert by a poll interval, never drop
# it. If more slow singleton pollers are ever added here, revisit giving the monitor
# its own tiny queue.
#
# Noise control (two layers):
# 1. Hysteresis — the backlog must read critical on CONSECUTIVE_CRITICAL_TO_ALERT
#    consecutive checks before we alert, so a brief burst that drains on its own
#    (e.g. a short spike of SessionTitleJobs) never pages. A single healthy check
#    resets the streak.
# 2. AlertService dedup — raise_alert suppresses duplicate alerts sharing a
#    dedup_key for AlertService::DEDUP_WINDOW (1 hour), so an incident that stays
#    critical for hours pages at most once per hour rather than every run.
class SystemHealthMonitorJob < ApplicationJob
  queue_as :pollers

  # Singleton: at most one monitor unfinished at a time, matching the other
  # periodic pollers. A monitor run is cheap, but this guarantees overlapping
  # cron ticks can never stack.
  good_job_control_concurrency_with(
    key: -> { "system_health_monitor" },
    total_limit: 1
  )

  # Number of consecutive critical observations required before alerting. With a
  # 2-minute cron this means the backlog must persist ~2-4 minutes, filtering out
  # transient single-tick spikes while still catching a genuine collapse quickly.
  CONSECUTIVE_CRITICAL_TO_ALERT = 2

  # Rails cache (Redis) key tracking the current run of consecutive critical
  # observations. Expires well beyond the cron interval so a missed tick doesn't
  # silently reset the streak, but not so long that a stale count lingers for ever.
  STREAK_CACHE_KEY = "system_health_monitor:consecutive_critical_queue"
  STREAK_TTL = 1.hour

  # Stable dedup key so every backlog-critical alert collapses onto one throttled
  # entry (one page per AlertService::DEDUP_WINDOW), rather than a fresh page each
  # time the depth number changes.
  ALERT_DEDUP_KEY = "system_health_queue_backlog_critical"

  def perform
    system_health = HealthMonitorService.new.system_health

    if system_health[:status].critical?
      handle_critical(system_health)
    else
      # Healthy (or merely elevated) — reset the streak so a later spike must build
      # its own fresh run of consecutive criticals before paging.
      Rails.cache.delete(STREAK_CACHE_KEY)
    end
  end

  private

  def handle_critical(system_health)
    streak = Rails.cache.read(STREAK_CACHE_KEY).to_i + 1
    Rails.cache.write(STREAK_CACHE_KEY, streak, expires_in: STREAK_TTL)

    # Not yet sustained long enough — wait for confirmation before paging.
    return if streak < CONSECUTIVE_CRITICAL_TO_ALERT

    depth = system_health[:queue_depth]

    # .warn (not .error): a queue backlog is an operational condition a human
    # should look at, but it is not necessarily a broken-system fault, and the
    # human-facing page is delivered by AlertService below — logging at .error
    # would additionally trip the "any Zimmer ERROR → critical" Grafana rule on top of
    # the Slack page (double-alerting). See CLAUDE.md logging philosophy.
    Rails.logger.warn(
      "[SystemHealthMonitorJob] Queue backlog critical: #{depth} ready job(s), oldest waiting " \
      "#{HealthMonitorService.format_wait(system_health[:queue_stats][:oldest_ready_age_seconds])}, " \
      "for #{streak} consecutive check(s); alerting #eng-alerts."
    )

    AlertService.raise_alert(
      "Queue backlog critical",
      details: build_details(system_health),
      source: "SystemHealthMonitorJob",
      dedup_key: ALERT_DEDUP_KEY
    )
  end

  # Compact, actionable alert body: how deep, what the depth is made of, whether
  # it is draining, and whether there is enough worker capacity to drain it.
  #
  # The breakdown lines are the difference between a page that can be triaged and
  # one that cannot. Zimmer's queues have very different shapes — `agents` holds a
  # thread for the whole life of a session, `default` and `pollers` turn jobs over
  # in milliseconds — so a bare ready count is compatible with both "one starved
  # queue" and "everything is busy", and those want opposite responses. Naming the
  # queue and the job classes in the page itself is what makes the next firing
  # readable without a database the responder may have no route to: agent triage
  # sessions have no shell on the production host and no way to open /jobs, so an
  # alert that says "check the dashboard" is a dead end for the reader most likely
  # to be reading it.
  def build_details(system_health)
    stats = system_health[:queue_stats]
    workers = system_health[:worker_stats]
    breakdown = ready_backlog_breakdown

    [
      "GoodJob backlog is critical.",
      "",
      "• Ready (waiting on a worker): #{stats[:ready_count]}, " \
        "oldest waiting #{HealthMonitorService.format_wait(stats[:oldest_ready_age_seconds])}",
      "• Ready by queue: #{format_breakdown(breakdown[:by_queue])}",
      "• Ready by job class: #{format_breakdown(breakdown[:by_job_class])}",
      "• Not backlog: #{stats[:claimed_count]} claimed (executing now), " \
        "#{stats[:scheduled_count]} scheduled (future-dated)",
      "• Processing rate: #{stats[:processing_rate_per_hour]}/hour",
      "• Workers: #{workers[:active_workers]} active / #{workers[:total_workers]} registered",
      "",
      "A backlog concentrated in ONE queue is that queue starving: its threads are " \
        "all held (an `agents` thread lasts as long as its session) or blocked on a " \
        "long external wait, and the other queues will still look healthy — including " \
        "the processing rate, which is a trailing hour and lags a stall by many minutes. " \
        "A backlog spread across every queue is the worker itself: down, restarting, or " \
        "starved of database round-trips."
    ].join("\n")
  end

  # Never let the diagnostic detail be the reason the page does not go out. The
  # breakdown is two extra grouped scans of `good_jobs` at exactly the moment the
  # database may be the thing going wrong, and a depth number that reaches a human
  # beats a richer one that raises on the way.
  def ready_backlog_breakdown
    HealthMonitorService.new.ready_backlog_breakdown
  rescue StandardError => e
    Rails.logger.warn("[SystemHealthMonitorJob] Could not read the backlog breakdown: #{e.message}")
    { by_queue: {}, by_job_class: {} }
  end

  def format_breakdown(counts)
    return "unavailable" if counts.blank?

    counts.map { |name, count| "#{name} #{count}" }.join(", ")
  end
end
