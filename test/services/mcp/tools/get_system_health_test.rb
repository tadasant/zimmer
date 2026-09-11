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

  # The answer to a "Cron schedule stale" page, for an agent with no route to /health:
  # one line always, and each key that is behind with the reason it is behind.
  test "cron freshness is one line when every key is on schedule, and names the keys behind otherwise" do
    healthy = HealthMonitorService::HealthStatus.new(status: :healthy, message: "All 49 judged cron key(s) are enqueuing on schedule")
    HealthMonitorService.any_instance.stubs(:full_health_report).returns(
      { overall_status: "healthy", cron_health: { status: healthy, keys: [ { key: "zombie_reaper", state: :fresh } ] } }
    )
    assert_includes @tool.call({}), "- **Cron freshness:** All 49 judged cron key(s) are enqueuing on schedule"

    stale = HealthMonitorService::HealthStatus.new(status: :critical, message: "Cron schedule stale: 1 key(s) stopped producing jobs (docker_cleanup)")
    HealthMonitorService.any_instance.stubs(:full_health_report).returns(
      { overall_status: "critical", cron_health: { status: stale, keys: [
        { key: "docker_cleanup", state: :stale, reason: "Held by a run on maintenance that started 9h 0m ago" },
        { key: "log_retention", state: :overdue, reason: "Its copy has waited 2h 0m for a worker on maintenance" },
        { key: "zombie_reaper", state: :fresh }
      ] } }
    )
    result = @tool.call({})

    assert_includes result, "- **Cron freshness:** Cron schedule stale: 1 key(s) stopped producing jobs (docker_cleanup)"
    assert_includes result, "  - `docker_cleanup` (stale): Held by a run on maintenance that started 9h 0m ago"
    assert_includes result, "  - `log_retention` (overdue): Its copy has waited 2h 0m for a worker on maintenance"
    refute_includes result, "`zombie_reaper`"
  end

  # A key that stopped overnight and recovered reads `fresh`, so the line above would
  # not carry it — and its own summary line is INFO, which the OTel appender does not
  # ship. This bullet is the only place an agent can read it (tadasant/zimmer#584).
  test "a key that stopped earlier in the window and recovered gets its own line" do
    healthy = HealthMonitorService::HealthStatus.new(
      status: :healthy,
      message: "All 2 judged cron key(s) are enqueuing on schedule. 1 key(s) stopped and recovered " \
               "in the last 24 hours (status_summary_backstop silent 6h 0m to 2026-09-11 02:00 UTC)"
    )
    HealthMonitorService.any_instance.stubs(:full_health_report).returns(
      { overall_status: "healthy", cron_health: { status: healthy, history_window_seconds: 86_400, keys: [
        { key: "status_summary_backstop", state: :fresh, stopped_in_window: true, ticks_in_window: 216,
          longest_gap_seconds: 21_600, gap_ended_at: Time.utc(2026, 9, 11, 2, 0, 0) },
        { key: "zombie_reaper", state: :fresh, stopped_in_window: false, ticks_in_window: 288 }
      ] } }
    )

    result = @tool.call({})

    assert_includes result, "  - `status_summary_backstop` (enqueuing now, but stopped earlier): " \
                            "216 tick(s) in the last 24 hours, longest silence 6h 0m, resumed 2026-09-11 02:00 UTC"
    refute_includes result, "`zombie_reaper`"
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
    ErrorReporter.stubs(:report_message)
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

  # --- the Parameter Store namespace migration -------------------------------
  #
  # The rename reads BOTH namespaces across the move, so a half-done migration
  # and a finished one are indistinguishable from every other angle: nothing
  # raises, nothing is missing. The Connectors page banner tells them apart for a
  # human; an agent session cannot read a web page, so the session assigned "drop
  # the pre-rename read path" either parks in `needs_input` asking a human to read
  # a banner back to it, or proceeds blind. Dropping that read path early turns
  # every affected `${VAR}` into "Missing configuration" in silence, because a
  # miss is not an error.

  test "names the variables still answering from a pre-rename namespace" do
    fake = FakeParameterStore.new
    fake.seed_secret("MOVED_ALREADY", "1")
    fake.seed_secret("STILL_AT_OLD_PATH", "2",
      path: ParameterStore::Namespace.legacy_parameter_path("STILL_AT_OLD_PATH"))
    fake.seed_secret("ALSO_AT_OLD_PATH", "3",
      path: ParameterStore::Namespace.legacy_parameter_path("ALSO_AT_OLD_PATH"))
    stub_chain_with(fake)

    result = @tool.call({})

    assert_includes result, "### Secret Store"
    assert_includes result, "- **Canonical namespace:** `#{ParameterStore::Namespace.static_namespace}`"
    assert_includes result,
      "- **Pre-rename namespaces still read:** `#{ParameterStore::Namespace.legacy_static_namespace}`"
    assert_includes result,
      "- **Names still answering from a pre-rename namespace (2):** ALSO_AT_OLD_PATH, STILL_AT_OLD_PATH",
      "sorted, counted, and only the names the old namespace actually holds"
    refute_includes result, "MOVED_ALREADY"
  end

  # A parameter the resolver REFUSES to serve is still a parameter at the old
  # path, so it counts as remaining — otherwise the section would say the
  # namespace is empty while it still holds one.
  test "counts a pre-rename name the resolver holds back as still remaining" do
    fake = FakeParameterStore.new
    fake.seed_secret("STUCK", "whatever", encoding: "rot13",
      path: ParameterStore::Namespace.legacy_parameter_path("STUCK"))
    stub_chain_with(fake)

    result = @tool.call({})

    assert_includes result, "- **Names still answering from a pre-rename namespace (1):** STUCK"
  end

  test "folds every pre-rename namespace the resolver reads into one list" do
    fake = FakeParameterStore.new
    other = "/zimmer/#{Rails.env}/legacy/static/"
    fake.seed_secret("FROM_MCP", "1", path: ParameterStore::Namespace.legacy_parameter_path("FROM_MCP"))
    fake.seed_secret("FROM_OTHER", "2", path: "#{other}FROM_OTHER")
    namespaces = ParameterStore::Namespace.read_namespaces + [ other ]
    stub_chain_with(fake, namespaces: namespaces)

    result = @tool.call({})

    assert_includes result, "- **Pre-rename namespaces still read:** " \
                            "`#{ParameterStore::Namespace.legacy_static_namespace}`, `#{other}`"
    assert_includes result,
      "- **Names still answering from a pre-rename namespace (2):** FROM_MCP, FROM_OTHER"
  end

  test "says the pre-rename read path can be dropped once nothing answers from it" do
    fake = FakeParameterStore.new
    fake.seed_secret("MOVED_ALREADY", "1")
    fake.seed_secret("ALSO_MOVED", "2")
    stub_chain_with(fake)

    result = @tool.call({})

    assert_includes result,
      "- **Pre-rename namespaces still read:** `#{ParameterStore::Namespace.legacy_static_namespace}`"
    assert_includes result,
      "- **Names still answering from a pre-rename namespace:** none — that read path can be dropped."
  end

  # The load-bearing safety property. This response is read by other agent
  # sessions, so a secret VALUE folded in here would be secret material handed to
  # every caller. Seeded on both sides of the move, in both envelope shapes, and
  # under a name the report does print — so the assertion cannot pass merely
  # because the name is absent.
  test "reports names, never values" do
    fake = FakeParameterStore.new
    fake.seed_secret("CANONICAL_KEY", "sk-live-canonical-secret")
    fake.seed_console_secret("ENCODED_KEY", "sk-live-encoded-secret")
    fake.seed_secret("STILL_AT_OLD_PATH", "sk-live-legacy-secret",
      path: ParameterStore::Namespace.legacy_parameter_path("STILL_AT_OLD_PATH"))
    stub_chain_with(fake)

    result = @tool.call({})

    assert_includes result, "STILL_AT_OLD_PATH", "the name is reported"
    [ "sk-live-canonical-secret", "sk-live-encoded-secret", "sk-live-legacy-secret" ].each do |value|
      refute_includes result, value, "a secret value must never reach an MCP response"
      refute_includes result, Base64.urlsafe_encode64(value, padding: false),
        "nor an encoded form of one"
    end
  end

  # Reporting a namespace nobody read as an empty one is the single wrong answer
  # here: it tells the follow-up PR to go ahead. The configuration lines above it
  # are true whether or not Google ever answered, so only that one line degrades.
  test "a namespace with no snapshot says unknown rather than reading as finished" do
    fake = FakeParameterStore.new
    fake.fail_with!(503)
    stub_chain_with(fake, warm: false)

    result = @tool.call({})

    assert_includes result, "- **Canonical namespace:** `#{ParameterStore::Namespace.static_namespace}`"
    assert_includes result, "- **Names still answering from a pre-rename namespace:** unknown — this " \
                            "process holds no snapshot of the store yet."
    refute_includes result, "that read path can be dropped"
    assert_includes result, '"overall_status": "healthy"', "and the health report survives"
  end

  # Reporting, not resolving: an agent asking for a health report must not be the
  # thing that provokes a round trip to Google, least of all while triaging a
  # store that is not answering.
  test "reads what the process already holds rather than calling the store" do
    fake = FakeParameterStore.new
    fake.seed_secret("STILL_AT_OLD_PATH", "1",
      path: ParameterStore::Namespace.legacy_parameter_path("STILL_AT_OLD_PATH"))
    stub_chain_with(fake)
    before = fake.requests.size

    3.times { @tool.call({}) }

    assert_equal before, fake.requests.size
  end

  test "reports the migration as complete once the pre-rename read path is gone" do
    fake = FakeParameterStore.new
    fake.seed_secret("MOVED_ALREADY", "1")
    stub_chain_with(fake, namespaces: [ ParameterStore::Namespace.static_namespace ])

    result = @tool.call({})

    assert_includes result,
      "- **Pre-rename namespaces still read:** none — the namespace migration is complete."
  end

  # An explicit line rather than an absent section, so a caller asking "is the
  # migration done?" can tell "there is no store" from "this report doesn't say".
  test "says which store is in use when no Parameter Store is configured" do
    SecretProviders.stubs(:chain).returns(SecretProviders::Chain.new([ SecretProviders::RailsCredentials.new ]))
    SecretProviders.stubs(:parameter_store_configuration)
                   .returns(ParameterStore::Resolver::Configuration.new(client: nil, reason: "no key is set"))

    result = @tool.call({})

    assert_includes result, "### Secret Store"
    assert_includes result, "the Google Parameter Store is not configured (no key is set)"
    refute_includes result, "Pre-rename namespaces still read"
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

  # `warm:` reproduces what every real MCP request already did before this tool
  # runs: Mcp::Context resolves ${VAR}s for the self-session injector, which is a
  # read through this same chain, so the snapshot is held by the time the health
  # report is rendered. The section deliberately does not refresh it itself.
  def stub_chain_with(fake, namespaces: ParameterStore::Namespace.read_namespaces, warm: true)
    chain = SecretProviders::Chain.new(
      [ fake.provider(namespaces: namespaces), SecretProviders::RailsCredentials.new ]
    )
    chain.get("ZIMMER_APP_URL") if warm
    SecretProviders.stubs(:chain).returns(chain)
  end
end
