# frozen_string_literal: true

require "test_helper"

class CycleTimes::ReportTest < ActiveSupport::TestCase
  include CycleTimeFixtures

  test "aggregates hierarchy time, shares, percentiles and the newest-first rows over the window" do
    create_cycle_time_row(finished_at: 3.hours.ago, totals: { "inference" => 100, "wait_ci" => 300 }, title: "Short")
    create_cycle_time_row(finished_at: 2.hours.ago, totals: { "inference" => 200, "wait_ci" => 1400 }, title: "Long")
    create_cycle_time_row(finished_at: 40.days.ago, totals: { "inference" => 999 }, title: "Outside")

    report = CycleTimes::Report.new(window: CostWindow.from_params(days: 7))

    assert_equal 2, report.count
    assert_in_delta 2000, report.wall_seconds
    assert_in_delta 1700, report.totals["wait_ci"]
    assert_equal [ "wait_ci" ], report.top_waits.map(&:first)
    assert_in_delta 400, report.wall_percentiles["p50"]
    assert_in_delta 1600, report.wall_percentiles["max"]
    assert_equal %w[Long Short], report.rows.map(&:title)
    assert_equal %w[Long], report.slowest(1).map(&:title)
    shares = report.to_h[:categories].sum { |row| row[:share] }
    assert_in_delta 1.0, shares, 0.001
  end
end
