# frozen_string_literal: true

require "test_helper"

class CostWindowTest < ActiveSupport::TestCase
  test "a preset resolves to a window ending now" do
    window = CostWindow.from_params(days: 30)

    assert_not window.custom?
    assert_equal 30, window.preset_days
    assert_equal "30 days", window.label
    assert_equal({ days: 30 }, window.to_params)
    assert_in_delta 30.days.ago.to_i, window.from.to_i, 5
  end

  test "a missing or unusable preset falls back to the default rather than erroring" do
    assert_equal CostWindow::DEFAULT_DAYS, CostWindow.from_params({}).preset_days
    assert_equal CostWindow::DEFAULT_DAYS, CostWindow.from_params(days: "banana").preset_days
    assert_equal CostWindow::DEFAULT_DAYS, CostWindow.from_params(days: 0).preset_days
    assert_equal CostWindow::DEFAULT_DAYS, CostWindow.from_params(days: -5).preset_days
  end

  test "a calendar range covers whole days at both ends" do
    window = CostWindow.from_params(from: "2026-03-09", to: "2026-03-11")

    assert window.custom?
    assert_equal Date.new(2026, 3, 9).in_time_zone.beginning_of_day, window.from
    # Inclusive of the END day: "Mar 9 to Mar 11" means through the end of the 11th,
    # which is what the person filling in the second date field meant.
    assert_equal Date.new(2026, 3, 11).in_time_zone.end_of_day, window.to
    assert_equal({ from: "2026-03-09", to: "2026-03-11" }, window.to_params)
  end

  test "half a range still resolves" do
    only_from = CostWindow.from_params(from: "2026-03-09")
    assert only_from.custom?
    assert_equal Date.current, only_from.to_date

    only_to = CostWindow.from_params(to: "2026-03-09")
    assert only_to.custom?
    assert_equal Date.new(2026, 3, 9) - CostWindow::DEFAULT_DAYS, only_to.from_date
  end

  test "a reversed range is swapped rather than rejected" do
    window = CostWindow.from_params(from: "2026-03-11", to: "2026-03-09")

    assert_equal Date.new(2026, 3, 9), window.from_date
    assert_equal Date.new(2026, 3, 11), window.to_date
  end

  test "an oversized span is clamped to the most recent MAX_DAYS" do
    window = CostWindow.from_params(from: "2019-01-01", to: "2026-03-09")

    assert_equal Date.new(2026, 3, 9), window.to_date
    assert_equal CostWindow::MAX_DAYS, window.days
  end

  test "an unparseable date falls back to the preset path instead of blowing up" do
    window = CostWindow.from_params(from: "not-a-date", days: 30)

    assert_not window.custom?
    assert_equal 30, window.preset_days
  end

  test "a preset pre-fills the calendar fields with its own bounds" do
    # Opening the picker should start from what you are already looking at.
    window = CostWindow.from_params(days: 7)

    assert_equal Date.current, window.to_date
    assert_equal 7.days.ago.to_date, window.from_date
  end

  test "a single-day range reads as one date" do
    assert_equal "Mar 9, 2026", CostWindow.from_params(from: "2026-03-09", to: "2026-03-09").label
  end
end
