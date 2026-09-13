# frozen_string_literal: true

require "test_helper"

# CronFreshness reads the newest job each cron key produced and judges it against that
# key's own cadence. These drive it with real `good_jobs` rows, because the answer is a
# lateral join and a witness probe over that table, and a stub of either would test
# nothing.
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

  # A healthy key that enqueued on every tick in `window` — which also makes it the
  # witness that a cron manager was running at each of those ticks.
  def ticking(key, every:, window:, job_class: "PlaceholderJob")
    tick = window.end
    rows = []
    while tick >= window.begin
      rows << { queue_name: "default", job_class: job_class, cron_key: key, cron_at: tick,
                created_at: tick, updated_at: tick, scheduled_at: tick, finished_at: tick + 1 }
      tick -= every
    end
    GoodJob::Job.insert_all(rows)
  end

  def report(entries, now: NOW, cron_running_since: NOW - 1.day, exemptions: {})
    CronFreshness.new(entries: entries, now: now, cron_running_since: cron_running_since,
                      exemptions: exemptions).report
  end

  def reading(result, key)
    result[:keys].find { |r| r[:key] == key.to_s }
  end

  # How the readings stamp an instant, so an expectation does not depend on the zone
  # the suite happens to run in.
  def utc(time)
    time.utc.strftime("%Y-%m-%d %H:%M UTC")
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

  # The ticks a key owes only count if a cron manager was up to fire them: another key
  # stamped with the same fire time is the evidence. Here nothing ticked between the
  # sweep's last row at 09:50 and 11:40, when the worker came back.
  test "ticks that fell while no cron manager was running are excused" do
    cron_row("sweep", enqueued: NOW - 2.hours - 10.minutes, finished: NOW - 2.hours - 10.minutes + 5)
    ticking("clock", every: 1.minute, window: (NOW - 20.minutes)..NOW)
    entries = [ entry(:sweep, "*/5 * * * *"), entry(:clock, "* * * * *") ]

    down = reading(report(entries), :sweep)
    assert_equal :fresh, down[:state], "every tick it owes before 11:30 fell while nothing was ticking"
    assert_operator down[:due_at], :>, NOW - 30.minutes

    ticking("clock", every: 1.minute, window: (NOW - 60.minutes)..(NOW - 50.minutes))
    assert_equal :stale, reading(report(entries), :sweep)[:state], "11:00-11:10 were ticked, and it owed those"
  end

  # The case that rules out "count from the worker's start": deploys land every half hour
  # on a busy day, so a clock restarted by each one would never reach a daily key's grace.
  test "a daily key that missed a tick the cron manager fired is stale however recently the worker restarted" do
    yesterday = Time.new(2026, 9, 10, 6, 0, 0)
    cron_row("daily", enqueued: yesterday, finished: yesterday + 30)
    ticking("clock", every: 1.minute, window: (Time.new(2026, 9, 11, 5, 55, 0))..(Time.new(2026, 9, 11, 6, 5, 0)))

    result = report([ entry(:daily, "0 6 * * *"), entry(:clock, "* * * * *") ],
                    now: Time.new(2026, 9, 11, 12, 0, 0), cron_running_since: Time.new(2026, 9, 11, 11, 50, 0))

    assert_equal :stale, reading(result, :daily)[:state]
  end

  # Disabling a key stops its rows; re-enabling it must not read the days it was off as
  # days it stopped.
  test "a key re-enabled in the dashboard is owed nothing from before it was switched back on" do
    cron_row("sweep", enqueued: NOW - 3.days, finished: NOW - 3.days + 5)
    GoodJob::Setting.cron_key_disable(:sweep)
    GoodJob::Setting.cron_key_enable(:sweep)
    GoodJob::Setting.update_all(updated_at: NOW - 10.minutes)

    assert_equal :fresh, reading(report([ entry(:sweep, "*/5 * * * *") ]), :sweep)[:state]

    GoodJob::Setting.update_all(updated_at: NOW - 3.hours)
    assert_equal :stale, reading(report([ entry(:sweep, "*/5 * * * *") ]), :sweep)[:state]
  end

  # A `perform_later` or a dashboard "run now" of a singleton takes the same slot the
  # cron copy would, so GoodJob refuses every tick behind it. It is judged by what it is
  # doing, not reported as cron failing to enqueue.
  test "a copy enqueued outside cron holding a singleton's slot is judged like a cron copy" do
    cron_row("post_deploy_tasks", enqueued: NOW - 2.hours, finished: NOW - 2.hours + 5, job_class: "PostDeployTaskJob")
    GoodJob::Job.where(cron_key: "post_deploy_tasks").update_all(concurrency_key: "PostDeployTaskJob")
    stray = { queue_name: "default", job_class: "PostDeployTaskJob", cron_key: nil, cron_at: nil,
              concurrency_key: "PostDeployTaskJob", created_at: NOW - 110.minutes, updated_at: NOW - 110.minutes,
              scheduled_at: NOW - 110.minutes }
    GoodJob::Job.insert_all([ stray ])
    entries = [ entry(:post_deploy_tasks, "*/2 * * * *", "PostDeployTaskJob") ]

    waiting = reading(report(entries), :post_deploy_tasks)
    assert_equal :overdue, waiting[:state], "a queued copy is the queue gates' to page on, whoever enqueued it"
    assert waiting[:outside_cron]
    assert_match(/A copy enqueued outside cron has waited 1h 50m for a worker on default/, waiting[:reason])

    GoodJob::Job.where(cron_key: nil).update_all(locked_by_id: SecureRandom.uuid, locked_at: NOW - 100.minutes,
                                                 performed_at: NOW - 100.minutes)
    held = reading(report(entries), :post_deploy_tasks)
    assert_equal :stale, held[:state]
    assert_match(/Held by a run enqueued outside cron on default that started 1h 40m ago/, held[:reason])
  end

  # tadasant/zimmer#1190: the 11:10 copy waited in a backed-up maintenance lane, every tick
  # from 11:20 to 11:50 was refused behind it, and a worker replacement freed the lane so
  # it ran and finished at 11:55. The tick it owes is 12:00, not 11:20.
  test "a singleton whose copy just finished is owed the tick after its slot came free" do
    ticking("clock", every: 1.minute, window: (NOW - 2.hours)..(NOW + 40.minutes))
    cron_row("log_retention", enqueued: NOW - 50.minutes, finished: NOW - 5.minutes,
             queue: "maintenance", job_class: "LogRetentionJob")
    GoodJob::Job.where(cron_key: "log_retention").update_all(concurrency_key: "LogRetentionJob")
    entries = [ entry(:log_retention, "*/10 * * * *", "LogRetentionJob"), entry(:clock, "* * * * *") ]

    drained = reading(report(entries, now: NOW - 2.minutes), :log_retention)
    assert_equal :fresh, drained[:state]
    assert_equal NOW, drained[:due_at]

    silent = reading(report(entries, now: NOW + 35.minutes), :log_retention)
    assert_equal :stale, silent[:state], "a key cron stops enqueuing after its slot came free still pages"
    assert_equal NOW, silent[:due_at]
    assert_match(/Nothing enqueued since #{utc(NOW - 50.minutes)}; owed a job since #{utc(NOW)}/, silent[:reason])
  end

  test "a copy enqueued outside cron that held the slot and finished counts as the slot coming free" do
    ticking("clock", every: 1.minute, window: (NOW - 3.hours)..NOW)
    cron_row("post_deploy_tasks", enqueued: NOW - 2.hours, finished: NOW - 2.hours + 5, job_class: "PostDeployTaskJob")
    GoodJob::Job.where(cron_key: "post_deploy_tasks").update_all(concurrency_key: "PostDeployTaskJob")
    GoodJob::Job.insert_all([ { queue_name: "default", job_class: "PostDeployTaskJob", concurrency_key: "PostDeployTaskJob",
                                created_at: NOW - 110.minutes, updated_at: NOW - 3.minutes,
                                scheduled_at: NOW - 110.minutes, finished_at: NOW - 3.minutes } ])
    entries = [ entry(:post_deploy_tasks, "*/2 * * * *", "PostDeployTaskJob"), entry(:clock, "* * * * *") ]

    assert_equal :fresh, reading(report(entries), :post_deploy_tasks)[:state]
  end

  test "a late finish excuses nothing for a class whose ticks are never refused" do
    ticking("clock", every: 1.minute, window: (NOW - 2.hours)..NOW)
    cron_row("sweep", enqueued: NOW - 50.minutes, finished: NOW - 2.minutes)
    GoodJob::Job.where(cron_key: "sweep").update_all(concurrency_key: "anything")

    sweep = reading(report([ entry(:sweep, "*/10 * * * *"), entry(:clock, "* * * * *") ]), :sweep)

    assert_equal :stale, sweep[:state], "without a limit at enqueue, every tick since 11:20 should have produced a row"
  end

  test "a stray copy of a class with no enqueue limit is not what stops its ticks" do
    cron_row("refresh", enqueued: NOW - 2.hours, finished: NOW - 2.hours + 5, job_class: "RefreshMcpOauthTokensJob")
    GoodJob::Job.update_all(concurrency_key: "anything")
    GoodJob::Job.insert_all([ { queue_name: "default", job_class: "RefreshMcpOauthTokensJob", concurrency_key: "anything",
                                created_at: NOW - 1.hour, updated_at: NOW - 1.hour, scheduled_at: NOW - 1.hour } ])

    refresh = reading(report([ entry(:refresh, "*/5 * * * *", "RefreshMcpOauthTokensJob") ]), :refresh)

    assert_equal :stale, refresh[:state]
    assert_not refresh[:outside_cron]
    assert_match(/nothing holds its slot, so cron is not enqueuing this key/, refresh[:reason])
  end

  test "the newest of a key's ticks is the one it is judged by" do
    cron_row("sweep", enqueued: NOW - 3.hours, finished: NOW - 3.hours + 5)
    cron_row("sweep", enqueued: NOW - 5.minutes, finished: NOW - 5.minutes + 5)

    sweep = reading(report([ entry(:sweep, "*/5 * * * *") ]), :sweep)

    assert_equal :fresh, sweep[:state]
    assert_equal NOW - 5.minutes, sweep[:last_enqueued_at]
  end

  test "a deploy that spans a daily key's fire time does not make it late" do
    yesterday = Time.new(2026, 9, 10, 6, 0, 0)
    cron_row("daily", enqueued: yesterday, finished: yesterday + 30)

    # The worker was down from 05:50 until 06:30 today, so nothing ticked at 06:00 and
    # GoodJob does not catch the tick up. The every-minute key shows the gap; the daily
    # key is excused 06:00 and is next due tomorrow.
    ticking("clock", every: 1.minute, window: Time.new(2026, 9, 11, 5, 0, 0)..Time.new(2026, 9, 11, 5, 50, 0))
    ticking("clock", every: 1.minute, window: Time.new(2026, 9, 11, 6, 30, 0)..Time.new(2026, 9, 11, 12, 0, 0))
    result = report([ entry(:daily, "0 6 * * *"), entry(:clock, "* * * * *") ],
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

  # A "run now" from the GoodJob dashboard carries the cron key but no `cron_at`. It is
  # not a tick, so it neither makes a stopped key look alive nor hides the last real one.
  test "a manual run from the dashboard is not a tick" do
    cron_row("sweep", enqueued: NOW - 2.hours, finished: NOW - 2.hours + 5)
    GoodJob::Job.insert_all([ { queue_name: "default", job_class: "PlaceholderJob", cron_key: "sweep", cron_at: nil,
                                created_at: NOW - 1.minute, updated_at: NOW - 1.minute, scheduled_at: NOW - 1.minute,
                                finished_at: NOW - 1.minute + 2 } ])

    sweep = reading(report([ entry(:sweep, "*/5 * * * *") ]), :sweep)

    assert_equal :stale, sweep[:state]
    assert_equal NOW - 2.hours, sweep[:last_enqueued_at]
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
    ticking("ok", every: 5.minutes, window: (NOW - 4.hours)..(NOW - 5.minutes))
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

  # --- History: has it been running, not just is it running -----------------------

  test "a key that never missed a tick reports a full window and no stop" do
    ticking("sweep", every: 5.minutes, window: (NOW - 30.hours)..NOW)

    sweep = reading(report([ entry(:sweep, "*/5 * * * *") ]), :sweep)

    assert_equal :fresh, sweep[:state]
    assert_equal 289, sweep[:ticks_in_window], "24h of a 5-minute key, both edges included"
    assert_equal 5.minutes.to_i, sweep[:longest_gap_seconds]
    assert_not sweep[:stopped_in_window]
  end

  # The whole point of reading more than the newest row: this key is enqueuing
  # perfectly right now, and the live rule cannot see the hole behind it.
  test "a key that stopped for hours and recovered reads fresh, and says so anyway" do
    ticking("sweep", every: 5.minutes, window: (NOW - 30.hours)..(NOW - 10.hours))
    ticking("sweep", every: 5.minutes, window: (NOW - 4.hours)..NOW)

    result = report([ entry(:sweep, "*/5 * * * *") ])
    sweep = reading(result, :sweep)

    assert_equal :fresh, sweep[:state], "its newest tick is three minutes old; nothing is late"
    assert sweep[:stopped_in_window]
    assert_equal 6.hours.to_i, sweep[:longest_gap_seconds]
    assert_equal NOW - 10.hours, sweep[:gap_started_at]
    assert_equal NOW - 4.hours, sweep[:gap_ended_at]
    assert_equal 1, result[:stopped_in_window]
    assert result[:status].healthy?, "a stop that is over is reported, never paged"
    assert_equal "All 1 judged cron key(s) are enqueuing on schedule. 1 key(s) stopped and recovered " \
                 "in the last 24 hours (sweep silent 6h 0m to #{utc(NOW - 4.hours)})", result[:status].message
  end

  # A hole at the leading edge leaves ordinary gaps between every pair of rows INSIDE
  # the window. It is only visible against the newest tick before the window.
  test "a stop that straddles the start of the window is measured against the tick before it" do
    ticking("sweep", every: 5.minutes, window: (NOW - 30.hours)..(NOW - 27.hours))
    ticking("sweep", every: 5.minutes, window: (NOW - 20.hours)..NOW)

    sweep = reading(report([ entry(:sweep, "*/5 * * * *") ]), :sweep)

    assert sweep[:stopped_in_window]
    assert_equal 7.hours.to_i, sweep[:longest_gap_seconds]
    assert_equal NOW - 27.hours, sweep[:gap_started_at]
  end

  test "a key with no tick before the window has its leading edge left unmeasured" do
    ticking("sweep", every: 5.minutes, window: (NOW - 20.hours)..NOW)

    sweep = reading(report([ entry(:sweep, "*/5 * * * *") ]), :sweep)

    assert_not sweep[:stopped_in_window], "understating a silence loses a finding; it never invents one"
    assert_equal 5.minutes.to_i, sweep[:longest_gap_seconds]
  end

  # The allowance is one interval plus the key's own grace, which is what lets one rule
  # serve every cadence.
  test "a daily key's ordinary 24-hour silence is not a stop, and a 27-hour one is" do
    daily = [ entry(:daily, "0 6 * * *") ]
    now = Time.new(2026, 9, 11, 6, 30, 0)
    [ 2, 1, 0 ].each { |days| cron_row("daily", enqueued: now.change(hour: 6) - days.days, finished: now) }

    assert_not reading(report(daily, now: now), :daily)[:stopped_in_window],
               "24h against an allowance of 24h + the 2h cap"

    GoodJob::Job.where(cron_key: "daily", cron_at: now.change(hour: 6) - 1.day).delete_all
    stopped = reading(report(daily, now: now), :daily)
    assert stopped[:stopped_in_window], "48h against the same allowance"
    assert_equal 48.hours.to_i, stopped[:longest_gap_seconds]
  end

  # A 5-minute singleton whose copy legitimately runs past a tick or two is silent for
  # 15 minutes against an allowance of 35. The same floor that keeps the live rule quiet
  # keeps this one quiet.
  test "a singleton refusing a tick or two while its copy runs is not a stop" do
    ticking("sweep", every: 5.minutes, window: (NOW - 30.hours)..(NOW - 20.minutes))
    ticking("sweep", every: 5.minutes, window: NOW..NOW)

    sweep = reading(report([ entry(:sweep, "*/5 * * * *") ]), :sweep)

    assert_equal 20.minutes.to_i, sweep[:longest_gap_seconds]
    assert_not sweep[:stopped_in_window]
  end

  # GoodJob keeps every key's dashboard switch in one settings row, so its timestamp
  # cannot say WHICH key was flipped. The live rule excuses on it because it pages;
  # this never pages, so it does not, and a stop stays visible whoever toggled what.
  test "a dashboard toggle on any key does not hide a stop, its own included" do
    ticking("sweep", every: 5.minutes, window: (NOW - 30.hours)..(NOW - 10.hours))
    ticking("sweep", every: 5.minutes, window: (NOW - 4.hours)..NOW)
    ticking("other", every: 5.minutes, window: (NOW - 30.hours)..NOW)
    GoodJob::Setting.cron_key_disable(:other)
    GoodJob::Setting.cron_key_enable(:other)
    GoodJob::Setting.update_all(updated_at: NOW - 5.hours)
    entries = [ entry(:sweep, "*/5 * * * *"), entry(:other, "*/5 * * * *") ]

    result = report(entries)
    assert reading(result, :sweep)[:stopped_in_window], "another key's toggle says nothing about this one"
    assert_not reading(result, :other)[:stopped_in_window]
    assert_equal :fresh, reading(result, :sweep)[:state], "the live rule still takes the toggle as a lower bound"

    GoodJob::Setting.cron_key_disable(:sweep)
    GoodJob::Setting.cron_key_enable(:sweep)
    GoodJob::Setting.update_all(updated_at: NOW - 5.hours)
    assert reading(report(entries), :sweep)[:stopped_in_window],
           "switched off for six hours is still six hours of no ticks, and the sentence says stopped, not failed"
  end

  test "a key whose interval is longer than the window gets no history verdict" do
    weekly = Time.new(2026, 9, 7, 6, 0, 0)
    cron_row("weekly", enqueued: weekly, finished: weekly + 30)

    result = reading(report([ entry(:weekly, "0 6 * * 1") ]), :weekly)

    assert_equal 0, result[:ticks_in_window]
    assert_nil result[:longest_gap_seconds]
    assert_not result[:stopped_in_window]
  end

  # An outage stops every key at once. That is true and worth seeing, and it is also
  # not a fifty-name sentence.
  test "the summary names the worst few keys that stopped and counts the rest" do
    keys = (1..5).map { |n| :"sweep#{n}" }
    keys.each_with_index do |key, index|
      ticking(key.to_s, every: 5.minutes, window: (NOW - 30.hours)..(NOW - 10.hours - index.hours))
      ticking(key.to_s, every: 5.minutes, window: (NOW - 4.hours)..NOW)
    end

    result = report(keys.map { |key| entry(key, "*/5 * * * *") })

    assert_equal 5, result[:stopped_in_window]
    assert_match(/sweep5 silent 10h 0m to .*; sweep4 silent 9h 0m to .*; sweep3 silent 8h 0m to .*; and 2 more/,
                 result[:status].message)
  end

  test "keys that are not judged carry no history verdict" do
    ticking("sweep", every: 5.minutes, window: (NOW - 30.hours)..(NOW - 10.hours))
    ticking("sweep", every: 5.minutes, window: (NOW - 4.hours)..NOW)

    exempt = reading(report([ entry(:sweep, "*/5 * * * *") ], exemptions: { "sweep" => "It sleeps" }), :sweep)

    assert_equal :exempt, exempt[:state]
    assert_not exempt[:stopped_in_window]
    assert_equal 218, exempt[:ticks_in_window], "the facts are still reported; only the verdict is withheld"
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
