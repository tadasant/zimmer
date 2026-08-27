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

  test "a session deleted before the job runs is a no-op, not a failure" do
    session = create_session
    id = session.id
    session.destroy!

    assert_nothing_raised { SessionProvenanceBroadcastJob.perform_now(id) }
  end

  private

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
