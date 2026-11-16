# frozen_string_literal: true

require "test_helper"

class CycleTimeJobsTest < ActiveJob::TestCase
  include CycleTimeFixtures

  AGENT = "session #1 via the self-session MCP server"

  def settled_root(at: 2.days.ago)
    root = build_cycle_time_session(created_at: at, title: "Root", script: simple_turn(at + 5) + [ [ :archive, at + 120, AGENT ] ])
    build_cycle_time_session(created_at: at + 10, title: "Child", parent: root, script: simple_turn(at + 20) + [ [ :archive, at + 100, AGENT ] ])
    root
  end

  test "archiving a session enqueues the analysis of its hierarchy" do
    session = create_session(status: :needs_input)

    assert_enqueued_with(job: CycleTimeAnalysisJob, args: [ session.id ]) do
      session.archive!
    end
  end

  test "a status-summary fork's archive enqueues nothing and is never analyzed" do
    fork = create_session(status: :needs_input, metadata: { SessionStatusSummaryGenerator::FORK_MARKER => 1 })

    assert_no_enqueued_jobs(only: CycleTimeAnalysisJob) { fork.archive! }
    CycleTimeAnalysisJob.perform_now(fork.id)
    assert_not CycleTimeAnalysis.exists?(root_session_id: fork.id)
  end

  test "the analysis job walks to the root from any session in the hierarchy" do
    root = settled_root
    child = root.child_sessions.first

    CycleTimeAnalysisJob.perform_now(child.id)

    assert CycleTimeAnalysis.find_by(root_session_id: root.id).eligible
  end

  test "the sweep backfills settled roots in its lookback, once" do
    root = settled_root
    old = settled_root(at: CycleTimeSweepJob::LOOKBACK.ago - 2.days)

    assert_equal 1, CycleTimeSweepJob.perform_now
    assert CycleTimeAnalysis.exists?(root_session_id: root.id)
    assert_not CycleTimeAnalysis.exists?(root_session_id: old.id)
    assert_equal 0, CycleTimeSweepJob.perform_now
  end

  test "the sweep reaches roots whose metadata is NULL" do
    root = settled_root
    root.update_columns(metadata: nil)

    assert_includes CycleTimeSweepJob.candidate_scope.pluck(:id), root.id
  end

  test "restoring a session drops its hierarchy's row" do
    root = settled_root
    CycleTimes::Analyzer.call(root)
    child = root.child_sessions.first

    assert_enqueued_with(job: CycleTimeAnalysisJob, args: [ child.id ]) { child.unarchive_to_needs_input! }
    perform_enqueued_jobs(only: CycleTimeAnalysisJob)

    assert_not CycleTimeAnalysis.exists?(root_session_id: root.id)
  end

  test "the sweep recomputes rows written by an older analyzer version" do
    root = settled_root
    CycleTimes::Analyzer.call(root)
    CycleTimeAnalysis.where(root_session_id: root.id).update_all(algorithm_version: 0)

    assert_equal 1, CycleTimeSweepJob.perform_now
    assert_equal CycleTimes::Analyzer::VERSION, CycleTimeAnalysis.find_by(root_session_id: root.id).algorithm_version
  end
end
