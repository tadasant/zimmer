# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The core of #427's proof: the watchdog fires when the GoodJob queue executes nothing,
# because it is a plain object driven from the web process rather than a job on the
# queue it watches.
class QueueLivenessWatchdogTest < ActiveSupport::TestCase
  teardown { Mocha::Mockery.instance.teardown }

  # A stand-in for HealthMonitorService that returns whatever health hash a test hands
  # it, without touching the database. The watchdog only reads `system_health`.
  FakeHealthMonitor = Struct.new(:health) do
    def system_health
      health
    end
  end

  def stall_health(active_workers: 0, since: 900)
    {
      status: HealthMonitorService::HealthStatus.new(
        status: :critical,
        code: HealthMonitorService::EXECUTION_STALL_CODE,
        message: "Nothing is executing: no job has finished anywhere in 15 minutes, and no worker is reporting a heartbeat (#{active_workers} worker(s) reporting a heartbeat)."
      ),
      queue_stats: { seconds_since_last_finished: since },
      worker_stats: { active_workers: active_workers }
    }
  end

  def healthy_health
    {
      status: HealthMonitorService::HealthStatus.new(status: :healthy, message: "Queue processing normally"),
      queue_stats: { seconds_since_last_finished: 3 },
      worker_stats: { active_workers: 1 }
    }
  end

  def watchdog_for(health)
    QueueLivenessWatchdog.new(health_monitor: FakeHealthMonitor.new(health))
  end

  test "one stall observation builds the streak but does not page" do
    watchdog = watchdog_for(stall_health)
    ErrorReporter.expects(:report_message).never

    assert_equal :stalled, watchdog.check!
    assert_equal 1, watchdog.consecutive_stalls
  end

  test "the second consecutive stall pages via ERROR log and ErrorReporter" do
    watchdog = watchdog_for(stall_health)

    Rails.logger.expects(:error).with { |msg| msg.include?("QueueLivenessWatchdog") && msg.include?("out-of-band") }
    ErrorReporter.expects(:report_message).with(
      QueueLivenessWatchdog::ALERT_TITLE,
      has_entry(level: :error)
    )

    watchdog.check! # streak 1, silent
    watchdog.check! # streak 2, pages
    assert_equal 2, watchdog.consecutive_stalls
  end

  test "a sustained stall keeps paging every tick so the Grafana rule stays fresh" do
    watchdog = watchdog_for(stall_health)
    # Every tick from the second onward pages: a single log line ten hours ago would
    # not keep a rule that pages on recent ERROR records firing.
    ErrorReporter.expects(:report_message).times(3)
    Rails.logger.stubs(:error)

    4.times { watchdog.check! } # tick 1 silent, ticks 2-4 page
    assert_equal 4, watchdog.consecutive_stalls
  end

  test "a healthy check resets the streak so a blip cannot page" do
    watchdog = QueueLivenessWatchdog.new(
      health_monitor: FakeHealthMonitor.new(stall_health)
    )
    ErrorReporter.expects(:report_message).never
    Rails.logger.stubs(:error)

    watchdog.check! # streak 1
    watchdog.instance_variable_get(:@health_monitor).health = healthy_health
    assert_equal :healthy, watchdog.check! # resets to 0
    assert_equal 0, watchdog.consecutive_stalls

    # A single fresh stall after the reset is only streak 1 again, so still silent.
    watchdog.instance_variable_get(:@health_monitor).health = stall_health
    assert_equal :stalled, watchdog.check!
    assert_equal 1, watchdog.consecutive_stalls
  end

  test "a paused stall (queue recovery mode) is a warning and never pages" do
    # HealthMonitorService reports a deliberate halt as `execution_stalled:paused`
    # with status :warning. Gating on critical? excludes it -- paging an operator for
    # the silence they asked for would lock the escape hatch.
    paused = {
      status: HealthMonitorService::HealthStatus.new(
        status: :warning,
        code: "#{HealthMonitorService::EXECUTION_STALL_CODE}:paused",
        message: "Nothing is executing ... Halted on purpose: default is paused."
      ),
      queue_stats: { seconds_since_last_finished: 900 },
      worker_stats: { active_workers: 1 }
    }
    watchdog = watchdog_for(paused)
    ErrorReporter.expects(:report_message).never

    5.times { assert_equal :healthy, watchdog.check! }
    assert_equal 0, watchdog.consecutive_stalls
  end

  test "a mere backlog is left to the worker's monitor and does not page here" do
    # A deep-but-alive queue carries a backlog code, not the execution-stall code.
    # SystemHealthMonitorJob (which CAN run when the queue is only busy) pages on it;
    # paging here too would double-page under ordinary saturation.
    backlog = {
      status: HealthMonitorService::HealthStatus.new(
        status: :critical,
        code: "backlog_cross_lane",
        message: "Queue backlog critical: 300 jobs ready across 3 stalled lanes"
      ),
      queue_stats: { seconds_since_last_finished: 5 },
      worker_stats: { active_workers: 2 }
    }
    watchdog = watchdog_for(backlog)
    ErrorReporter.expects(:report_message).never

    5.times { assert_equal :healthy, watchdog.check! }
  end

  test "a failed liveness read pages rather than crashing the thread" do
    # If the web process itself cannot reach the database, that is a different failure
    # domain, but it is still an outage this process can see and nothing else here can.
    exploding = Object.new
    def exploding.system_health
      raise ActiveRecord::ConnectionNotEstablished, "no connection"
    end

    watchdog = QueueLivenessWatchdog.new(health_monitor: exploding)
    Rails.logger.expects(:error).with { |msg| msg.include?("Liveness read failed") }
    ErrorReporter.expects(:report_exception)

    assert_equal :error, watchdog.check!
  end

  # ------------------------------------------------------------------------------
  # The reproduce/fix/verify pair, against the REAL HealthMonitorService and real
  # GoodJob rows: the queue is executing nothing, and the two paths diverge.
  # ------------------------------------------------------------------------------

  test "IN-BAND path is structurally silent: the monitor is a job on the queue that is down" do
    # This is the "before". SystemHealthMonitorJob -- the only thing that pages on the
    # execution-stall condition today -- runs ON the GoodJob queue, on the `pollers`
    # lane. When the queue executes nothing (the #426 shape), it is never executed, so
    # it never pages: it shares the failure domain of the thing it watches. That is the
    # structural gap #427 names, and it is why the outage was silent for ~10 hours.
    assert_equal "pollers", SystemHealthMonitorJob.new.queue_name,
      "the in-band monitor rides the very queue whose outage it would need to report"
    assert SystemHealthMonitorJob < ActiveJob::Base,
      "it is an ActiveJob, so a queue that executes nothing cannot run it"

    # The out-of-band watchdog, by contrast, is a plain object with no queue at all.
    assert_not QueueLivenessWatchdog.respond_to?(:queue_name),
      "the watchdog must not be a job -- that is what lets it run when the queue does not"
  end

  test "OUT-OF-BAND path fires on the same dead-queue scenario, touching no GoodJob job" do
    # This is the "after". Build the exact signature of a worker that cannot claim
    # anything: one job finished 15 minutes ago and nothing since, and no live worker
    # heartbeat (no good_job_processes rows exist in test). HealthMonitorService reads
    # that as the `execution_stalled` critical status.
    GoodJob::Job.insert_all([ {
      queue_name: "default", job_class: "PlaceholderJob",
      created_at: 20.minutes.ago, updated_at: 15.minutes.ago,
      scheduled_at: 20.minutes.ago, performed_at: 16.minutes.ago,
      finished_at: 15.minutes.ago
    } ])

    health = HealthMonitorService.new.system_health
    assert health[:status].critical?, "the scenario must read as critical"
    assert_equal HealthMonitorService::EXECUTION_STALL_CODE, health[:status].code,
      "with no live worker and a stale last-finished, the status is execution_stalled"

    watchdog = QueueLivenessWatchdog.new # real HealthMonitorService
    jobs_before = GoodJob::Job.count

    ErrorReporter.expects(:report_message).once
    Rails.logger.stubs(:error)

    assert_equal :stalled, watchdog.check! # streak 1, silent
    assert_equal :stalled, watchdog.check! # streak 2, pages

    assert_equal jobs_before, GoodJob::Job.count,
      "the watchdog must not enqueue or execute any GoodJob job -- that is the whole point"
  end
end
