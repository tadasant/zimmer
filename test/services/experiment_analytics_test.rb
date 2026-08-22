# frozen_string_literal: true

require "test_helper"

class ExperimentAnalyticsTest < ActiveSupport::TestCase
  KEY = "mcp_tool_search"

  setup do
    SessionExperimentalFlag.delete_all
    SessionTokenUsage.delete_all
  end

  # A tagged session with `calls` API calls, each billing `scale` times a fixed
  # volume, so cost per call is directly comparable across cohorts.
  def tagged_session(start_value:, end_value: nil, calls: 10, scale: 1, root: "zimmer")
    session = create_session(title: "s")
    SessionExperimentalFlag.create!(
      session: session, setting_key: KEY,
      value_at_start: start_value, value_at_end: end_value.nil? ? start_value : end_value
    )
    calls.times do |i|
      SessionTokenUsage.create!(
        request_id: "req_#{session.id}_#{i}", session_id: session.id, agent_root: root,
        model: "claude-opus-5", called_at: 1.hour.ago,
        input_tokens: 1_000 * scale, output_tokens: 500 * scale, cache_read_tokens: 10_000 * scale
      )
    end
    session
  end

  def report
    scope = SessionTokenUsage.in_window(7.days.ago, Time.current)
    ExperimentAnalytics.new(scope).reports.find { |r| r[:key] == KEY }
  end

  test "cohorts split by the value observed at the session's start" do
    6.times { tagged_session(start_value: false, scale: 4) }
    6.times { tagged_session(start_value: true, scale: 1) }

    cohorts = report[:cohorts]

    assert_equal 6, cohorts["off"][:sessions]
    assert_equal 6, cohorts["on"][:sessions]
    assert_operator cohorts["off"][:cost_per_call], :>, cohorts["on"][:cost_per_call]
  end

  test "a session whose ends disagree is bucketed out of both cohorts" do
    6.times { tagged_session(start_value: false) }
    6.times { tagged_session(start_value: true) }
    tagged_session(start_value: true, end_value: false)

    cohorts = report[:cohorts]

    assert_equal 1, cohorts["mixed"][:sessions]
    assert_equal 6, cohorts["off"][:sessions]
    assert_equal 6, cohorts["on"][:sessions]
  end

  test "a thin cohort refuses to be compared" do
    # The failure this guards is the point of the whole section: a dramatic delta
    # over three sessions reads exactly like a real one.
    10.times { tagged_session(start_value: false, scale: 4) }
    2.times { tagged_session(start_value: true, scale: 1) }

    refute report[:comparison][:comparable]
  end

  test "a cohort with enough on both sides reports the change per API call" do
    6.times { tagged_session(start_value: false, calls: 10, scale: 4) }
    6.times { tagged_session(start_value: true, calls: 10, scale: 1) }

    comparison = report[:comparison]

    assert comparison[:comparable]
    assert_operator comparison[:cost_per_call_change], :<, 0, "on is cheaper per call, so the change is negative"
  end

  test "only agent roots present on both sides are paired" do
    # A root that only ever ran under one cohort tells you about scheduling, not
    # about the setting, so it is dropped rather than shown with half a row.
    3.times { tagged_session(start_value: false, root: "zimmer", scale: 4) }
    3.times { tagged_session(start_value: true, root: "zimmer", scale: 1) }
    3.times { tagged_session(start_value: true, root: "only-after") }

    roots = report[:paired_roots].map { |r| r[:agent_root] }

    assert_equal [ "zimmer" ], roots
    assert_operator report[:paired_roots].first[:cost_per_call_change], :<, 0
  end

  test "untagged sessions are absent rather than counted as a cohort" do
    session = create_session(title: "untagged")
    SessionTokenUsage.create!(
      request_id: "req_untagged", session_id: session.id, model: "claude-opus-5",
      called_at: 1.hour.ago, input_tokens: 1_000, output_tokens: 1_000
    )

    cohorts = report[:cohorts]

    assert_equal 0, cohorts.values.sum { |c| c[:sessions] }
  end

  test "the report carries the boundary date and where its labels came from" do
    # These are what stop a reader treating a temporal cohort as a randomized one.
    tagged_session(start_value: true)
    SessionExperimentalFlag.last.update!(source: SessionExperimentalFlag::BACKFILLED)

    result = report

    assert result[:landed_at].present?
    assert result[:backfilled]
    assert_equal 1, result[:tagged_by_source][SessionExperimentalFlag::BACKFILLED]
  end

  test "an empty window reports zeroes rather than blowing up on nil arithmetic" do
    result = report

    assert_equal 0, result[:cohorts]["on"][:sessions]
    assert_nil result[:cohorts]["on"][:cost_per_call]
    refute result[:comparison][:comparable]
    assert_empty result[:paired_roots]
  end
end
