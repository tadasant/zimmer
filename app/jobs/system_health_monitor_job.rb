# frozen_string_literal: true

# Periodic monitor that turns the *detection* HealthMonitorService already does
# into an *alert a human actually sees*.
#
# Background: HealthMonitorService#system_health already computes a
# `status: :critical` ("Queue backlog critical: ...") once a backlog is both deep
# and not draining — either on a single lane past its own
# QUEUE_LANE_CRITICAL_THRESHOLDS, or fleet-wide with no lane picking anything up
# (QUEUE_DEPTH_CRITICAL_THRESHOLD, QUEUE_STALL_CRITICAL_AGE). That status was surfaced only in
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

  # Stable dedup key so a backlog-critical alert collapses onto one throttled entry
  # (one page per AlertService::DEDUP_WINDOW), rather than a fresh page each time the
  # depth number changes.
  #
  # Qualified by the status's `code`, so the two critical shapes throttle
  # SEPARATELY. They are different incidents wanting different responses — one lane
  # starving is not the worker going quiet across several — and on one shared key the
  # first to fire silences the other for the rest of the window. A starved-`inference`
  # page at 10:00 must not swallow a cross-lane stall at 10:15. Within a shape the key
  # is still stable, including per lane, so a lane that stays starved for hours pages
  # once an hour and not once a tick.
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
    # Quote the gate's own message rather than rebuilding it: it names WHICH of the
    # two critical shapes fired — a single starved lane, or no lane picking work up
    # at all — and that is the first thing the responder needs.
    Rails.logger.warn(
      "[SystemHealthMonitorJob] #{system_health[:status].message} " \
      "(#{depth} ready job(s), for #{streak} consecutive check(s)); alerting #eng-alerts."
    )

    AlertService.raise_alert(
      "Queue backlog critical",
      details: build_details(system_health),
      source: "SystemHealthMonitorJob",
      dedup_key: alert_dedup_key(system_health[:status])
    )
  end

  # Falls back to the bare key for a critical status carrying no code, so a future
  # backlog shape that forgets one throttles like the old single-key behaviour rather
  # than paging every tick.
  def alert_dedup_key(status)
    [ ALERT_DEDUP_KEY, status.code.presence ].compact.join(":")
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
      system_health[:status].message,
      "",
      "• Ready (waiting on a worker): #{stats[:ready_count]}, " \
        "oldest waiting #{head_of_line_age(stats, breakdown[:head_of_line])}" \
        "#{head_of_line_suffix(breakdown[:head_of_line])}",
      "• Ready by queue: #{HealthMonitorService.format_breakdown(breakdown[:by_queue])}",
      "• Ready by job class: #{HealthMonitorService.format_breakdown(breakdown[:by_job_class])}",
      "• Oldest ready by queue: #{HealthMonitorService.format_ages(breakdown[:oldest_by_queue])}",
      "• Not backlog: #{stats[:claimed_count]} claimed (executing now), " \
        "#{stats[:scheduled_count]} scheduled (future-dated)",
      "• Processing rate: #{stats[:processing_rate_per_hour]}/hour",
      "• Workers: #{workers[:active_workers]} active / #{workers[:total_workers]} registered",
      "",
      "The line above names either one starved lane or a stall spread across several, " \
        "because the gate decides per lane rather than on one age across all of them. " \
        "It does not settle the question on its own: a worker that has stopped " \
        "entirely leaves its deepest lane over that lane's own bar too, and the " \
        "starved-lane wording is what you get. Read these ages before you act on it. " \
        "ONE old queue " \
        "beside fresh ones is that queue starving: its threads are all held (an " \
        "`agents` thread lasts as long as its session, and `inference` and " \
        "`maintenance` run two threads against jobs that block for a minute or " \
        "more) or blocked on a long external wait, and every other queue will still " \
        "look healthy — including the processing rate, which is a trailing hour and " \
        "lags a stall by many minutes. EVERY queue old at once is the worker itself: " \
        "down, restarting, or starved of database round-trips. The Grafana `not " \
        "draining` rule still fires on the single global age and cannot tell them apart."
    ].join("\n")
  end

  # Never let the diagnostic detail be the reason the page does not go out. The
  # breakdown is three extra scans of `good_jobs` at exactly the moment the
  # database may be the thing going wrong, and a depth number that reaches a human
  # beats a richer one that raises on the way.
  #
  # Nil on failure, NOT an empty breakdown. The two render differently — a queue
  # that read as empty and a query that never answered are different facts about
  # the incident, and collapsing them would tell the responder the backlog is
  # spread across nothing.
  def ready_backlog_breakdown
    HealthMonitorService.new.ready_backlog_breakdown
  rescue StandardError => e
    Rails.logger.warn("[SystemHealthMonitorJob] Could not read the backlog breakdown: #{e.message}")
    { by_queue: nil, by_job_class: nil, oldest_by_queue: nil, head_of_line: nil }
  end

  # The age and the lane are quoted from the SAME read when there is one.
  #
  # `queue_statistics` and `ready_backlog_breakdown` are separate queries against a
  # moving table, so their answers can differ by whatever drained between them: the
  # row `queue_statistics` measured may already be claimed when the breakdown runs,
  # leaving the bullet quoting one row's age next to another row's lane. Taking
  # both from `head_of_line` keeps the sentence internally true. `queue_statistics`
  # remains the fallback; its own per-lane numbers are what the `critical` gate
  # thresholded on, which this does not touch.
  def head_of_line_age(stats, head)
    seconds = head.present? ? head[:age_seconds] : stats[:oldest_ready_age_seconds]
    HealthMonitorService.format_wait(seconds)
  end

  # Names the lane and the job class behind the age the line just quoted, so the
  # first bullet answers "old where" and not only "old". Empty when the breakdown
  # could not be read — the age still comes through from `queue_statistics` and is
  # worth printing on its own.
  def head_of_line_suffix(head)
    return "" if head.blank?

    " (#{head[:queue]} / #{head[:job_class]})"
  end
end
