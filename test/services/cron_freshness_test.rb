# frozen_string_literal: true

require "test_helper"

# CronFreshness reads the newest job each cron key produced and judges it against that
# key's own cadence. These drive it with real `good_jobs` rows, because the answer is
# GoodJob's own `last_jobs_by_key` lateral join and a stub of that would test nothing.
class CronFreshnessTest < ActiveSupport::TestCase
  # A fixed instant so every cadence lands on a boundary. Local time, because fire
  # times are computed in the process's zone the way GoodJob computes them.
  NOW = Time.new(2026, 9, 11, 12, 0, 0)

  setup do
    GoodJob::Job.delete_all
    GoodJob::Setting.delete_all
    GoodJob::Process.delete_all
  end

  def entry(key, cron, job_class = "PlaceholderJob")
    GoodJob::CronEntry.new(key: key, cron: cron, class: job_class)
  end

  # One cron row for `key`. `enqueued` is the tick it was for; the rest describe what
  # became of it.
  def cron_row(key, enqueued:, finished: nil, running_since: nil, retry_at: nil, queue: "default",
               executions: 1, job_class: "PlaceholderJob")
    GoodJob::Job.insert_all([ {
      queue_name: queue, job_class: job_class, cron_key: key, cron_at: enqueued,
      created_at: enqueued, updated_at: enqueued, scheduled_at: retry_at || enqueued,
      finished_at: finished, performed_at: running_since,
      locked_by_id: running_since && SecureRandom.uuid, locked_at: running_since,
      executions_count: executions
    } ])
  end

  def report(entries, now: NOW, cron_running_since: NOW - 1.day, exemptions: {})
    CronFreshness.new(entries: entries, now: now, cron_running_since: cron_running_since,
                      exemptions: exemptions).report
  end

  def reading(result, key)
    result[:keys].find { |r| r[:key] == key.to_s }
  end

  test "a key that enqueued on its last tick is fresh" do
    cron_row("sweep", enqueued: NOW - 3.minutes, finished: NOW - 3.minutes + 2)

    result = report([ entry(:sweep, "*/5 * * * *") ])

    assert_equal :fresh, reading(result, :sweep)[:state]
    assert result[:status].healthy?
    assert_equal "All 1 judged cron key(s) are enqueuing on schedule", result[:status].message
  end

  test "a key whose last job finished and whose ticks stopped arriving is stale" do
    cron_row("sweep", enqueued: NOW - 2.hours, finished: NOW - 2.hours + 5)

    result = report([ entry(:sweep, "*/5 * * * *") ])
    sweep = reading(result, :sweep)

    assert_equal :stale, sweep[:state]
    assert_nil sweep[:blocker]
    assert_match(/Nothing enqueued since .*cron is not enqueuing this key/, sweep[:reason])
    assert_equal 30.minutes.to_i, sweep[:grace_seconds]
    assert result[:status].critical?
    assert_equal "Cron schedule stale: 1 key(s) stopped producing jobs (sweep)", result[:status].message
  end

  test "a key is not stale until it has owed a job for the whole of its grace" do
    # Due at 11:35 (the tick after 11:30); 25 minutes owed against a 30-minute grace.
    cron_row("sweep", enqueued: NOW - 30.minutes, finished: NOW - 30.minutes + 5)
    assert_equal :fresh, reading(report([ entry(:sweep, "*/5 * * * *") ]), :sweep)[:state]

    # Due at 11:30; 30 minutes owed.
    GoodJob::Job.delete_all
    cron_row("sweep", enqueued: NOW - 35.minutes, finished: NOW - 35.minutes + 5)
    assert_equal :stale, reading(report([ entry(:sweep, "*/5 * * * *") ]), :sweep)[:state]
  end

  test "a key that has never run is judged from when the cron manager started, not the epoch" do
    fresh_start = report([ entry(:new_key, "*/5 * * * *") ], cron_running_since: NOW - 10.minutes)
    assert_equal :fresh, reading(fresh_start, :new_key)[:state],
                 "a fresh database or a just-deployed entry has not had the chance to run yet"

    long_up = report([ entry(:new_key, "*/5 * * * *") ], cron_running_since: NOW - 3.hours)
    never = reading(long_up, :new_key)
    assert_equal :stale, never[:state]
    assert_nil never[:last_enqueued_at]
    assert_match(/Never enqueued since the cron manager started/, never[:reason])
  end

  test "a daily key gets the two-hour cap, not three days of silence" do
    daily = [ entry(:daily, "0 6 * * *") ]
    yesterday = Time.new(2026, 9, 10, 6, 0, 0)
    cron_row("daily", enqueued: yesterday, finished: yesterday + 30)

    at_seven = report(daily, now: Time.new(2026, 9, 11, 7, 0, 0), cron_running_since: yesterday - 1.hour)
    assert_equal :fresh, reading(at_seven, :daily)[:state], "an hour past 06:00 is inside the grace"
    assert_equal 2.hours.to_i, reading(at_seven, :daily)[:grace_seconds]

    at_eight_thirty = report(daily, now: Time.new(2026, 9, 11, 8, 30, 0), cron_running_since: yesterday - 1.hour)
    assert_equal :stale, reading(at_eight_thirty, :daily)[:state]
  end

  test "a deploy that spans a daily key's fire time does not make it late" do
    yesterday = Time.new(2026, 9, 10, 6, 0, 0)
    cron_row("daily", enqueued: yesterday, finished: yesterday + 30)

    # The worker restarted at 06:30 today, so no cron manager was running at 06:00 and
    # GoodJob does not catch the tick up. The key is next due tomorrow.
    result = report([ entry(:daily, "0 6 * * *") ],
                    now: Time.new(2026, 9, 11, 12, 0, 0), cron_running_since: Time.new(2026, 9, 11, 6, 30, 0))

    assert_equal :fresh, reading(result, :daily)[:state]
    assert_equal Time.new(2026, 9, 12, 6, 0, 0), reading(result, :daily)[:due_at]
  end

  test "a singleton held by a run past its lane's ceiling is stale" do
    started = NOW - 40.minutes
    cron_row("heartbeat", enqueued: started, running_since: started)

    held = reading(report([ entry(:heartbeat, "*/30 * * * * *") ]), :heartbeat)

    assert_equal :stale, held[:state]
    assert_equal :running, held[:blocker]
    assert_match(/Held by a run on default that started 40m ago and has not finished/, held[:reason])
  end

  test "a run still inside its lane's designed hold is behind, not stale" do
    # maintenance allows a thread to be held for 90 minutes (LANE_EXECUTION_CEILINGS).
    started = NOW - 40.minutes
    cron_row("archive", enqueued: started, running_since: started, queue: "maintenance")

    slow = reading(report([ entry(:archive, "*/10 * * * *") ]), :archive)

    assert_equal :overdue, slow[:state]
    assert_match(/inside the 1h 30m that lane allows/, slow[:reason])
  end

  test "a copy waiting for a worker is behind and never stale, and says when its queue is paused" do
    queued = NOW - 3.hours
    cron_row("sweep", enqueued: queued)
    GoodJob.pause(queue: "default")

    waiting = reading(report([ entry(:sweep, "*/5 * * * *") ]), :sweep)

    assert_equal :overdue, waiting[:state]
    assert_equal :waiting, waiting[:blocker]
    assert waiting[:paused]
    assert_match(/waited 3h 0m for a worker on default, which is paused/, waiting[:reason])
  end

  test "a copy stuck retrying is stale" do
    cron_row("sweep", enqueued: NOW - 2.hours, retry_at: NOW + 10.minutes, executions: 6)

    retrying = reading(report([ entry(:sweep, "*/5 * * * *") ]), :sweep)

    assert_equal :stale, retrying[:state]
    assert_equal :retrying, retrying[:blocker]
    assert_match(/keeps failing \(6 attempt\(s\)\)/, retrying[:reason])
  end

  test "an exempted key is listed with its reason and never judged" do
    cron_row("rare", enqueued: NOW - 5.days, finished: NOW - 5.days + 1)

    result = report([ entry(:rare, "*/5 * * * *") ], exemptions: { "rare" => "Enabled by hand only" })

    assert_equal :exempt, reading(result, :rare)[:state]
    assert_equal "Enabled by hand only", reading(result, :rare)[:reason]
    assert result[:status].healthy?
  end

  test "a key disabled in the GoodJob dashboard is not judged" do
    cron_row("off", enqueued: NOW - 5.days, finished: NOW - 5.days + 1)
    GoodJob::Setting.cron_key_disable(:off)

    result = report([ entry(:off, "*/5 * * * *") ])

    assert_equal :disabled, reading(result, :off)[:state]
    assert result[:status].healthy?
  end

  test "keys are listed worst first, and counted by state" do
    cron_row("ok", enqueued: NOW - 1.minute)
    cron_row("dead", enqueued: NOW - 3.hours, finished: NOW - 3.hours + 1)
    cron_row("queued", enqueued: NOW - 3.hours)

    result = report([ entry(:ok, "*/5 * * * *"), entry(:queued, "*/5 * * * *"), entry(:dead, "*/5 * * * *") ])

    assert_equal %w[dead queued ok], result[:keys].map { |r| r[:key] }
    assert_equal({ stale: 1, overdue: 1, disabled: 0, exempt: 0, fresh: 1 }, result[:counts])
  end

  test "nothing is judged with no schedule, or with no live worker running one" do
    empty = report([])
    assert empty[:status].healthy?
    assert_equal "No cron schedule in this environment", empty[:status].message

    dark = report([ entry(:sweep, "*/5 * * * *") ], cron_running_since: nil)
    assert dark[:status].unknown?
    assert_empty dark[:keys]
  end

  test "the cron manager's start is the newest live worker that runs cron" do
    now = Time.current
    old_worker = now - 6.hours
    new_worker = now - 20.minutes
    GoodJob::Process.insert_all([
      { id: SecureRandom.uuid, state: { cron_enabled: true }, created_at: old_worker, updated_at: now },
      { id: SecureRandom.uuid, state: { cron_enabled: true }, created_at: new_worker, updated_at: now },
      # Dead: its heartbeat is past WORKER_ACTIVE_INTERVAL, however recent its start.
      { id: SecureRandom.uuid, state: { cron_enabled: true }, created_at: now - 1.minute, updated_at: now - 1.hour },
      # Live, but says it does not run cron.
      { id: SecureRandom.uuid, state: { cron_enabled: false }, created_at: now - 2.minutes, updated_at: now }
    ])

    result = CronFreshness.new(entries: [ entry(:sweep, "*/5 * * * *") ], now: now, exemptions: {}).report

    assert_in_delta new_worker, result[:cron_running_since], 1
  end

  # The demonstration: every entry production actually schedules, and the grace each
  # one gets from its own cadence.
  test "the grace for each real production entry follows its own cadence" do
    now = Time.new(2026, 9, 11, 12, 0, 0)
    entries = CronSchedule.for(:production).map do |key, e|
      GoodJob::CronEntry.new(key: key, cron: e[:cron], class: e[:class])
    end

    graces = report(entries, now: now)[:keys].to_h { |r| [ r[:key], r[:grace_seconds] ] }

    assert_equal 30.minutes.to_i, graces["heartbeat_sweep"], "30s: the floor"
    assert_equal 30.minutes.to_i, graces["token_usage_backfill"], "5m: the floor"
    assert_equal 30.minutes.to_i, graces["quota_reset_checker"], "15m: the floor"
    assert_equal 40.minutes.to_i, graces["burn_rate_recompute"], "20m: two ticks"
    assert_equal 60.minutes.to_i, graces["refresh_mcp_oauth_tokens"], "30m: two ticks"
    assert_equal 2.hours.to_i, graces["stale_clone_cleanup"], "hourly: two ticks, which is the cap"
    assert_equal 2.hours.to_i, graces["docker_cleanup"], "6h: the cap"
    assert_equal 2.hours.to_i, graces["claude_code_update"], "daily: the cap"
  end
end
