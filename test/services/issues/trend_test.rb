# frozen_string_literal: true

require "test_helper"
require "support/issues_helpers"

# The series behind the chart, and the one property everything else rests on: an
# issue is counted on a day exactly when it was open at the end of that day.
class Issues::TrendTest < ActiveSupport::TestCase
  include IssuesHelpers

  test "an open issue is counted from the day it was created onward" do
    trend = build([ github_issue(number: 1, created_at: noon(3)) ], window_days: 7)

    assert_equal [ 0, 0, 0, 1, 1, 1, 1 ], series_values(trend, Issues::Direction::UNRATED),
                 "a 7-day window is today-6..today, so today-3 is index 3"
  end

  test "a closed issue stops being counted on the day it closed" do
    trend = build([ github_issue(number: 1, created_at: noon(6), closed_at: noon(3), state: "closed") ],
                  window_days: 7)

    assert_equal [ 1, 1, 1, 0, 0, 0, 0 ], series_values(trend, Issues::Direction::UNRATED),
                 "closed at midday on index 3, so that day ends with it shut"
  end

  test "an issue created before the window is counted for the whole window" do
    trend = build([ github_issue(number: 1, created_at: noon(400)) ], window_days: 5)

    assert_equal [ 1, 1, 1, 1, 1 ], series_values(trend, Issues::Direction::UNRATED)
  end

  test "an issue created after the window ends is never counted" do
    trend = build([ github_issue(number: 1, created_at: noon(-2)) ], window_days: 5)

    assert trend.totals.all?(&:zero?)
  end

  test "an issue opened and closed the same day never appears" do
    trend = build([ github_issue(number: 1, created_at: noon(3), closed_at: noon(3) + 2.hours, state: "closed") ],
                  window_days: 7)

    assert trend.totals.all?(&:zero?), "it was not open at the end of any day"
  end

  test "the fast path agrees with the per-day predicate it replaces" do
    issues = [
      github_issue(number: 1, created_at: noon(9)),
      github_issue(number: 2, created_at: noon(20), closed_at: noon(4), state: "closed"),
      github_issue(number: 3, created_at: noon(2))
    ]
    trend = build(issues, window_days: 12)

    expected = trend.dates.map { |date| issues.count { |issue| issue.open_on?(date) } }
    assert_equal expected, trend.totals
  end

  test "segments by direction, and the segments sum to the total" do
    resolutions = {
      "convergent" => Issues::Direction::Resolution.new(direction: "convergent", source: :label),
      "divergent" => Issues::Direction::Resolution.new(direction: "divergent", source: :label)
    }
    issues = [
      github_issue(number: 1, created_at: noon(5), labels: [ "convergent" ]),
      github_issue(number: 2, created_at: noon(5), labels: [ "convergent" ]),
      github_issue(number: 3, created_at: noon(5), labels: [ "divergent" ])
    ]
    trend = Issues::Trend.new(
      issues: issues, window_days: 7, segment: "direction",
      direction_for: ->(issue) { resolutions.fetch(issue.labels.first) }
    )

    assert_equal %w[convergent divergent], trend.series.map(&:key)
    assert_equal 2, trend.series.first.last_value
    assert_equal 1, trend.series.last.last_value
    assert_equal 3, trend.totals.last
  end

  test "the unrated segment is grey and last, however big it is" do
    unrated = ->(_issue) { Issues::Direction::UNRESOLVED }
    convergent = Issues::Direction::Resolution.new(direction: "convergent", source: :label)
    issues = 5.times.map { |i| github_issue(number: i, created_at: noon(5)) }
    issues << github_issue(number: 99, created_at: noon(5), labels: [ "convergent" ])

    trend = Issues::Trend.new(issues: issues, window_days: 7, segment: "direction",
                              direction_for: ->(issue) { issue.labels.any? ? convergent : unrated.call(issue) })

    assert_equal [ "convergent", Issues::Direction::UNRATED ], trend.series.map(&:key)
    assert_equal Issues::Trend::RESIDUAL_COLOR, trend.series.last.color
    assert_equal Issues::Trend::PALETTE.first, trend.series.first.color
  end

  test "segments by repo" do
    trend = build([ github_issue(repo: "tadasant/zimmer", number: 1, created_at: noon(5)),
                    github_issue(repo: "tadasant/motet", number: 1, created_at: noon(5)) ],
                  window_days: 7, segment: "repo")

    assert_equal %w[motet zimmer].sort, trend.series.map(&:key).sort
  end

  test "segmenting by label folds the long tail into one grey series rather than inventing hues" do
    issues = (1..9).map { |i| github_issue(number: i, created_at: noon(5), labels: [ "label-#{i}" ]) }
    # Make one label the most common so the ranking has something to rank by.
    issues << github_issue(number: 20, created_at: noon(5), labels: [ "label-1" ])

    trend = build(issues, window_days: 7, segment: "label")

    assert_operator trend.series.length, :<=, Issues::Trend::MAX_SERIES
    assert_equal Issues::Trend::OTHER, trend.series.last.key
    assert_equal 10, trend.totals.last, "folding must not lose an issue"
  end

  test "direction labels are not offered as label segments" do
    trend = build([ github_issue(number: 1, created_at: noon(5), labels: [ "convergent" ]) ],
                  window_days: 7, segment: "label")

    assert_equal [ Issues::Trend::OTHER ], trend.series.map(&:key)
  end

  test "an issue closed before the window opened is never counted" do
    trend = build([ github_issue(number: 1, created_at: noon(60), closed_at: noon(40), state: "closed") ],
                  window_days: 30)

    assert trend.totals.all?(&:zero?)
  end

  test "exactly MAX_SERIES named segments all keep their own colour" do
    issues = (1..Issues::Trend::MAX_SERIES).flat_map do |i|
      # Descending sizes, so the ordering is deterministic and every segment is named.
      (Issues::Trend::MAX_SERIES - i + 1).times.map { |n| github_issue(number: (i * 100) + n, created_at: noon(5), labels: [ "label-#{i}" ]) }
    end
    trend = build(issues, window_days: 7, segment: "label")

    assert_equal Issues::Trend::MAX_SERIES, trend.series.length
    assert_equal Issues::Trend::PALETTE, trend.series.map(&:color)
    assert_not_includes trend.series.map(&:key), Issues::Trend::OTHER
    assert_equal issues.length, trend.totals.last
  end

  test "an unknown segment falls back to direction rather than raising" do
    assert_equal Issues::Trend::DEFAULT_SEGMENT, build([], window_days: 7, segment: "wat").segment
  end

  test "the window sets the number of days and the last day is today" do
    trend = build([], window_days: 90)

    assert_equal 90, trend.dates.length
    assert_equal Date.current, trend.dates.last
    assert_operator trend.tick_indexes.length, :<=, Issues::Trend::MAX_TICKS
  end

  test "an empty window is empty rather than a division by zero" do
    trend = build([], window_days: 30)

    assert trend.empty?
    assert_equal 1, trend.max_value
  end

  test "a GitHub label named `unrated` does not become a second grey series" do
    issues = [ github_issue(number: 1, created_at: noon(5), labels: [ "unrated" ]),
               github_issue(number: 2, created_at: noon(5)) ]

    trend = build(issues, window_days: 7, segment: "label")

    grey = trend.series.select { |s| s.color == Issues::Trend::RESIDUAL_COLOR }
    assert_equal 1, grey.length, "only one bucket per chart means we could not classify this"
    assert_equal Issues::Trend::OTHER, grey.sole.key
    assert_equal 2, trend.totals.last, "and no issue is lost to the relabelling"
  end

  private

  def build(issues, window_days:, segment: "direction")
    Issues::Trend.new(issues: issues, window_days: window_days, segment: segment,
                      direction_for: ->(_issue) { Issues::Direction::UNRESOLVED })
  end

  # Midday `days` ago, so a test never straddles a date boundary because it ran
  # at 23:59 — which is exactly the bug a naive `3.days.ago` hides.
  def noon(days)
    (Date.current - days).in_time_zone.change(hour: 12)
  end

  def series_values(trend, key)
    trend.series.find { |s| s.key == key }&.values
  end
end
