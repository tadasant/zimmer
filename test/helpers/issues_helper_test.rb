# frozen_string_literal: true

require "test_helper"

class IssuesHelperTest < ActionView::TestCase
  include IssuesHelper

  test "the y axis climbs in round steps under the top of the plot" do
    assert_equal [ 0, 100, 200, 300, 400, 500 ], issue_trend_y_ticks(500)
    assert_equal [ 0, 125, 250, 375, 500 ], issue_trend_y_ticks(502)
    assert_equal [ 0, 10, 20, 30 ], issue_trend_y_ticks(39)
    assert_equal [ 0, 30, 60, 90, 120 ], issue_trend_y_ticks(137)
  end

  test "a tiny axis is not rounded into uselessness" do
    assert_equal [ 0, 1 ], issue_trend_y_ticks(1)
    assert_equal [ 0, 1, 2, 3 ], issue_trend_y_ticks(3)
    assert_equal [ 0, 2, 4, 6 ], issue_trend_y_ticks(6)
    assert_equal [ 0, 1 ], issue_trend_y_ticks(0), "an empty chart still has an axis"
  end

  test "no gridline is ever drawn above the top of the plot" do
    (1..600).each do |max|
      ticks = issue_trend_y_ticks(max)
      assert_equal 0, ticks.first
      assert_operator ticks.last, :<=, max, "gridline #{ticks.last} sits above a plot topping out at #{max}"
      assert_operator ticks.length, :>=, 2, "an axis with one gridline is not an axis (max #{max})"
    end
  end

  test "the plot points count y down from the axis top" do
    assert_equal "0,10 1,8 2,4", issue_trend_points([ 0, 2, 6 ], 10)
  end

  test "a gate session is linked only when it is an http(s) URL" do
    assert_match "https://zimmer.example.com/sessions/1",
                 issue_gate_session_link("https://zimmer.example.com/sessions/1")
    assert_nil issue_gate_session_link("javascript:alert(1)")
    assert_nil issue_gate_session_link("the groomer ran it by hand")
    assert_nil issue_gate_session_link(nil)
  end

  test "an issue URL reads as repo#number" do
    assert_equal "zimmer#498", issue_short_key("https://github.com/tadasant/zimmer/issues/498")
    assert_equal "fallback", issue_short_key("not a url", fallback: "fallback")
  end
end
