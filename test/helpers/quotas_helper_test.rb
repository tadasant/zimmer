# frozen_string_literal: true

require "test_helper"

class QuotasHelperTest < ActionView::TestCase
  include QuotasHelper

  # effective_utilization tests

  test "effective_utilization returns original value when reset_time is nil" do
    assert_in_delta 0.85, effective_utilization(0.85, nil)
  end

  test "effective_utilization returns original value when reset_time is in the future" do
    assert_in_delta 0.85, effective_utilization(0.85, 2.hours.from_now)
  end

  test "effective_utilization returns 0.0 when reset_time has passed" do
    assert_in_delta 0.0, effective_utilization(0.95, 1.hour.ago)
  end

  test "effective_utilization returns 0.0 when reset_time is exactly now" do
    assert_in_delta 0.0, effective_utilization(0.95, Time.current)
  end

  test "effective_utilization returns nil when utilization is nil regardless of reset_time" do
    assert_nil effective_utilization(nil, 1.hour.ago)
  end

  # time_until_reset tests

  test "time_until_reset returns N/A for nil" do
    assert_equal "N/A", time_until_reset(nil)
  end

  test "time_until_reset returns Window reset when time has passed" do
    assert_equal "Window reset", time_until_reset(1.hour.ago)
  end

  test "time_until_reset returns formatted time for future reset" do
    result = time_until_reset(3.hours.from_now)
    assert_match(/2h/, result)
    assert_match(/m/, result)
  end

  # utilization_percentage_text tests

  test "utilization_percentage_text shows 0.0% for zero" do
    assert_equal "0.0%", utilization_percentage_text(0.0)
  end

  test "utilization_percentage_text shows N/A for nil" do
    assert_equal "N/A", utilization_percentage_text(nil)
  end
end
