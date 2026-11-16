# frozen_string_literal: true

require "test_helper"

class CycleTimes::AnalyzerTest < ActiveSupport::TestCase
  include CycleTimeFixtures

  T0 = Time.utc(2026, 11, 10, 12, 0, 0)

  # A router spawned by a human prompt, watching two children: one that runs the
  # tests and sleeps on CI, one that spends its turn on network calls. All three
  # archive themselves.
  def build_hierarchy(router_archive: "session #ROOT via the self-session MCP server")
    root = build_cycle_time_session(
      created_at: T0, title: "Router",
      script: [
        [ :state, T0 + 5, "Turn started on a worker" ],
        [ :user, T0 + 8, "Fix the flaky test" ],
        [ :tool, T0 + 20, T0 + 21, "mcp__zimmer__start_session", { "agent_root" => "zimmer" } ],
        [ :tool, T0 + 30, T0 + 31, "mcp__zimmer-self-session__wake_me_up_when_session_changes_state", { "session_ids" => [ 2 ] } ],
        [ :say, T0 + 40, "Waiting on the child." ],
        [ :state, T0 + 42, "Session paused, waiting for input" ],
        [ :state, T0 + 43, "Session sleeping, waiting for scheduled wake-up" ],
        [ :state, T0 + 1800, "Session resumed — its turn is queued for a worker" ],
        [ :state, T0 + 1810, "Turn started on a worker" ],
        [ :user, T0 + 1812, "Your child changed state" ],
        [ :say, T0 + 1830, "All done." ],
        [ :state, T0 + 1832, "Session paused, waiting for input" ]
      ]
    )
    root.update_columns(metadata: { "agent_root_key" => "zimmer-orchestrator" })

    worker = build_cycle_time_session(
      created_at: T0 + 21, title: "Worker", parent: root,
      script: [
        [ :state, T0 + 60, "Turn started on a worker" ],
        [ :user, T0 + 70, "Fix it" ],
        [ :tool, T0 + 90, T0 + 390, "Bash", { "command" => "bin/rails test test/models" } ],
        [ :tool, T0 + 400, T0 + 410, "Bash", { "command" => "git push -u origin fix" } ],
        [ :tool, T0 + 420, T0 + 421, "mcp__zimmer-self-session__wake_me_up_later", { "prompt" => "CI wake 1 on https://github.com/x/y/pull/1." } ],
        [ :state, T0 + 430, "Session paused, waiting for input" ],
        [ :state, T0 + 431, "Session sleeping, waiting for scheduled wake-up" ],
        [ :state, T0 + 1500, "Session resumed — its turn is queued for a worker" ],
        [ :state, T0 + 1560, "Turn started on a worker" ],
        [ :user, T0 + 1565, "CI wake 1" ],
        [ :say, T0 + 1600, "Green." ],
        [ :archive, T0 + 1700, "session #9001 via the self-session MCP server" ]
      ]
    )

    helper = build_cycle_time_session(
      created_at: T0 + 25, title: "Helper", parent: root,
      script: [
        [ :state, T0 + 100, "Turn started on a worker" ],
        [ :user, T0 + 101, "Look it up" ],
        [ :tool, T0 + 110, T0 + 500, "WebFetch", { "url" => "https://example.com" } ],
        [ :say, T0 + 520, "Found it." ],
        [ :archive, T0 + 530, "session #9002 via the self-session MCP server" ]
      ]
    )

    archive_line = router_archive.sub("ROOT", root.id.to_s)
    Log.insert_all([ { session_id: root.id, content: "[State Machine] Session moved to trash by #{archive_line}", level: "info",
                       created_at: T0 + 1840, updated_at: T0 + 1840 } ])
    root.update_columns(status: Session.statuses[:archived], archived_at: T0 + 1840)
    [ root.reload, worker, helper ]
  end

  test "an autonomous hierarchy gets a row whose hierarchy totals sum to its wall-clock" do
    root, = build_hierarchy

    analysis = CycleTimes::Analyzer.call(root)

    assert analysis.eligible, analysis.ineligible_detail
    assert_equal 3, analysis.session_count
    assert_in_delta 1840.0, analysis.wall_seconds, 0.01
    assert_in_delta analysis.wall_seconds, analysis.category_seconds.values.sum, 0.05
    assert_equal "zimmer-orchestrator", analysis.agent_root

    analysis.lanes.each do |lane|
      lane_span = lane["end"] - lane["start"]
      assert_in_delta lane_span, lane["totals"].values.sum, 0.05, "lane #{lane['session_id']} does not tile its span"
      lane["segments"].each_cons(2) { |a, b| assert_in_delta a[1], b[0], 0.001, "lane #{lane['session_id']} has a gap or overlap" }
    end
  end

  test "work in one child outranks the router's wait on it, and CI shows where nothing else ran" do
    root, = build_hierarchy

    totals = CycleTimes::Analyzer.call(root).category_seconds

    # 90..390 the worker ran tests while the helper generated (101..110) and
    # fetched (110..500). Work outranks waiting, and among work inference >
    # network > local, so the tests keep only 90..101.
    assert_in_delta 11.0, totals["local_io"], 0.5
    assert_in_delta 372.0, totals["network"], 0.5
    # The worker slept on a CI wake from 431 to 1500; the helper was busy until
    # 520, so the hierarchy was blocked on CI for 520..1500.
    assert_in_delta 980.0, totals["wait_ci"], 0.5
    # The router "waited on a child" for 1,757 s, but a child had a more specific
    # account of all of it except 1700..1800, after both had archived.
    assert_in_delta 100.0, totals["wait_child"], 0.5
    assert_equal "wait_ci", CycleTimeAnalysis.find_by(root_session_id: root.id).dominant_wait_category
  end

  test "session time counts overlap, so it exceeds the wall-clock" do
    root, = build_hierarchy

    analysis = CycleTimes::Analyzer.call(root)

    assert_operator analysis.session_category_seconds.values.sum, :>, analysis.wall_seconds
    assert_operator analysis.session_category_seconds["wait_child"], :>, 1000
  end

  test "top segments name the session and what it was doing" do
    root, worker, = build_hierarchy

    top = CycleTimes::Analyzer.call(root).top_segments.first

    assert_equal "wait_ci", top["category"]
    assert_equal worker.id, top["session_id"]
    assert_match "CI wake 1", top["detail"]
  end

  test "a human Trash on the root records an ineligible row with the reason" do
    root, = build_hierarchy(router_archive: "a user in the web UI")

    analysis = CycleTimes::Analyzer.call(root)

    refute analysis.eligible
    assert_equal "human_archive", analysis.ineligible_reason
    assert_empty analysis.lanes
  end

  test "a hierarchy with a session still in flight gets no row, and loses a stale one" do
    root, worker, = build_hierarchy
    CycleTimes::Analyzer.call(root)
    worker.update_columns(status: Session.statuses[:needs_input], archived_at: nil)

    assert_nil CycleTimes::Analyzer.call(root)
    assert_nil CycleTimeAnalysis.find_by(root_session_id: root.id)
  end

  test "running twice writes one row" do
    root, = build_hierarchy

    CycleTimes::Analyzer.call(root)
    CycleTimes::Analyzer.call(root)

    assert_equal 1, CycleTimeAnalysis.where(root_session_id: root.id).count
  end
end
