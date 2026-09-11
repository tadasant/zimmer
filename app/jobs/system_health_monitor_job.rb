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
# cron and reports an operational alert through the obs pipeline (an ERROR log
# record, which pages via Grafana, plus a GlitchTip event) when the backlog is
# critical.
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
# 2. Notification grouping in the obs pipeline — Grafana groups by alertname over
#    a 5-minute interval and re-pages every 4 hours, and a GlitchTip issue notifies
#    at most once, so an incident that stays critical for hours does not page every
#    run. Nothing in this process throttles any more.
#
# Cron freshness — the second thing it pages on (tadasant/zimmer#619). Most recurring
# jobs are singletons, so a `perform` that hangs makes GoodJob refuse every later tick
# for that class and the backlog stays flat: the gate above cannot see it. Each run
# also reads CronFreshness and pages when a key has stopped producing jobs, under its
# own title ("Cron schedule stale", so GlitchTip keeps it a separate issue from the
# backlog pages) and its own streak (CRON_STREAK_CACHE_KEY, the same
# CONSECUTIVE_CRITICAL_TO_ALERT confirmation). The two are independent: a healthy
# backlog resets only its own streak.
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

  # The cron-freshness streak. Separate from the backlog's, so one condition clearing
  # never resets the other's confirmation.
  CRON_STREAK_CACHE_KEY = "system_health_monitor:consecutive_stale_cron"

  def perform
    system_health = HealthMonitorService.new.system_health

    if system_health[:status].critical?
      handle_critical(system_health)
    else
      # Healthy (or merely elevated) — reset the streak so a later spike must build
      # its own fresh run of consecutive criticals before paging.
      Rails.cache.delete(STREAK_CACHE_KEY)
    end

    check_cron_freshness(system_health)
  end

  private

  # CronFreshness directly rather than HealthMonitorService#cron_health, which rescues
  # a failed read into a warning for the dashboard. Here that rescue would turn a
  # broken check into "nothing stale" — the silent failure this check exists to end —
  # so an error fails the job instead, and a failed job is loud.
  def check_cron_freshness(system_health)
    report = CronFreshness.new.report
    stale = pageable_stale_keys(report, system_health)

    if stale.empty?
      Rails.cache.delete(CRON_STREAK_CACHE_KEY)
      return
    end

    streak = Rails.cache.read(CRON_STREAK_CACHE_KEY).to_i + 1
    Rails.cache.write(CRON_STREAK_CACHE_KEY, streak, expires_in: STREAK_TTL)
    return if streak < CONSECUTIVE_CRITICAL_TO_ALERT

    # .error for the same reason as the backlog page: this line is what trips the
    # Grafana rule. The keys go in the message because the message is all a phone
    # shows; the GlitchTip title below stays fixed so every firing groups as one issue.
    Rails.logger.error(
      "[SystemHealthMonitorJob] Cron schedule stale: #{stale.map { |r| r[:key] }.join(', ')} " \
      "stopped producing jobs (for #{streak} consecutive check(s))"
    )

    ErrorReporter.report_message(
      "Cron schedule stale",
      level: :error,
      context: {
        source: "SystemHealthMonitorJob",
        details: build_cron_details(stale),
        stale_keys: stale.map { |r| r[:key] },
        consecutive_checks: streak
      }
    )
  end

  # The stale keys this page speaks for. While the backlog gate is itself critical, a
  # key held by a RUNNING copy is left to that page: the lane it is running in is the
  # one the backlog page is already describing, with its in-flight breakdown naming
  # the job class, and a second page about the same held threads would say it twice.
  # It is not dropped — once the backlog clears, this streak starts from there. A key
  # nobody is enqueuing, or one whose copy keeps failing, is something the backlog
  # gate cannot see at all, so it pages regardless.
  def pageable_stale_keys(report, system_health)
    stale = report[:keys].select { |r| r[:state] == :stale }
    return stale unless system_health[:status].critical?

    stale.reject { |r| r[:blocker] == :running }
  end

  def build_cron_details(stale)
    [
      "#{stale.size} scheduled key(s) have stopped producing jobs, each judged against its own cadence:",
      "",
      *stale.map { |r| "• #{r[:key]} (#{r[:job_class]}, `#{r[:cron]}`): #{r[:reason]}" },
      "",
      "A key is stale once the tick it owes is more than two of its own intervals late " \
        "(never less than 30 minutes, never more than 2 hours). \"Held by a run\" is a " \
        "perform that has not returned: the job is a singleton, so GoodJob refuses every " \
        "tick while that one row is unfinished, and nothing frees it but the run ending or " \
        "its worker process exiting — a deploy restarts the worker, and GoodJob reclaims the " \
        "row. \"Keeps failing\" is a copy waiting out retry backoff; its error is on the " \
        "row at /jobs. \"Nothing enqueued\" means the cron manager is not producing this " \
        "key at all: a job class that no longer loads, an enqueue that raises on every " \
        "tick, or a copy enqueued outside cron holding the singleton slot.",
      "",
      "Every key's reading is live under `cron_health` in the `get_system_health` MCP " \
        "tool and on /health, including keys that are behind but not paged on (a copy " \
        "waiting for a worker is the queue gates' to report). A key that may legitimately " \
        "go silent for longer than its cadence is exempted with `freshness_exempt:` and a " \
        "reason on its entry in config/cron_schedule.rb."
    ].join("\n")
  end

  def handle_critical(system_health)
    streak = Rails.cache.read(STREAK_CACHE_KEY).to_i + 1
    Rails.cache.write(STREAK_CACHE_KEY, streak, expires_in: STREAK_TTL)

    # Not yet sustained long enough — wait for confirmation before paging.
    return if streak < CONSECUTIVE_CRITICAL_TO_ALERT

    depth = system_health[:queue_depth]

    # .error, because this line IS the page: it is what trips the "any non-staging
    # Zimmer ERROR record" Grafana rule. Nothing else here pages — a GlitchTip issue
    # notifies at most once, ever — so demoting it to .warn takes this alert to
    # zero.
    # Quote the gate's own message rather than rebuilding it: it names WHICH of the
    # two critical shapes fired — a single starved lane, or no lane picking work up
    # at all — and that is the first thing the responder needs.
    Rails.logger.error(
      "[SystemHealthMonitorJob] #{system_health[:status].message} " \
      "(#{depth} ready job(s), for #{streak} consecutive check(s))"
    )

    # The title varies by shape (a wedged lane is not a backlog), so GlitchTip
    # groups the two incidents separately — which is what the two dedup keys used
    # to buy. The exact code, including which lane is starved, rides in context.
    ErrorReporter.report_message(
      alert_title(system_health[:status]),
      level: :error,
      context: {
        source: "SystemHealthMonitorJob",
        details: build_details(system_health),
        status_code: system_health[:status].code.presence,
        queue_depth: depth,
        consecutive_checks: streak
      }
    )
  end

  # A wedged lane is not a backlog, and the title is the one line a human on a phone
  # reads before deciding whether to open the page. "Queue backlog
  # critical" over a page whose body says the worker is holding a full pool on work
  # that will not finish sends the responder looking for the wrong thing.
  #
  # Keyed off the status `code`, which HealthMonitorService owns, rather than off
  # its prose — the message is written for a human and is free to be reworded.
  def alert_title(status)
    case status.code.to_s
    when /\A#{Regexp.escape(HealthMonitorService::WEDGED_LANE_CODE_PREFIX)}:/
      "Queue lane wedged"
    when HealthMonitorService::EXECUTION_STALL_CODE
      # Not a backlog at all: nothing anywhere has finished. A responder who reads
      # "backlog" goes looking for what is deep, and the answer is that nothing is
      # running. (In the total-outage case this job cannot run either — it is on
      # `pollers`, which is exactly the hole the external Grafana rule covers — but
      # a stall confined to the lanes this job does not run on reaches here.)
      "Nothing is executing"
    else
      "Queue backlog critical"
    end
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
    head = stats[:head_of_line]

    [
      system_health[:status].message,
      "",
      "• Ready (waiting on a worker): #{stats[:ready_count]}, " \
        "oldest waiting #{HealthMonitorService.format_wait(stats[:oldest_ready_age_seconds])}" \
        "#{head_of_line_suffix(head)}",
      "• Ready by queue: #{HealthMonitorService.format_breakdown(stats[:ready_count_by_queue])}",
      "• Ready by job class: #{HealthMonitorService.format_breakdown(stats[:ready_count_by_job_class])}",
      "• Oldest ready by queue: " \
        "#{HealthMonitorService.format_ages(stats[:oldest_ready_age_seconds_by_queue])}",
      "• Not backlog: #{stats[:claimed_count]} claimed (executing now), " \
        "#{stats[:scheduled_count]} scheduled (future-dated)",
      "• In flight by queue: #{HealthMonitorService.format_breakdown(stats[:claimed_count_by_queue])} " \
        "(threads: #{HealthMonitorService.format_breakdown(HealthMonitorService.lane_thread_counts)})",
      "• In flight by job class: " \
        "#{HealthMonitorService.format_breakdown(stats[:claimed_count_by_job_class])}",
      "• Oldest execution by queue: " \
        "#{HealthMonitorService.format_ages(stats[:oldest_claimed_age_seconds_by_queue])}",
      "• Youngest execution by queue: " \
        "#{HealthMonitorService.format_ages(stats[:youngest_claimed_age_seconds_by_queue])}",
      "• Processing rate: #{stats[:processing_rate_per_hour]}/hour",
      "• Workers: #{workers[:active_workers]} active / #{workers[:total_workers]} registered",
      "",
      "Every number above is live in the `get_system_health` MCP tool, which is the " \
        "route a responder with no browser session on the production host has: it " \
        "returns these same per-queue and per-job-class breakdowns, so the page can " \
        "be re-read as it moves rather than only as it fired. The GoodJob dashboard " \
        "at /jobs shows the individual rows behind them, for a human who can log in.",
      "",
      "The first line names one of three things: a WEDGED lane, one starved lane, or " \
        "a stall spread across several. Read the in-flight bullets together before " \
        "acting, because they settle what the ready ages cannot. A lane whose in-flight " \
        "count equals its thread count and whose YOUNGEST execution is already hours " \
        "old is wedged: every thread is held by work that is not coming back, so it " \
        "can claim nothing — not the backlog behind it, and not a deploy gate's " \
        "canary. An old oldest beside a fresh youngest is one slow job, not a wedge. " \
        "A lane " \
        "with ready work and NO claims is the opposite failure: the worker is not " \
        "polling that lane at all. Both leave an old head of line and they look " \
        "identical from the ready side alone, which is why these lines exist. " \
        "Long holds are normal in some lanes and not others: an `agents` thread lasts " \
        "as long as its session, `auth` as long as a login CLI is open, while " \
        "`inference`, `maintenance` and `default` run two threads each against jobs " \
        "that should finish in seconds to minutes. EVERY queue old at once, with the " \
        "claims fresh or absent, is the worker itself: down, restarting, or starved of " \
        "database round-trips. The processing rate is a trailing hour and lags any of " \
        "these by many minutes, so a healthy-looking rate beside a stuck lane is " \
        "expected rather than reassuring. The Grafana `not draining` rule reads the " \
        "global ready age, and is gated on throughput so a healthy fleet behind a slow " \
        "lane does not page twice."
    ].join("\n")
  end

  # Names the lane and the job class behind the age the line just quoted, so the
  # first bullet answers "old where" and not only "old". Empty when nothing is
  # ready, which is when there is no head to name.
  #
  # The age and the lane come from the SAME read, which is why every number in this
  # body is taken off the `queue_stats` the gate already computed rather than from a
  # fresh query. Re-reading `good_jobs` here would cost three more scans of the
  # table at exactly the moment the database may be the thing going wrong, and would
  # let the first bullet quote one row's age beside another row's lane whenever the
  # row the gate measured drains in between. `queue_statistics` publishes the whole
  # head row, so the page is assembled entirely from facts the caller already holds.
  def head_of_line_suffix(head)
    return "" if head.blank?

    " (#{head[:queue]} / #{head[:job_class]})"
  end
end
