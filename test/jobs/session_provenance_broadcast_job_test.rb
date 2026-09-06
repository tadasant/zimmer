# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The provenance fan-out is quadratic in the size of the lineage, and it used to
# run inline in the request that spawned the session. That is the create-path
# latency behind #577 — a create that only queues work has no business rendering
# 150 panels before it answers. These tests hold the line on both halves: the
# request enqueues instead of rendering, and the job still produces the repaint.
class SessionProvenanceBroadcastJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def create_session(**overrides)
    Session.create!({
      git_root: "https://github.com/test/repo.git",
      prompt: "work",
      title: "Session"
    }.merge(overrides))
  end

  test "spawning a child enqueues the fan-out instead of rendering it in the caller's request" do
    parent = create_session(title: "Parent")

    Session.any_instance.expects(:broadcast_provenance_change_to_hierarchy).never

    assert_enqueued_with(job: SessionProvenanceBroadcastJob) do
      create_session(title: "Child", parent_session_id: parent.id)
    end
  end

  test "a parentless session enqueues nothing — there is no hierarchy to repaint" do
    assert_no_enqueued_jobs(only: SessionProvenanceBroadcastJob) do
      create_session(title: "Solitary")
    end
  end

  test "recording a human message enqueues the fan-out rather than running it inline" do
    session = create_session

    Session.any_instance.expects(:broadcast_provenance_change_to_hierarchy).never

    assert_enqueued_with(job: SessionProvenanceBroadcastJob, args: [ session.id ]) do
      session.human_messages.create!(
        author: "tadasant",
        channel: HumanMessage::WEB_UI,
        content: "ship it",
        occurred_at: Time.current
      )
    end
  end

  test "an uncle edge enqueues the fan-out" do
    junior = create_session(title: "Junior")
    senior = create_session(title: "Senior")

    assert_enqueued_with(job: SessionProvenanceBroadcastJob, args: [ junior.id ]) do
      SessionUncleLink.create!(session: junior, uncle_session: senior)
    end
  end

  test "the job broadcasts the refreshed panel to every session in the lineage" do
    parent = create_session(title: "Parent")
    child = create_session(title: "Spawned child", parent_session_id: parent.id)

    broadcasts = []
    Turbo::StreamsChannel.stubs(:broadcast_replace_to).with do |stream, **options|
      broadcasts << [ stream, options ]
      true
    end

    SessionProvenanceBroadcastJob.perform_now(child.id)

    targets = broadcasts.map { |_stream, options| options[:target] }
    assert_includes targets, "session_#{parent.id}_provenance"
    assert_includes targets, "session_#{child.id}_provenance"
  end

  # The measurement behind the change, run in CI so the numbers are observed
  # rather than asserted from memory. It builds a lineage, then compares what the
  # create itself costs against what the fan-out costs — the fan-out being exactly
  # the work that used to happen inside that create.
  test "the create sheds the fan-out cost that used to be inside it" do
    router = create_session(title: "Router")
    30.times { |i| create_session(title: "Child #{i}", parent_session_id: router.id) }

    child = nil
    create_queries, create_ms = measure { child = create_session(title: "Newest", parent_session_id: router.id) }
    fanout_queries, fanout_ms = measure { SessionProvenanceBroadcastJob.perform_now(child.id) }

    puts "[#577 create-path measurement, lineage of #{router.reload.child_sessions.count + 1}] " \
         "create: #{create_queries} queries / #{create_ms.round(1)}ms — " \
         "provenance fan-out (formerly inline in that create): #{fanout_queries} queries / #{fanout_ms.round(1)}ms"

    assert_operator fanout_queries, :>, create_queries * 5,
                    "the fan-out should dominate the create it was removed from " \
                    "(create #{create_queries}, fan-out #{fanout_queries})"
  end

  # after_create_commit raises to the caller, and the caller is the HTTP request
  # that just created the session. A failed enqueue must not answer a committed
  # create with a 500 — that is the #577 shape one layer along.
  test "a failing enqueue does not take the create down with it" do
    parent = create_session(title: "Parent")
    SessionProvenanceBroadcastJob.stubs(:perform_later).raises(StandardError, "queue is down")

    child = nil
    assert_nothing_raised do
      child = create_session(title: "Child", parent_session_id: parent.id)
    end
    assert child.persisted?
  end

  test "a session deleted before the job runs is a no-op, not a failure" do
    session = create_session
    id = session.id
    session.destroy!

    assert_nothing_raised { SessionProvenanceBroadcastJob.perform_now(id) }
  end

  # The fan-out is quadratic in the lineage, so what it costs PER ROW is what
  # decides whether it finishes in seconds or holds a lane for a quarter of an
  # hour. `sessions.transcript` is a whole agent transcript — megabytes on a
  # session that ran for hours — and a bare `Session.where(…)` in the walk
  # detoasted one per row, per viewer, to read a title off it: a 47-session
  # lineage shipped 2.5 GB nobody looked at, wedged both `default` threads for
  # 17m, and starved every other lane behind a saturated database
  # (zimmer#1063).
  #
  # Asserted against the SQL rather than against a duration, because a timing
  # threshold on a shared CI box is a flake and this is a categorical claim: the
  # fan-out must never ask for that column, however the projection is spelled. The
  # star form is kept in the check for the case where some other model's loader
  # drags it in; for Session itself ActiveRecord has enumerated the columns since
  # `execution_provider` went into `ignored_columns` (#172), so naming the transcript
  # column is what actually catches a whole-row read today.
  test "the fan-out never asks Postgres for a session's transcript" do
    router = create_session(title: "Router")
    10.times { |i| create_session(title: "Child #{i}", parent_session_id: router.id) }
    child = create_session(title: "Newest", parent_session_id: router.id)

    statements = session_selects_during { SessionProvenanceBroadcastJob.perform_now(child.id) }
    offenders = statements.select { |sql| sql.match?(/SELECT\s+"sessions"\.\*/) || sql.include?('"sessions"."transcript"') }

    # A negative assertion alone would pass on a job that queried nothing at all —
    # a nil seed, an early return, a refactor that no-ops the fan-out — and the
    # guard would stop guarding silently. Establish it ran first.
    assert statements.any? { |sql| sql.include?('"sessions"."title"') },
           "the fan-out issued no projected session query, so the assertion below was never exercised"

    assert_empty offenders,
                 "the provenance fan-out loaded whole session rows — each one detoasts a " \
                 "multi-megabyte transcript to read a title. Load through " \
                 "SessionHierarchy.graph_scope instead.\n#{offenders.first(3).join("\n")}"
  end

  # The other half of the same claim, from the other end: the projection has to
  # carry every attribute the render reads, and THIS is where that gets checked,
  # because at runtime nothing checks it.
  #
  # A column missing from SessionHierarchy::COLUMNS raises
  # ActiveModel::MissingAttributeError — a StandardError — and the render that
  # raises it runs inside the block BroadcastService#broadcast_with_retry wraps in
  # a bare `rescue`. So in production the symptom is not an exception anybody
  # sees: the panel quietly stops repainting, and five swallowed failures open
  # that service's circuit breaker and pause live updates app-wide.
  #
  # So this renders the real partial, through the same SessionsController.render
  # the fan-out calls, off a record loaded through the projection. That reaches
  # what reading Struct fields does not: `human_message_record`,
  # SessionHumanMessages#entries, and every attribute the ERB touches.
  test "the projection carries every attribute the rendered panel reads" do
    # A git_root the catalog actually carries, which is what makes this cover
    # `subdirectory`. AgentRootsConfig.find_for_session matches on
    # `ar.url == git_root && ar.subdirectory.to_s == subdirectory.to_s`, and `&&`
    # short-circuits: against a git_root no root matches, `subdirectory` is never
    # read and dropping it from COLUMNS would leave this green while production
    # — where the URL does match — raised into BroadcastService's rescue.
    in_catalog = { git_root: AgentRootsConfig.all.first.url }
    router = create_session(title: "Router", genesis: "web_ui", scheduling_class: "priority", **in_catalog)
    child = create_session(title: "Child", parent_session_id: router.id, **in_catalog)
    SessionUncleLink.create!(session: child, uncle_session: create_session(title: "Senior", **in_catalog))
    child.human_messages.create!(
      author: "tadasant", channel: HumanMessage::WEB_UI, content: "ship it", occurred_at: Time.current
    )

    # Built from the child, so the walk exercises both directions: up to the
    # router and the uncle, then back down. A hierarchy built from the router
    # would never reach the uncle, and `uncle_ids_for` drops an edge whose senior
    # is outside the graph.
    projected = SessionHierarchy.graph_scope.find_by(id: child.id)

    # Rendered outside assert_nothing_raised, which takes no message: an
    # ActiveModel::MissingAttributeError here IS the failure, and letting it
    # surface as the error names the attribute that is missing.
    html = SessionsController.render(partial: "sessions/session_hierarchy", locals: { agent_session: projected })

    # Rendered, not merely non-raising: an empty or degraded panel would satisfy
    # a "did not raise" check on its own.
    assert_includes html, "Session hierarchy"
    assert_includes html, "Router"
    assert_includes html, "also senior"
    assert_includes html, "ship it"
    # Every agent-root pill resolved to a real root rather than falling back to
    # Node#agent_root_label's em dash — which is what proves `metadata`,
    # `git_root` and `subdirectory` were all readable off the projection. Read
    # out of the pill specifically, since the panel's explanatory prose is itself
    # full of em dashes.
    pills = html.scan(%r{title="Agent root">\s*(.*?)\s*</span>}m).flatten
    assert_equal [ AgentRootsConfig.all.first.name ], pills.uniq
  end

  private

  # Every non-schema statement against `sessions` issued while the block runs.
  def session_selects_during
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_n, _s, _f, _i, payload|
      next if [ "SCHEMA", "TRANSACTION" ].include?(payload[:name])
      statements << payload[:sql] if payload[:sql].include?('FROM "sessions"')
    end
    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  # @return [Array(Integer, Float)] statements issued, and wall-clock ms
  def measure
    statements = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_n, _s, _f, _i, payload|
      statements += 1 unless [ "SCHEMA", "TRANSACTION" ].include?(payload[:name])
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
    [ statements, elapsed ]
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end
