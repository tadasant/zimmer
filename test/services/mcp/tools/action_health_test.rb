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
end
