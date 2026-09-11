# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class Mcp::Tools::ActionHealthTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  # The cooldown fails closed under the test environment's :null_store — a
  # limiter that cannot enforce anything refuses rather than waves things
  # through — so a real store is what lets the happy paths below run at all.
  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @tool = tool_for("key_one")
  end

  teardown do
    Rails.cache = @original_cache
  end

  def tool_for(api_key)
    Mcp::Tools::ActionHealth.new(
      context: Mcp::Context.new(
        tool_groups: "health",
        caller_fingerprint: HealthActionCooldown.fingerprint(api_key)
      )
    )
  end

  test "cleanup_processes reports terminated pids" do
    HealthMonitorService.any_instance.expects(:cleanup_orphaned_processes)
      .returns({ terminated: [ 42 ], failed: [], already_dead: [] })

    result = @tool.call("action" => "cleanup_processes")

    assert_includes result, "## Processes Cleaned Up"
    assert_includes result, '"terminated": ['
    assert_includes result, "42"
  end

  test "retry_sessions passes the requested session ids through" do
    HealthMonitorService.any_instance.expects(:retry_failed_sessions)
      .with(session_ids: [ 1, 2 ])
      .returns({ retried: [ 1, 2 ], failed: [], skipped: [] })

    result = @tool.call("action" => "retry_sessions", "session_ids" => [ 1, 2 ])

    assert_includes result, "## Sessions Retried"
    assert_includes result, '"retried": ['
  end

  test "retry_sessions without ids retries the recent failures" do
    HealthMonitorService.any_instance.expects(:retry_failed_sessions)
      .with(session_ids: nil)
      .returns({ retried: [], failed: [], skipped: [] })

    assert_includes @tool.call("action" => "retry_sessions"), "## Sessions Retried"
  end

  test "archive_old defaults to seven days" do
    HealthMonitorService.any_instance.expects(:archive_old_sessions)
      .with(older_than: 7.days)
      .returns({ archived: [ 3 ], failed: [] })

    result = @tool.call("action" => "archive_old")

    assert_includes result, "## Old Sessions Archived"
    assert_includes result, '"archived": ['
  end

  test "archive_old clamps days to the supported range" do
    HealthMonitorService.any_instance.expects(:archive_old_sessions)
      .with(older_than: 365.days)
      .returns({ archived: [], failed: [] })

    assert_includes @tool.call("action" => "archive_old", "days" => 5_000), "## Old Sessions Archived"
  end

  test "cli_refresh enqueues a cli status refresh" do
    assert_enqueued_with(job: CliStatusRefreshJob) do
      assert_includes @tool.call("action" => "cli_refresh"), "## CLI Refresh Queued"
    end
  end

  test "cli_clear_cache enqueues a cache clear with reinstall" do
    assert_enqueued_with(job: CacheClearJob, args: [ { reinstall: true } ]) do
      assert_includes @tool.call("action" => "cli_clear_cache"), "## CLI Cache Clear Queued"
    end
  end

  test "backfill_token_usage queues a sweep of the whole corpus" do
    assert_enqueued_with(job: TokenUsageBackfillJob) do
      output = @tool.call("action" => "backfill_token_usage")
      assert_includes output, "## Token Usage Backfill Queued"
    end

    assert_equal 1, TokenUsageBackfill.count
    assert_equal "manual", TokenUsageBackfill.latest.trigger
  end

  test "backfill_token_usage is idempotent: a second call joins the run in flight" do
    @tool.call("action" => "backfill_token_usage")
    @tool.call("action" => "backfill_token_usage")

    assert_equal 1, TokenUsageBackfill.count, "asking twice must not start two sweeps"
  end

  test "unknown action raises" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "reboot") }

    assert_includes error.message, 'Unknown action "reboot"'
  end

  test "missing action raises" do
    error = assert_raises(Mcp::ToolError) { @tool.call({}) }

    assert_equal "Missing required parameter: action", error.message
  end

  # === Cooldown ===

  test "a second call within the cooldown is refused" do
    HealthMonitorService.any_instance.stubs(:cleanup_orphaned_processes)
      .returns({ terminated: [], failed: [], already_dead: [] })

    @tool.call("action" => "cleanup_processes")
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "cleanup_processes") }

    assert_includes error.message, "Rate limited"
  end

  test "the cooldown is scoped per caller" do
    HealthMonitorService.any_instance.stubs(:cleanup_orphaned_processes)
      .returns({ terminated: [], failed: [], already_dead: [] })

    @tool.call("action" => "cleanup_processes")

    # A different API key is a different bucket, so it is not locked out by the
    # first caller's cooldown.
    assert_includes tool_for("key_two").call("action" => "cleanup_processes"), "## Processes Cleaned Up"
  end

  # The REST controller and this tool share HealthActionCooldown, so a caller
  # cannot get two runs out of one cooldown by alternating surfaces.
  test "the cooldown is shared with the REST surface for the same caller" do
    HealthActionCooldown.new(HealthActionCooldown.fingerprint("key_one")).record("cleanup_processes")

    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "cleanup_processes") }

    assert_includes error.message, "Rate limited"
  end

  test "the CLI actions are not rate limited" do
    assert_includes @tool.call("action" => "cli_refresh"), "## CLI Refresh Queued"
    assert_includes @tool.call("action" => "cli_refresh"), "## CLI Refresh Queued"
  end

  test "a null cache store refuses the destructive actions rather than running them unthrottled" do
    Rails.cache = ActiveSupport::Cache::NullStore.new
    HealthMonitorService.any_instance.expects(:cleanup_orphaned_processes).never

    error = assert_raises(Mcp::ToolError) { tool_for("key_one").call("action" => "cleanup_processes") }

    assert_includes error.message, "Rate limiting unavailable"
  end

  test "a null cache store still allows the CLI actions" do
    Rails.cache = ActiveSupport::Cache::NullStore.new

    assert_includes tool_for("key_one").call("action" => "cli_refresh"), "## CLI Refresh Queued"
  end
  # === Queue recovery mode ===

  test "enter_queue_recovery_mode halts the demand-side queues and says agents is still live" do
    AlertService.stubs(:raise_alert).returns(true)
    GoodJob::Setting.delete_all
    AppSetting.delete_all

    result = @tool.call(
      "action" => "enter_queue_recovery_mode",
      "reason" => "trigger stampede",
      "ttl_minutes" => 30
    )

    assert_includes result, "## Queue Recovery Mode ON"
    assert_includes result, "pollers"
    # The caller is usually the investigating session; it has to be told that its
    # own queue keeps running, and that jobs are frozen rather than dropped.
    assert_includes result, "agent sessions start and run normally"
    assert_includes result, "frozen, not discarded"
    assert_equal QueueRecoveryMode::HALTED_QUEUES.sort, GoodJob.paused(:queues).sort
    refute_includes GoodJob.paused(:queues), "agents"
  ensure
    GoodJob::Setting.delete_all
  end

  test "exit_queue_recovery_mode resumes processing" do
    AlertService.stubs(:raise_alert).returns(true)
    GoodJob::Setting.delete_all
    AppSetting.delete_all
    @tool.call("action" => "enter_queue_recovery_mode", "reason" => "x")

    result = @tool.call("action" => "exit_queue_recovery_mode")

    assert_includes result, "## Queue Recovery Mode OFF"
    assert_empty GoodJob.paused(:queues)
  ensure
    GoodJob::Setting.delete_all
  end

  # The escape hatch, and above all the way back out of it, must not be gated by a
  # throttle that fails closed exactly when the cache is struggling.
  test "the queue recovery mode actions are not rate limited" do
    AlertService.stubs(:raise_alert).returns(true)
    GoodJob::Setting.delete_all
    AppSetting.delete_all
    HealthActionCooldown.new(HealthActionCooldown.fingerprint("key_one")).record("cleanup_processes")

    assert_includes @tool.call("action" => "enter_queue_recovery_mode"), "## Queue Recovery Mode ON"
    assert_includes @tool.call("action" => "exit_queue_recovery_mode"), "## Queue Recovery Mode OFF"
  ensure
    GoodJob::Setting.delete_all
  end

  test "enter_queue_recovery_mode raises rather than reporting a halt GoodJob would ignore" do
    QueueRecoveryMode.stubs(:enabled?).returns(false)

    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "enter_queue_recovery_mode") }

    assert_includes error.message, "enable_pauses"
  end

  # The text an investigating session reads while the queues are halted is the
  # thing that tells it the third lever exists at all. Before #335 it named the
  # GoodJob dashboard, which is the app the session cannot drive.
  test "enter_queue_recovery_mode points at the job maintenance actions, not at /jobs" do
    AlertService.stubs(:raise_alert).returns(true)
    GoodJob::Setting.delete_all
    AppSetting.delete_all

    result = @tool.call("action" => "enter_queue_recovery_mode")

    assert_includes result, "discard_queued_jobs"
    refute_includes result, "GoodJob dashboard"
  ensure
    GoodJob::Setting.delete_all
  end

  # === Queued job maintenance ===

  def enqueue_good_job(job_class: "CanaryJob", queue_name: "pollers", **attrs)
    id = SecureRandom.uuid

    GoodJob::Job.create!(
      id: id, active_job_id: id, job_class: job_class, queue_name: queue_name,
      priority: 0, scheduled_at: Time.current,
      serialized_params: {
        "job_class" => job_class, "job_id" => id, "queue_name" => queue_name,
        "priority" => 0, "arguments" => [], "executions" => 0, "locale" => "en"
      },
      **attrs
    )
  end

  test "preview_queued_jobs counts the eligible rows and names the expected_count to pass back" do
    GoodJob::Job.delete_all
    2.times { enqueue_good_job }

    result = @tool.call("action" => "preview_queued_jobs", "queue_name" => "pollers")

    assert_includes result, "## Queued Jobs — 2 eligible"
    assert_includes result, "`CanaryJob` 2"
    assert_includes result, "expected_count: 2"
    assert_equal 0, GoodJob::Job.where.not(finished_at: nil).count
  ensure
    GoodJob::Job.delete_all
  end

  test "discard_queued_jobs reports what it discarded, by class" do
    AlertService.stubs(:raise_alert).returns(true)
    GoodJob::Job.delete_all
    2.times { enqueue_good_job }
    enqueue_good_job(job_class: "HeartbeatSweepJob")

    result = @tool.call(
      "action" => "discard_queued_jobs", "queue_name" => "pollers", "expected_count" => 3
    )

    assert_includes result, "## Queued Jobs Discarded — 3 rows"
    assert_includes result, "`CanaryJob` 2"
    assert_includes result, "`HeartbeatSweepJob` 1"
    assert_includes result, "not recoverable"
    assert_equal 3, GoodJob::Job.where.not(finished_at: nil).count
  ensure
    GoodJob::Job.delete_all
  end

  test "a count mismatch is a tool error the model can recover from, and discards nothing" do
    GoodJob::Job.delete_all
    3.times { enqueue_good_job }

    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "discard_queued_jobs", "queue_name" => "pollers", "expected_count" => 1)
    end

    assert_includes error.message, "Count confirmation failed"
    assert_includes error.message, "expected_count=3"
    assert_equal 0, GoodJob::Job.where.not(finished_at: nil).count
  ensure
    GoodJob::Job.delete_all
  end

  test "the agents queue is refused through the tool surface too" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "discard_queued_jobs", "queue_name" => "agents", "expected_count" => 0)
    end

    assert_includes error.message, "protected"
  end

  test "reschedule_queued_jobs moves the work instead of ending it" do
    AlertService.stubs(:raise_alert).returns(true)
    GoodJob::Job.delete_all
    job = enqueue_good_job

    result = @tool.call(
      "action" => "reschedule_queued_jobs", "queue_name" => "pollers",
      "expected_count" => 1, "delay_minutes" => 30
    )

    assert_includes result, "## Queued Jobs Rescheduled — 1 row"
    assert_includes result, "Nothing was destroyed"
    job.reload
    assert_nil job.finished_at
    assert_in_delta 30.minutes.from_now.to_i, job.scheduled_at.to_i, 5
  ensure
    GoodJob::Job.delete_all
  end

  # Same reasoning as the recovery mode exemption, plus their own: a mistaken
  # repeat is refused by the count confirmation, not by a timer that fails closed
  # when the cache is down.
  test "the queued job actions are not rate limited" do
    AlertService.stubs(:raise_alert).returns(true)
    GoodJob::Job.delete_all
    HealthActionCooldown.new(HealthActionCooldown.fingerprint("key_one")).record("cleanup_processes")

    assert_includes @tool.call("action" => "preview_queued_jobs", "queue_name" => "pollers"), "## Queued Jobs"
    assert_includes @tool.call("action" => "discard_queued_jobs", "queue_name" => "pollers", "expected_count" => 0),
      "## Queued Jobs Discarded"
  ensure
    GoodJob::Job.delete_all
  end

  test "the three actions are advertised in the schema and the description" do
    schema = Mcp::Tools::ActionHealth.input_schema.to_h
    actions = schema.dig(:properties, :action, :enum) || schema.dig("properties", "action", "enum")

    assert_includes actions, "preview_queued_jobs"
    assert_includes actions, "discard_queued_jobs"
    assert_includes actions, "reschedule_queued_jobs"

    description = Mcp::Tools::ActionHealth.rendered_description
    assert_includes description, "NOT RECOVERABLE"
    assert_includes description, "expected_count"
  end
end
