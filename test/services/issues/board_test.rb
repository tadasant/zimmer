# frozen_string_literal: true

require "test_helper"
require "support/work_backlog_helpers"
require "support/issues_helpers"

# The join. The properties worth pinning are about which side of the page a row
# lands on, and about the filters meaning the same thing on both sides.
class Issues::BoardTest < ActiveSupport::TestCase
  include WorkBacklogHelpers
  include IssuesHelpers

  test "queued items come back in rank order with their position on the queue" do
    backlog_item(key: "zimmer#1", precedence: 100)
    backlog_item(key: "zimmer#2", precedence: 6000)

    rows = board.queued_rows

    assert_equal %w[zimmer#2 zimmer#1], rows.map(&:key)
    assert_equal [ 1, 2 ], rows.map(&:position)
  end

  test "a queued item is joined to its GitHub issue, and its label beats its column" do
    backlog_item(key: "zimmer#7", issue_url: url(7), scope_direction: "convergent")
    snapshot = github_snapshot(issues: [ github_issue(number: 7, labels: [ "divergent", "bug" ]) ])

    row = board(snapshot: snapshot).queued_rows.sole

    assert_equal "divergent", row.direction.direction
    assert_equal :label, row.direction.source
    assert_equal [ "divergent", "bug" ], row.labels
    assert_not row.issue_closed?
  end

  test "a queued item whose issue has been closed says so" do
    backlog_item(key: "zimmer#7", issue_url: url(7))
    snapshot = github_snapshot(issues: [ github_issue(number: 7, state: "closed", closed_at: 1.day.ago) ])

    assert board(snapshot: snapshot).queued_rows.sole.issue_closed?
  end

  test "an open issue with a live backlog row is not also in the loose list" do
    backlog_item(key: "zimmer#7", issue_url: url(7))
    snapshot = github_snapshot(issues: [ github_issue(number: 7), github_issue(number: 8) ])

    assert_equal [ 8 ], board(snapshot: snapshot).loose_rows.map { |row| row.github.number }
  end

  test "an issue whose backlog row was removed comes back to the loose list" do
    backlog_item(key: "zimmer#7", issue_url: url(7), status: WorkBacklogItem::REMOVED,
                 removal_reason: "not worth it", removed_by: "human")
    snapshot = github_snapshot(issues: [ github_issue(number: 7) ])

    assert_equal [ 7 ], board(snapshot: snapshot).loose_rows.map { |row| row.github.number }
  end

  test "a started item whose session died comes back to the loose list rather than vanishing" do
    item = backlog_item(key: "zimmer#7", issue_url: url(7))
    item.mark_started!(session: sessions(:archived), by: nil)
    snapshot = github_snapshot(issues: [ github_issue(number: 7) ])

    result = board(snapshot: snapshot)

    assert_empty result.queued_rows
    assert_empty result.in_flight_rows, "the session is archived, so nothing is in flight"
    assert_equal [ 7 ], result.loose_rows.map { |row| row.github.number },
                 "the issue is open and nobody is working it — it must not disappear from the page"
  end

  test "closed GitHub issues never appear in the loose list" do
    snapshot = github_snapshot(issues: [ github_issue(number: 8, state: "closed", closed_at: 1.day.ago) ])

    assert_empty board(snapshot: snapshot).loose_rows
  end

  test "the gate's hold label is surfaced on a loose row" do
    snapshot = github_snapshot(issues: [ github_issue(number: 8, labels: [ Issues::Board::HOLD_LABEL ]) ])

    assert board(snapshot: snapshot).loose_rows.sole.held?
  end

  test "the repo and direction filters narrow the GitHub half as well as the queue" do
    snapshot = github_snapshot(issues: [
      github_issue(repo: "tadasant/zimmer", number: 1, labels: [ "convergent" ]),
      github_issue(repo: "tadasant/zimmer", number: 2, labels: [ "divergent" ]),
      github_issue(repo: "tadasant/motet", number: 3, labels: [ "convergent" ])
    ])

    by_repo = board(snapshot: snapshot, filters: { "repo" => "tadasant/zimmer" }).loose_rows
    assert_equal [ 2, 1 ], by_repo.map { |row| row.github.number }, "newest issue first within a repo"

    by_direction = board(snapshot: snapshot, filters: { "scope_direction" => "divergent" }).loose_rows
    assert_equal [ 2 ], by_direction.map { |row| row.github.number }
  end

  test "a queue-only filter narrows the queue and leaves the GitHub list alone" do
    backlog_item(key: "zimmer#1", issue_url: url(1), kind: "bug")
    backlog_item(key: "zimmer#2", issue_url: url(2), kind: "tech-debt")
    snapshot = github_snapshot(issues: [ github_issue(number: 3) ])

    result = board(snapshot: snapshot, filters: { "kind" => "bug" })

    assert_equal %w[zimmer#1], result.queued_rows.map(&:key)
    assert_equal [ 3 ], result.loose_rows.map { |row| row.github.number }
  end

  test "in-flight rows are started items with a live session, and ignore the filters" do
    live = backlog_item(key: "zimmer#1", repo: "tadasant/zimmer")
    live.mark_started!(session: sessions(:running), by: nil)
    dead = backlog_item(key: "motet#1", repo: "tadasant/motet")
    dead.mark_started!(session: sessions(:archived), by: nil)

    rows = board(filters: { "repo" => "tadasant/motet" }).in_flight_rows

    assert_equal %w[zimmer#1], rows.map(&:key), "a repo filter must not empty the running list"
  end

  test "counts describe the whole queue, not the filtered slice" do
    backlog_item(key: "zimmer#1", kind: "bug")
    backlog_item(key: "zimmer#2", kind: "tech-debt")

    result = board(filters: { "kind" => "bug" })

    assert_equal 1, result.queued_rows.length
    assert_equal 2, result.counts[:queued]
  end

  test "the direction counts resolve through the chain rather than off the column" do
    backlog_item(key: "zimmer#1", issue_url: url(1), scope_direction: "convergent")
    snapshot = github_snapshot(issues: [ github_issue(number: 1, labels: [ "divergent" ]) ])

    assert_equal 1, board(snapshot: snapshot).queued_by_direction["divergent"]
    assert_equal 0, board(snapshot: snapshot).queued_by_direction["convergent"]
  end

  test "the direction filter reads the resolved direction on the queue, not the raw column" do
    # The column says convergent; the GitHub label — which wins — says divergent.
    backlog_item(key: "zimmer#1", issue_url: url(1), scope_direction: "convergent")
    snapshot = github_snapshot(issues: [ github_issue(number: 1, labels: [ "divergent" ]) ])

    divergent = board(snapshot: snapshot, filters: { "scope_direction" => "divergent" })
    assert_equal %w[zimmer#1], divergent.queued_rows.map(&:key),
                 "the pill reads divergent, so the divergent filter has to keep the row"

    convergent = board(snapshot: snapshot, filters: { "scope_direction" => "convergent" })
    assert_empty convergent.queued_rows,
                 "filtering on the column while the pill shows the resolved value is how the two disagree"
  end

  test "a page past the end is clamped rather than rendering an empty page 999 of 3" do
    issues = (1..(Issues::Board::GITHUB_PER_PAGE + 3)).map { |n| github_issue(number: n) }
    result = board(snapshot: github_snapshot(issues: issues), page: 999)

    assert_equal 2, result.github_page
    assert_equal 3, result.loose_page_rows.length
  end

  test "a page below the first is clamped too" do
    result = board(snapshot: github_snapshot(issues: [ github_issue(number: 1) ]), page: -4)

    assert_equal 1, result.github_page
  end

  test "the loose list is paginated" do
    issues = (1..(Issues::Board::GITHUB_PER_PAGE + 3)).map { |n| github_issue(number: n) }
    result = board(snapshot: github_snapshot(issues: issues), page: 2)

    assert_equal 2, result.loose_page_count
    assert_equal 3, result.loose_page_rows.length
    assert_equal issues.length, result.loose_total
  end

  test "a repo whose search failed is reported rather than shown as zero open issues" do
    snapshot = github_snapshot(issues: [], errors: { "tadasant/motet" => "boom" })

    summary = board(snapshot: snapshot).repo_summaries.find { |s| s.repo == "tadasant/motet" }
    assert_equal "boom", summary.error
  end

  test "the trend issue set follows the repo filter" do
    snapshot = github_snapshot(issues: [ github_issue(repo: "tadasant/zimmer", number: 1),
                                         github_issue(repo: "tadasant/motet", number: 2) ])

    assert_equal 2, board(snapshot: snapshot).trend_issues.length
    assert_equal [ "tadasant/motet" ],
                 board(snapshot: snapshot, filters: { "repo" => "tadasant/motet" }).trend_issues.map(&:repo)
  end

  test "a started item whose session is dead comes back into the loose list" do
    item = backlog_item(key: "zimmer#7", issue_url: url(7))
    item.mark_started!(session: sessions(:archived), by: nil)
    snapshot = github_snapshot(issues: [ github_issue(number: 7) ])

    result = board(snapshot: snapshot)
    assert_empty result.in_flight_rows, "the session is archived, so nothing is in flight"
    assert_equal [ 7 ], result.loose_rows.map { |row| row.github.number },
                 "an issue nobody is working must be visible somewhere"
  end

  test "a queued item whose issue is closed stays on the queue and out of the loose list" do
    backlog_item(key: "zimmer#7", issue_url: url(7))
    snapshot = github_snapshot(issues: [ github_issue(number: 7, state: "closed", closed_at: 1.day.ago) ])

    result = board(snapshot: snapshot)
    assert result.queued_rows.sole.issue_closed?
    assert_empty result.loose_rows, "a closed issue is never loose, queued or not"
  end

  test "per-repo direction counts agree with the pills the rows carry" do
    snapshot = github_snapshot(issues: [
      github_issue(repo: "tadasant/zimmer", number: 1, labels: [ "convergent" ]),
      github_issue(repo: "tadasant/zimmer", number: 2, labels: [ "divergent" ]),
      github_issue(repo: "tadasant/zimmer", number: 3),
      github_issue(repo: "tadasant/zimmer", number: 4, state: "closed", closed_at: 1.day.ago, labels: [ "convergent" ])
    ])

    summary = board(snapshot: snapshot).repo_summaries.find { |r| r.repo == "tadasant/zimmer" }
    assert_equal 3, summary.open_count, "a closed issue is not open"
    assert_equal({ "convergent" => 1, "divergent" => 1, "unrated" => 1 }, summary.directions)
  end

  private

  def url(number) = "https://github.com/tadasant/zimmer/issues/#{number}"

  def board(snapshot: github_snapshot, filters: {}, page: 1)
    Issues::Board.new(filters: WorkBacklog::Filters.new(filters), snapshot: snapshot, github_page: page)
  end
end
