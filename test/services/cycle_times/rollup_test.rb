# frozen_string_literal: true

require "test_helper"

class CycleTimes::RollupTest < ActiveSupport::TestCase
  T = Time.utc(2026, 11, 1)
  Seg = CycleTimes::LaneBuilder::Segment

  def seg(from, to, category) = Seg.new(T + from, T + to, category, category)

  test "each instant goes to the highest-priority category, and the totals sum to the wall-clock" do
    parent = [ seg(0, 10, "inference"), seg(10, 100, "wait_child") ]
    child_a = [ seg(5, 50, "local_io"), seg(50, 80, "wait_ci") ]
    child_b = [ seg(20, 30, "network") ]

    result = CycleTimes::Rollup.new([ parent, child_a, child_b ], start: T, finish: T + 120).call

    assert_in_delta 10, result.totals["inference"]
    assert_in_delta 30, result.totals["local_io"] # 10..20 and 30..50
    assert_in_delta 10, result.totals["network"]
    assert_in_delta 30, result.totals["wait_ci"]
    assert_in_delta 20, result.totals["wait_child"]
    assert_in_delta 20, result.totals["unattributed"] # 100..120, nothing alive
    assert_in_delta 120, result.totals.values.sum
  end

  test "session time sums every lane, overlap included" do
    result = CycleTimes::Rollup.new([ [ seg(0, 60, "wait_child") ], [ seg(0, 60, "inference") ] ], start: T, finish: T + 60).call

    assert_in_delta 60, result.totals.values.sum
    assert_in_delta 120, result.summed_totals.values.sum
  end

  test "contributions credit the winning segment, and the merged lane names it" do
    result = CycleTimes::Rollup.new([ [ seg(0, 60, "wait_child") ], [ seg(10, 40, "wait_ci") ] ], start: T, finish: T + 60).call

    assert_in_delta 30, result.contributions[[ 1, 0 ]]
    assert_in_delta 30, result.contributions[[ 0, 0 ]]
    assert_equal [ "wait_child", "wait_ci", "wait_child" ], result.segments.map { |s| s[:category] }
  end
end
