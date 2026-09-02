# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class Mcp::Tools::GetSystemHealthTest < ActiveSupport::TestCase
  setup do
    @tool = Mcp::Tools::GetSystemHealth.new(context: Mcp::Context.new(tool_groups: "health"))
    HealthMonitorService.any_instance.stubs(:full_health_report).returns(
      { overall_status: "healthy", session_health: { total_sessions: 3 } }
    )
  end

  test "renders the health report as a json block" do
    result = @tool.call({})

    assert_includes result, "## System Health Report"
    assert_includes result, "- **Environment:** test"
    assert_includes result, "- **Ruby Version:** #{RUBY_VERSION}"
    assert_includes result, "### Health Details"
    assert_includes result, '"overall_status": "healthy"'
    refute_includes result, "### CLI Status"
  end

  test "include_cli_status appends the cli report" do
    CliStatusService.stubs(:unauthenticated_count).returns(2)
    CliStatusService.stubs(:cached_report).returns({ tools: { claude: { authenticated: false } } })

    result = @tool.call("include_cli_status" => true)

    assert_includes result, "### CLI Status"
    assert_includes result, "- **Unauthenticated CLIs:** 2"
    assert_includes result, '"authenticated": false'
  end

  test "a failing cli report degrades to a note instead of losing the health report" do
    CliStatusService.stubs(:unauthenticated_count).raises(StandardError, "cache unavailable")

    result = @tool.call("include_cli_status" => true)

    assert_includes result, "## System Health Report"
    assert_includes result, "*Could not fetch CLI status: cache unavailable*"
  end

  # Parity with the Slack backlog page. A bare ready count cannot tell a starved
  # queue from a busy one, and this tool is what an agent triaging that page
  # actually has — the GoodJob dashboard needs a browser session on the production
  # host, which an agent session does not have.
  test "names the backlogged queues and job classes when work is waiting" do
    HealthMonitorService.any_instance.stubs(:ready_backlog_breakdown).returns(
      { by_queue: { "agents" => 231, "default" => 18 },
        by_job_class: { "AgentSessionJob" => 231, "SessionTitleJob" => 18 },
        oldest_by_queue: { "agents" => 1500, "default" => 4 },
        head_of_line: { queue: "agents", job_class: "AgentSessionJob", age_seconds: 1500 } }
    )

    result = @tool.call({})

    assert_includes result, "- **Ready backlog by queue:** agents 231, default 18"
    assert_includes result, "- **Ready backlog by job class:** AgentSessionJob 231, SessionTitleJob 18"
  end

  # `oldest_ready_age_seconds` in the JSON below is one number over every queue at
  # once, and it is what the Grafana `GoodJob queue is not draining` rule fires on.
  # An agent triaging that page has to be able to tell one starved lane from a
  # wedged worker, and the maximum alone cannot: `inference` and `maintenance` run
  # two threads against jobs that block for a minute or more, so their head of line
  # is routinely tens of minutes old while everything else turns over in seconds.
  test "names each queue's own head-of-line age, oldest lane first" do
    HealthMonitorService.any_instance.stubs(:ready_backlog_breakdown).returns(
      { by_queue: { "inference" => 26, "maintenance" => 19 },
        by_job_class: { "SessionStatusSummaryJob" => 17, "DeferredCloneCleanupJob" => 15 },
        oldest_by_queue: { "inference" => 1640, "maintenance" => 1290, "pollers" => 4 },
        head_of_line: { queue: "inference", job_class: "SessionStatusSummaryJob", age_seconds: 1640 } }
    )

    result = @tool.call({})

    assert_includes result, "- **Oldest ready by queue:** inference 27m, maintenance 21m, pollers 4s"
    assert_includes result, "- **Head of line:** inference / SessionStatusSummaryJob, waiting 27m",
                    "the agent reader has no route to /jobs, so the page must name the job class too"
  end

  # A breakdown of an empty queue is a line of noise on every healthy call. A
  # breakdown that could not be READ is not — the caller most likely to hit a
  # database that cannot serve these scans is the one triaging a database that is
  # struggling, so that case has to say so rather than go quiet or raise.
  test "says nothing about the backlog when nothing is waiting" do
    result = @tool.call({})

    refute_includes result, "Ready backlog by queue"
    refute_includes result, "Ready backlog by job class"
    refute_includes result, "Oldest ready by queue"
    refute_includes result, "Head of line"
  end

  test "a breakdown that cannot be read is reported, not raised, and keeps the report" do
    HealthMonitorService.any_instance.stubs(:ready_backlog_breakdown)
                        .raises(ActiveRecord::StatementInvalid, "canceling statement due to statement timeout")

    result = @tool.call({})

    assert_includes result, "- **Ready backlog breakdown:** unavailable"
    assert_includes result, '"overall_status": "healthy"'
  end

  # A pending-job count means something completely different when the queues are
  # deliberately halted, so the report says which it is — in both directions, so
  # "no" is distinguishable from "this report doesn't say".
  test "reports queue recovery mode as off when it is off" do
    assert_includes @tool.call({}), "**Queue Recovery Mode:** Off"
  end

  test "leads with queue recovery mode when it is on" do
    AlertService.stubs(:raise_alert).returns(true)
    AppSetting.delete_all
    GoodJob::Setting.delete_all
    QueueRecoveryMode.enter!(reason: "trigger stampede", actor: "test")

    result = @tool.call({})

    assert_includes result, "QUEUE RECOVERY MODE IS ON"
    assert_includes result, "frozen, not backing up"
    assert_includes result, "trigger stampede"
  ensure
    GoodJob::Setting.delete_all
  end
end
