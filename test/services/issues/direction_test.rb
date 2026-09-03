# frozen_string_literal: true

require "test_helper"
require "support/work_backlog_helpers"
require "support/issues_helpers"

# The four-step fallback chain. Every step matters because the three sources are
# landing at different times: the GitHub labels are being back-filled right now,
# the backlog only covers issues the gate queued, and the gate ledger is the only
# record for everything it rated and did not queue.
class Issues::DirectionTest < ActiveSupport::TestCase
  include WorkBacklogHelpers
  include IssuesHelpers

  ISSUE_URL = "https://github.com/tadasant/zimmer/issues/4242"

  test "the GitHub label wins over everything else" do
    backlog_item(key: "zimmer#4242", issue_url: ISSUE_URL, scope_direction: "convergent")
    gate_decision(ISSUE_URL, "convergent")

    resolution = resolver.call(labels: [ "bug", "divergent" ], issue_url: ISSUE_URL)

    assert_equal "divergent", resolution.direction
    assert_equal :label, resolution.source
  end

  test "with no label, the backlog row answers" do
    backlog_item(key: "zimmer#4242", issue_url: ISSUE_URL, scope_direction: "divergent")

    resolution = resolver.call(labels: [ "bug" ], issue_url: ISSUE_URL)

    assert_equal "divergent", resolution.direction
    assert_equal :backlog, resolution.source
  end

  test "with no label and no backlog row, the latest issue_work rating answers" do
    gate_decision(ISSUE_URL, "convergent", decided_at: Date.new(2026, 7, 1))
    gate_decision(ISSUE_URL, "divergent", decided_at: Date.new(2026, 8, 1))

    resolution = resolver.call(labels: [], issue_url: ISSUE_URL)

    assert_equal "divergent", resolution.direction, "a re-rate is a new row; the newest is the current reading"
    assert_equal :gate, resolution.source
  end

  test "a rating under the ratings key is read too" do
    GateDecision.create!(
      gate: GateDecision::ISSUE_WORK, surface: "zimmer", recorded_via: GateDecision::IMPORT,
      artifact_url: ISSUE_URL, decided_at: Date.new(2026, 8, 1), decision: "auto-proceed",
      payload: { "ratings" => { "scope_direction" => "divergent" } }
    )

    assert_equal "divergent", resolver.call(labels: [], issue_url: ISSUE_URL).direction
  end

  test "an unlabelled, unqueued, unrated issue is unrated rather than guessed" do
    resolution = resolver.call(labels: [ "bug", "agent-filed" ], issue_url: ISSUE_URL)

    assert_equal Issues::Direction::UNRATED, resolution.direction
    assert_equal :none, resolution.source
    assert_not resolution.rated?
  end

  test "a pr_merge rating never answers a question about an issue's direction" do
    GateDecision.create!(
      gate: GateDecision::PR_MERGE, surface: "zimmer", recorded_via: GateDecision::IMPORT,
      artifact_url: ISSUE_URL, decided_at: Date.new(2026, 8, 1), decision: "auto-merge",
      payload: { "scope_direction" => "divergent" }
    )

    assert_equal Issues::Direction::UNRATED, resolver.call(labels: [], issue_url: ISSUE_URL).direction
  end

  test "a payload whose scope_direction is not a direction is ignored" do
    GateDecision.create!(
      gate: GateDecision::ISSUE_WORK, surface: "zimmer", recorded_via: GateDecision::IMPORT,
      artifact_url: ISSUE_URL, decided_at: Date.new(2026, 8, 1), decision: "hold",
      payload: { "scope_direction" => "unclear" }
    )

    assert_equal Issues::Direction::UNRATED, resolver.call(labels: [], issue_url: ISSUE_URL).direction
  end

  test "the queued row wins over an older removed row for the same issue" do
    backlog_item(key: "zimmer#4242", issue_url: ISSUE_URL, scope_direction: "convergent",
                 status: WorkBacklogItem::REMOVED, removal_reason: "issue_closed", removed_by: "human")
    backlog_item(key: "zimmer#4242", issue_url: ISSUE_URL, scope_direction: "divergent")

    assert_equal "divergent", resolver.call(labels: [], issue_url: ISSUE_URL).direction
  end

  test "for_item prefers the label over the row's own column" do
    item = backlog_item(key: "zimmer#4242", issue_url: ISSUE_URL, scope_direction: "convergent")

    labelled = resolver.for_item(item, github_issue(number: 4242, labels: [ "divergent" ]))
    assert_equal "divergent", labelled.direction
    assert_equal :label, labelled.source

    unlabelled = resolver.for_item(item, github_issue(number: 4242, labels: [ "bug" ]))
    assert_equal "convergent", unlabelled.direction
    assert_equal :backlog, unlabelled.source
  end

  test "an issue with no URL cannot be resolved past its labels" do
    assert_equal Issues::Direction::UNRATED, resolver.call(labels: [], issue_url: nil).direction
    assert_equal "convergent", resolver.call(labels: [ "convergent" ], issue_url: nil).direction
  end

  private

  def resolver
    Issues::Direction.new(issue_urls: [ ISSUE_URL ])
  end

  def gate_decision(url, direction, decided_at: Date.new(2026, 8, 1))
    GateDecision.create!(
      gate: GateDecision::ISSUE_WORK, surface: "zimmer", recorded_via: GateDecision::IMPORT,
      artifact_url: url, decided_at: decided_at, decision: "auto-proceed",
      payload: { "scope_direction" => direction }
    )
  end
end
