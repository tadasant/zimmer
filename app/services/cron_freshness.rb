# frozen_string_literal: true

# Has every scheduled cron key produced a job recently, judged against its own cadence?
#
# WHY THIS EXISTS
# ---------------
# Most recurring jobs are singletons (`SingletonSweep`, or a hand-written
# `total_limit: 1`), so at most one copy of each can be unfinished. That is what
# stopped the 2026-08-22 pile-up, and it also removed the only signal that a sweep had
# stopped: when a `perform` hangs, its one unfinished row makes GoodJob refuse every
# later cron tick for that class, for ever, and the ready backlog stays flat. Nothing
# measured by the queue gates moves. The sweep just stops (tadasant/zimmer#619).
#
# The same silence covers a key the cron manager is failing to enqueue at all — a
# class that no longer loads, an enqueue that raises on every tick — because GoodJob's
# cron reschedules the next tick before it enqueues this one and logs nothing a page
# reads.
#
# So this reads the one fact both failures share: the newest job each key has produced
# (one lateral join for every key, served by the `(cron_key, cron_at)` index), against when
# that key's own schedule says the next one was due.
#
# THE RULE
# --------
# A key is behind once it owes a job — its next scheduled fire time after the newest
# job it produced has passed — and has owed it for longer than its grace:
#
#   grace = GRACE_TICKS x its own interval, clamped to GRACE_FLOOR..GRACE_CAP
#
# 30 seconds and 15 minutes both get the 30-minute floor; hourly gets the 2-hour cap,
# as do 6-hourly and daily. The floor is what keeps a fast singleton that legitimately
# runs past a tick or two — a sweep holding its thread for a 90-second slice on a
# 30-second cadence — from reading as stopped. The cap is what keeps a daily job from
# needing three days of silence before anyone hears about it: a daily key has no
# legitimate way to miss its tick under a running cron manager (its previous run
# cannot still be going 24 hours later unless it is hung), so two hours after 06:00
# with nothing enqueued is already the answer.
#
# A tick only counts against a key if a cron manager was running when it fell. GoodJob
# does not catch up ticks a worker was down for, so a deploy spanning 06:00 would
# otherwise make every daily key read as a day late. So before a key is judged, the
# ticks it owes (the newest WITNESS_PROBES of them) are checked for a witness: another
# key's cron row stamped with that exact fire time. The every-minute keys fire on every
# minute boundary, so a tick at which the cron manager was up has witnesses, and a tick
# that fell inside a deploy has none and is excused. This is deliberately NOT "count
# from the worker's start": deploys here are frequent enough that a clock restarted on
# every deploy would rarely run long enough to judge an hourly key, let alone a daily
# one, and a key whose enqueue fails on every tick fails across deploys too.
#
# Two lower bounds still apply. A key with no row at all — a fresh database, an entry a
# deploy just added — is counted from when the newest live cron-running worker
# registered (plus CRON_STARTUP_SLACK), since only a worker carrying the entry can have
# enqueued it. And no key is owed a tick from before the last time a cron key was
# enabled or disabled in the GoodJob dashboard, so re-enabling one does not read the
# days it was switched off as days it stopped.
#
# WHAT IS BEHIND IT, AND WHICH OF THOSE PAGES
# -------------------------------------------
# A key past its grace is read by what is holding it, from its newest row:
#
#   nothing      The newest row finished, no tick since has produced one, and no other
#                copy holds its singleton slot. Cron is not enqueuing this key. Stale.
#
# A singleton's slot can also be held by a copy enqueued outside cron — a
# `perform_later`, a "run now" from the dashboard — which GoodJob counts against the
# same `total_limit` and so refuses every tick behind it. When the newest tick has
# finished, the unfinished copy with the same concurrency key is read instead, by the
# same three rules below.
#   retrying     Its copy keeps failing and is waiting out a backoff. Stale.
#   running      Its copy has been executing since before the tick it owes. Stale once
#                that run is also past its lane's HealthMonitorService::
#                LANE_EXECUTION_CEILINGS — the same bound the wedged-lane gate uses for
#                "evidence of a wedge rather than work". Inside it, overdue.
#   waiting      Its copy is ready and no worker has picked it up. Overdue, never stale.
#
# Only `stale` pages (SystemHealthMonitorJob). A copy that is waiting on a worker is a
# queue that is not draining, and the queue gates — the lane thresholds, the wedged-lane
# branch, the Grafana `not draining` rule — are what page on that, sized for each lane
# (an `agents` job waiting hours is admission control, not a fault). Paging on it here
# too would say the same thing twice, and would page right after queue recovery mode
# lifts, while the halted lanes are still draining the copies it froze.
#
# Two readings are never judged at all: a key disabled in the GoodJob dashboard
# (`disabled`), and a key whose entry in config/cron_schedule.rb carries
# `freshness_exempt:` with its reason (`exempt`).
class CronFreshness
  GRACE_TICKS = 2
  GRACE_FLOOR = 30.minutes
  GRACE_CAP = 2.hours

  # Between a worker registering its GoodJob process row and its cron manager having
  # scheduled a first tick. A tick that falls inside it may be missed without anything
  # being wrong.
  CRON_STARTUP_SLACK = 1.minute

  # How many of the ticks a key owes are checked for a witness, newest first. Ten
  # minute-boundaries is ten minutes of a running cron manager; ten daily ticks is ten
  # days. Bounded so a thirty-second key silent for a week does not probe twenty
  # thousand timestamps.
  WITNESS_PROBES = 10

  # Worst first, which is the order every surface lists keys in.
  STATE_ORDER = %i[stale overdue disabled exempt fresh].freeze

  # @param entries [Array<GoodJob::CronEntry>] the schedule this process is configured
  #   with. Injectable for tests, whose environment schedules nothing.
  # @param now [Time]
  # @param cron_running_since [Time, nil, :lookup] when the newest live cron-running
  #   worker registered. `:lookup` reads it from `good_job_processes`.
  # @param exemptions [Hash{String => String}] key => why it is not judged
  def initialize(entries: GoodJob::CronEntry.all, now: Time.current, cron_running_since: :lookup,
                 exemptions: CronSchedule.freshness_exemptions)
    @entries = entries
    @now = now
    @cron_running_since = cron_running_since
    @exemptions = exemptions
  end

  # @return [Hash] :status (HealthMonitorService::HealthStatus), :cron_running_since,
  #   :checked_at, :counts ({state => n}) and :keys (one reading per key, worst first)
  def report
    return summary([], status(:healthy, "No cron schedule in this environment")) if @entries.empty?

    since = cron_running_since
    if since.nil?
      # Not a finding this can page on: the worker runs cron AND this check, so a fleet
      # with no live worker is the heartbeat rule's to report, and a key cannot be late
      # against a cron manager that is not there.
      return summary([], status(:unknown, "No live worker is running the cron schedule, so freshness cannot be judged"))
    end

    last_jobs = newest_tick_by_key
    enabled = GoodJob::Setting.cron_keys_enabled(@entries.map { |entry| [ entry.key, entry.enabled_by_default? ] })
    @toggled_at = GoodJob::Setting.where(
      key: [ GoodJob::Setting::CRON_KEYS_ENABLED, GoodJob::Setting::CRON_KEYS_DISABLED ]
    ).maximum(:updated_at)
    paused = paused_items

    readings = @entries.map do |entry|
      read(entry, last_jobs[entry.key.to_s], since, enabled.fetch(entry.key.to_s, true), paused)
    end
    readings.sort_by! { |r| [ STATE_ORDER.index(r[:state]), -r[:overdue_seconds].to_i, r[:key] ] }

    summary(readings, overall(readings), since)
  end

  private

  # The newest row each key's cron ticks produced: one lateral join, one row per key.
  #
  # GoodJob's own `CronEntry.last_jobs_by_key` is the same join ordered
  # `cron_at DESC NULLS LAST`, which the `(cron_key, cron_at)` index cannot serve, so
  # Postgres sorts every retained row of every key. At fourteen days of retention that
  # is ~320,000 rows and ~215 ms, paid on every /health refresh and every monitor tick.
  # Every cron tick sets `cron_at` (only a manual "run now" from the dashboard leaves
  # it null, and that is not a tick), so this filters the nulls out and orders plain
  # `DESC`, and each key becomes one backward index probe.
  def newest_tick_by_key
    keys = @entries.map { |entry| entry.key.to_s }
    from = GoodJob::Job.sanitize_sql_array([ "unnest(ARRAY[?]::text[]) AS cron_keys(cron_key)", keys ])

    GoodJob::Job.select("lateral_jobs.*").from(from).joins(<<~SQL.squish).index_by(&:cron_key)
      CROSS JOIN LATERAL (
        SELECT * FROM good_jobs
        WHERE good_jobs.cron_key = cron_keys.cron_key AND good_jobs.cron_at IS NOT NULL
        ORDER BY good_jobs.cron_at DESC
        LIMIT 1
      ) AS lateral_jobs
    SQL
  end

  def read(entry, job, since, enabled, paused)
    reading = {
      key: entry.key.to_s,
      job_class: entry.job_class.to_s,
      cron: entry.display_schedule.to_s,
      queue: job&.queue_name,
      last_enqueued_at: job&.cron_at,
      due_at: nil,
      overdue_seconds: 0,
      grace_seconds: nil,
      blocker: nil,
      blocker_since: nil,
      outside_cron: false,
      executions: job&.executions_count,
      paused: job.present? && paused_job?(job, paused),
      state: :fresh,
      reason: nil
    }

    return reading.merge(state: :disabled, reason: "Disabled in the GoodJob dashboard") unless enabled

    if (exemption = @exemptions[reading[:key]])
      return reading.merge(state: :exempt, reason: exemption)
    end

    schedule = Fugit.parse_cron(entry.display_schedule.to_s)
    return reading.merge(state: :exempt, reason: "A computed schedule has no fixed cadence to judge") if schedule.nil?

    reference = [ reading[:last_enqueued_at] || since + CRON_STARTUP_SLACK, @toggled_at ].compact.max
    due_at = next_fire(schedule, reference)
    interval = next_fire(schedule, due_at) - due_at
    grace = (interval * GRACE_TICKS).clamp(GRACE_FLOOR.to_f, GRACE_CAP.to_f)

    if @now - due_at >= grace
      owed = owed_ticks(schedule, reference, @now - grace)
      # No cron manager was running at any tick it owes: excused, and owed the next one.
      due_at = next_fire(schedule, owed.first) unless witnessed?(reading[:key], owed)
    end

    blocker, blocker_since = blocker_of(job)
    reading.merge!(
      due_at: due_at,
      overdue_seconds: [ @now - due_at, 0 ].max.round,
      grace_seconds: grace.round,
      blocker: blocker,
      blocker_since: blocker_since
    )
    return reading if @now - due_at < grace

    if blocker.nil? && (holder = slot_holder(job))
      holder_blocker, holder_since = blocker_of(holder)
      reading.merge!(
        blocker: holder_blocker, blocker_since: holder_since, outside_cron: true,
        queue: holder.queue_name, executions: holder.executions_count, paused: paused_job?(holder, paused)
      )
    end

    state, reason = judge(reading)
    reading.merge(state: state, reason: reason)
  end

  # The fire times a key owes, newest first: after `after`, no later than `upto`, at
  # most WITNESS_PROBES of them. Never empty when called, because the key's first owed
  # tick is itself inside that window.
  def owed_ticks(schedule, after, upto)
    ticks = []
    cursor = upto + 1
    while ticks.size < WITNESS_PROBES
      cursor = schedule.previous_time(cursor.to_time.getlocal).to_t
      break if cursor <= after

      ticks << cursor
    end
    ticks
  end

  # Was a cron manager running at any of these ticks? Another key's cron row stamped
  # with the same fire time says it was. Restricted to the configured keys so each
  # becomes an index probe on `(cron_key, cron_at)`. A schedule of one key has nothing
  # to witness with, and is judged on its own rows.
  def witnessed?(key, ticks)
    others = @entries.map { |entry| entry.key.to_s } - [ key ]
    return true if others.empty?

    GoodJob::Job.where(cron_key: others, cron_at: ticks).exists?
  end

  # The unfinished copy holding a singleton's slot when the newest tick has already
  # finished. Only a class whose concurrency limit applies at enqueue can have its tick
  # refused; any other class's stray copies are not what is stopping the tick.
  def slot_holder(job)
    return nil if job.nil? || job.concurrency_key.blank?

    config = job.job_class.to_s.safe_constantize.try(:good_job_concurrency_config) || {}
    return nil unless config[:total_limit] || config[:enqueue_limit]

    GoodJob::Job.where(concurrency_key: job.concurrency_key, finished_at: nil).order(:created_at).first
  end

  # What the newest row says is holding the key. Mirrors the populations
  # HealthMonitorService#queue_statistics partitions `good_jobs` into — claimed is
  # `locked_by_id`, and an execution is aged from `performed_at` — so the two surfaces
  # cannot disagree about the same row.
  def blocker_of(job)
    return [ nil, nil ] if job.nil? || job.finished_at.present?

    if job.locked_by_id.present?
      [ :running, job.performed_at || job.locked_at || job.created_at ]
    elsif job.scheduled_at.present? && job.scheduled_at > @now
      [ :retrying, job.scheduled_at ]
    else
      [ :waiting, job.scheduled_at || job.created_at ]
    end
  end

  def judge(reading)
    owed = "owed a job since #{stamp(reading[:due_at])}"
    copy = reading[:outside_cron] ? "a copy enqueued outside cron" : "its copy"
    run = reading[:outside_cron] ? "a run enqueued outside cron" : "a run"

    case reading[:blocker]
    when nil
      if reading[:last_enqueued_at]
        [ :stale, "Nothing enqueued since #{stamp(reading[:last_enqueued_at])}; #{owed}. " \
                  "Its last job finished and nothing holds its slot, so cron is not enqueuing this key" ]
      else
        [ :stale, "Never enqueued since the cron manager started; #{owed}" ]
      end
    when :retrying
      [ :stale, "#{copy.upcase_first} keeps failing (#{reading[:executions]} attempt(s)), next retry " \
                "#{stamp(reading[:blocker_since])}; every tick until then is refused. #{owed.upcase_first}" ]
    when :running
      running_for = @now - reading[:blocker_since]
      ceiling = HealthMonitorService::LANE_EXECUTION_CEILINGS.fetch(reading[:queue], 0)
      if running_for >= ceiling
        [ :stale, "Held by #{run} on #{reading[:queue]} that started #{ago(running_for)} ago and has not " \
                  "finished; every tick since has been refused. #{owed.upcase_first}" ]
      else
        [ :overdue, "#{run.upcase_first} on #{reading[:queue]} has been going #{ago(running_for)}, inside the " \
                    "#{ago(ceiling)} that lane allows; #{owed}" ]
      end
    when :waiting
      where = reading[:paused] ? "#{reading[:queue]}, which is paused" : reading[:queue]
      [ :overdue, "#{copy.upcase_first} has waited #{ago(@now - reading[:blocker_since])} for a worker on " \
                  "#{where}; #{owed}. A queue that is not draining is the queue gates' to page on" ]
    end
  end

  def overall(readings)
    stale = readings.select { |r| r[:state] == :stale }
    overdue = readings.select { |r| r[:state] == :overdue }

    if stale.any?
      status(:critical, "Cron schedule stale: #{stale.size} key(s) stopped producing jobs " \
                        "(#{stale.map { |r| r[:key] }.join(', ')})")
    elsif overdue.any?
      status(:warning, "#{overdue.size} cron key(s) behind while their jobs wait or run " \
                       "(#{overdue.map { |r| r[:key] }.join(', ')})")
    else
      judged = readings.count { |r| r[:state] == :fresh }
      status(:healthy, "All #{judged} judged cron key(s) are enqueuing on schedule")
    end
  end

  def summary(readings, status, since = nil)
    {
      status: status,
      cron_running_since: since,
      checked_at: @now,
      counts: STATE_ORDER.to_h { |state| [ state, readings.count { |r| r[:state] == state } ] },
      keys: readings
    }
  end

  # The newest live worker that runs cron. The newest rather than the oldest: during a
  # deploy cutover the old worker is still registered, running the OLD schedule, and a
  # key the deploy added must not be judged against a cron manager that never carried
  # it. Erring toward a later start can only delay a finding, never invent one.
  #
  # "Not explicitly false" rather than "true", so a GoodJob that stopped writing the
  # flag degrades to counting every live worker instead of to never judging anything.
  def cron_running_since
    return @cron_running_since unless @cron_running_since == :lookup

    GoodJob::Process
      .where(updated_at: (@now - HealthMonitorService::WORKER_ACTIVE_INTERVAL)..)
      .where("COALESCE(state ->> 'cron_enabled', 'true') <> 'false'")
      .maximum(:created_at)
  end

  def paused_items
    GoodJob.paused
  rescue StandardError => e
    Rails.logger.warn("[CronFreshness] could not read GoodJob pauses: #{e.class}: #{e.message}")
    {}
  end

  def paused_job?(job, paused)
    Array(paused[:queues]).include?(job.queue_name) || Array(paused[:job_classes]).include?(job.job_class)
  end

  # Fire times are computed in the process's local zone, which is what GoodJob's own
  # `CronEntry#next_at` does, so a daily entry is due when GoodJob would fire it.
  def next_fire(schedule, after)
    schedule.next_time(after.to_time.getlocal).to_t
  end

  def status(level, message)
    HealthMonitorService::HealthStatus.new(status: level, message: message)
  end

  def stamp(time)
    time.utc.strftime("%Y-%m-%d %H:%M UTC")
  end

  def ago(seconds)
    HealthMonitorService.format_wait(seconds)
  end
end
