# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class Mcp::Tools::ActionHealthTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tool = Mcp::Tools::ActionHealth.new(context: Mcp::Context.new(tool_groups: "health"))
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
end
