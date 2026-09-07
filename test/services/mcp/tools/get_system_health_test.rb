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
    stub_queue_stats(
      ready_count_by_queue: { "agents" => 231, "default" => 18 },
      ready_count_by_job_class: { "AgentSessionJob" => 231, "SessionTitleJob" => 18 },
      oldest_ready_age_seconds_by_queue: { "agents" => 1500, "default" => 4 },
      head_of_line: { queue: "agents", job_class: "AgentSessionJob", age_seconds: 1500 }
    )

    result = @tool.call({})

    assert_includes result, "- **Ready backlog by queue:** agents 231, default 18"
    assert_includes result, "- **Ready backlog by job class:** AgentSessionJob 231, SessionTitleJob 18"
  end

  # Every line of this section is folded out of the report the tool has already
  # built. A second read of `good_jobs` for the prose would be three more scans of
  # a table that is largest during the backlog this tool is called to explain, and
  # its answers could disagree with the JSON printed beneath them.
  test "the backlog section costs no query of its own beyond the health report" do
    stub_queue_stats(
      ready_count_by_queue: { "agents" => 231 },
      ready_count_by_job_class: { "AgentSessionJob" => 231 },
      oldest_ready_age_seconds_by_queue: { "agents" => 1500 },
      head_of_line: { queue: "agents", job_class: "AgentSessionJob", age_seconds: 1500 }
    )
    HealthMonitorService.any_instance.expects(:queue_statistics).never

    good_job_queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      good_job_queries << payload[:sql] if payload[:sql].to_s.include?("good_jobs")
    end
    begin
      @tool.call({})
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert_empty good_job_queries, "the breakdown must come off the report already in hand"
  end

  # `oldest_ready_age_seconds` in the JSON below is one number over every queue at
  # once, and it is what the Grafana `GoodJob queue is not draining` rule fires on.
  # An agent triaging that page has to be able to tell one starved lane from a
  # wedged worker, and the maximum alone cannot: `inference` and `maintenance` run
  # two threads against jobs that block for a minute or more, so their head of line
  # is routinely tens of minutes old while everything else turns over in seconds.
  test "names each queue's own head-of-line age, oldest lane first" do
    stub_queue_stats(
      ready_count_by_queue: { "inference" => 26, "maintenance" => 19 },
      ready_count_by_job_class: { "SessionStatusSummaryJob" => 17, "DeferredCloneCleanupJob" => 15 },
      oldest_ready_age_seconds_by_queue: { "inference" => 1640, "maintenance" => 1290, "pollers" => 4 },
      head_of_line: { queue: "inference", job_class: "SessionStatusSummaryJob", age_seconds: 1640 }
    )

    result = @tool.call({})

    assert_includes result, "- **Oldest ready by queue:** inference 27m, maintenance 21m, pollers 4s"
    assert_includes result, "- **Head of line:** inference / SessionStatusSummaryJob, waiting 27m",
                    "the agent reader has no route to /jobs, so the page must name the job class too"
  end

  # The claimed side of the same picture. An agent that can see a lane's ready
  # depth but not what the worker is HOLDING there cannot tell a wedge — full pool,
  # old executions — from a lane the worker has stopped polling, and the two want
  # opposite responses. Neither could be read off any surface on 2026-09-04.
  test "names what the worker is holding per lane, against that lane's thread count" do
    stub_queue_stats(
      claimed_count_by_queue: { "agents" => 8, "inference" => 2, "default" => 2 },
      claimed_count_by_job_class: { "AgentSessionJob" => 8, "SessionStatusSummaryJob" => 4 },
      oldest_claimed_age_seconds_by_queue: { "inference" => 4620, "default" => 3660, "agents" => 90 },
      youngest_claimed_age_seconds_by_queue: { "inference" => 4560, "default" => 3600, "agents" => 12 }
    )

    result = @tool.call({})

    assert_includes result, "- **In flight by queue:** agents 8, inference 2, default 2 " \
                            "(threads: agents 12, pollers 3, triggers 2, auth 2, inference 2, maintenance 2, default 2)",
                    "a hold is only readable beside the pool it is filling"
    assert_includes result, "- **In flight by job class:** AgentSessionJob 8, SessionStatusSummaryJob 4",
                    "which class is not FINISHING is a different answer from which class is waiting"
    assert_includes result, "- **Oldest execution by queue:** inference 1h 17m, default 1h 1m, agents 1m"
    assert_includes result, "- **Youngest execution by queue:** inference 1h 16m, default 1h 0m, agents 12s",
                    "an old oldest beside a fresh youngest is one slow job, not a wedge"
  end

  # The three shapes that look identical in the aggregate counts, told apart from
  # the keys this tool returns. This is the triage the 2026-08-14 episode could not
  # complete: `ready` climbing while `claimed` sat flat is compatible with all
  # three, and only the breakdown separates them.
  test "the response separates one class flooding from one lane starving" do
    stub_queue_stats(
      ready_count: 139,
      ready_count_by_queue: { "inference" => 131, "agents" => 8 },
      ready_count_by_job_class: { "SessionStatusSummaryJob" => 130, "AgentSessionJob" => 9 },
      oldest_ready_age_seconds_by_queue: { "inference" => 3600, "agents" => 12 },
      claimed_count_by_queue: { "inference" => 2, "agents" => 11 },
      claimed_count_by_job_class: { "AgentSessionJob" => 11, "SessionStatusSummaryJob" => 2 },
      oldest_claimed_age_seconds_by_queue: { "inference" => 8 },
      youngest_claimed_age_seconds_by_queue: { "inference" => 2 }
    )

    result = @tool.call({})

    assert_includes result, "- **Ready backlog by queue:** inference 131, agents 8",
                    "one lane holds the depth"
    assert_includes result, "- **Ready backlog by job class:** SessionStatusSummaryJob 130, AgentSessionJob 9",
                    "and one class is what it is made of — a flood, not a stalled worker"
    assert_includes result, "- **Oldest execution by queue:** inference 8s",
                    "that lane IS claiming work, so the worker has not stopped polling it"
  end

  test "says nothing about the in-flight population when the worker is holding nothing" do
    result = @tool.call({})

    refute_includes result, "In flight by queue"
    refute_includes result, "Oldest execution by queue"
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

  # A report with no `system_health` section AT ALL — the shape a degraded or
  # partially-built report has. This is what the `|| {}` guards in
  # `ready_backlog_lines` and `in_flight_lines` are for, and the only test that
  # reaches them: the empty-queue case below still hands them a fully populated
  # `queue_stats` whose breakdowns happen to be empty, which is a different shape.
  # Neither may raise on the way to the JSON the caller actually asked for.
  test "a report carrying no system_health section still renders" do
    HealthMonitorService.any_instance.stubs(:full_health_report).returns({ overall_status: "healthy" })

    result = @tool.call({})

    refute_includes result, "Ready backlog by queue"
    refute_includes result, "In flight by queue"
    assert_includes result, '"overall_status": "healthy"'
  end

  # The other degraded shape: `queue_stats` is present but a single breakdown key
  # is missing from it. `format_breakdown` answers `unavailable` rather than
  # guessing — a key that never arrived and a queue that read as empty are
  # different facts, and `none` is the word for the second one.
  test "a breakdown key missing from the report reads as unavailable, not as empty" do
    stub_queue_stats(
      ready_count_by_queue: { "agents" => 12 },
      oldest_ready_age_seconds_by_queue: { "agents" => 300 }
    )

    result = @tool.call({})

    assert_includes result, "- **Ready backlog by queue:** agents 12"
    assert_includes result, "- **Ready backlog by job class:** unavailable"
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

  private

  # A health report carrying the queue statistics under test. Every backlog line
  # this tool renders is folded out of `queue_stats`, so a stub of that section is
  # the whole input — there is no second query to intercept.
  def stub_queue_stats(**queue_stats)
    HealthMonitorService.any_instance.stubs(:full_health_report).returns(
      { overall_status: "healthy", session_health: { total_sessions: 3 },
        system_health: { queue_stats: queue_stats } }
    )
  end
end
