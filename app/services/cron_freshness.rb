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
# (`GoodJob::CronEntry.last_jobs_by_key`, one lateral join for every key), against when
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
# The clock only runs while a cron manager is running. The due time is taken from the
# later of the key's newest job and the moment the newest live cron-running worker
# registered (plus CRON_STARTUP_SLACK). GoodJob does not catch up ticks a worker was
# down for, so without that a deploy spanning 06:00 would make every daily key read as
# a day late, and a key that has never run — a fresh database, or an entry the deploy
# just added — would read as late since the epoch. Restarting the clock on a restart
# loses nothing: a hung `perform` dies with its worker, and GoodJob reclaims the row.
#
# WHAT IS BEHIND IT, AND WHICH OF THOSE PAGES
# -------------------------------------------
# A key past its grace is read by what is holding it, from its newest row:
#
#   nothing      The newest row finished and no tick since has produced one. Cron is
#                not enqueuing this key. Stale.
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

    last_jobs = GoodJob::CronEntry.last_jobs_by_key(@entries)
    enabled = GoodJob::Setting.cron_keys_enabled(@entries.map { |entry| [ entry.key, entry.enabled_by_default? ] })
    paused = paused_items

    readings = @entries.map do |entry|
      read(entry, last_jobs[entry.key.to_s], since, enabled.fetch(entry.key.to_s, true), paused)
    end
    readings.sort_by! { |r| [ STATE_ORDER.index(r[:state]), -r[:overdue_seconds].to_i, r[:key] ] }

    summary(readings, overall(readings), since)
  end

  private

  def read(entry, job, since, enabled, paused)
    reading = {
      key: entry.key.to_s,
      job_class: entry.job_class.to_s,
      cron: entry.display_schedule.to_s,
      queue: job&.queue_name,
      last_enqueued_at: job && (job.cron_at || job.created_at),
      due_at: nil,
      overdue_seconds: 0,
      grace_seconds: nil,
      blocker: nil,
      blocker_since: nil,
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

    reference = [ reading[:last_enqueued_at], since + CRON_STARTUP_SLACK ].compact.max
    due_at = next_fire(schedule, reference)
    interval = next_fire(schedule, due_at) - due_at
    grace = (interval * GRACE_TICKS).clamp(GRACE_FLOOR.to_f, GRACE_CAP.to_f)
    blocker, blocker_since = blocker_of(job)

    reading.merge!(
      due_at: due_at,
      overdue_seconds: [ @now - due_at, 0 ].max.round,
      grace_seconds: grace.round,
      blocker: blocker,
      blocker_since: blocker_since
    )
    return reading if @now - due_at < grace

    state, reason = judge(reading)
    reading.merge(state: state, reason: reason)
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

    case reading[:blocker]
    when nil
      if reading[:last_enqueued_at]
        [ :stale, "Nothing enqueued since #{stamp(reading[:last_enqueued_at])}; #{owed}. " \
                  "Its last job finished, so cron is not enqueuing this key" ]
      else
        [ :stale, "Never enqueued since the cron manager started; #{owed}" ]
      end
    when :retrying
      [ :stale, "Its copy keeps failing (#{reading[:executions]} attempt(s)), next retry " \
                "#{stamp(reading[:blocker_since])}; every tick until then is refused. #{owed.upcase_first}" ]
    when :running
      running_for = @now - reading[:blocker_since]
      ceiling = HealthMonitorService::LANE_EXECUTION_CEILINGS.fetch(reading[:queue], 0)
      if running_for >= ceiling
        [ :stale, "Held by a run on #{reading[:queue]} that started #{ago(running_for)} ago and has not " \
                  "finished; every tick since has been refused. #{owed.upcase_first}" ]
      else
        [ :overdue, "A run on #{reading[:queue]} has been going #{ago(running_for)}, inside the " \
                    "#{ago(ceiling)} that lane allows; #{owed}" ]
      end
    when :waiting
      where = reading[:paused] ? "#{reading[:queue]}, which is paused" : reading[:queue]
      [ :overdue, "Its copy has waited #{ago(@now - reading[:blocker_since])} for a worker on #{where}; " \
                  "#{owed}. A queue that is not draining is the queue gates' to page on" ]
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
