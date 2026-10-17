# frozen_string_literal: true

require "test_helper"

class ClaudeAccountScoreTest < ActiveSupport::TestCase
  setup do
    @account = claude_accounts(:secondary)
    @account.quota_snapshots.delete_all
  end

  def reading(u5: 0.0, u7: 0.0, reset_5h: nil, reset_7d: 6.days.from_now, at: 5.minutes.ago,
    status_5h: "allowed", status_7d: "allowed")
    @account.quota_snapshots.create!(
      utilization_5h: u5, utilization_7d: u7, status_5h: status_5h, status_7d: status_7d,
      reset_5h: reset_5h, reset_7d: reset_7d, trigger: "usage_sample", created_at: at
    )
  end

  def score(snapshot) = ClaudeAccountScore.new(@account, snapshot)

  test "an untouched account scores 1" do
    assert_in_delta 1.0, score(reading).value, 0.0001
  end

  test "weekly usage costs four times what 5-hour usage does" do
    weekly = score(reading(u7: 0.5)).value
    five_hour = score(reading(u5: 0.5)).value

    assert_in_delta 0.6, weekly, 0.0001
    assert_in_delta 0.9, five_hour, 0.0001
  end

  # The motivating case: 81% of the week used with a day and a half left gets no
  # credit for the reset, so a fresh account outranks it by a wide margin.
  test "an account at 81% weekly with days left scores far below a fresh one" do
    spent = score(reading(u5: 0.05, u7: 0.81, reset_7d: 36.hours.from_now)).value

    assert_in_delta 0.8 * 0.19 + 0.2 * 0.95, spent, 0.001
    assert_operator 1.0 - spent, :>=, AccountRebalanceService::MIN_GAIN
  end

  test "weekly usage about to be refunded counts as headroom" do
    far = score(reading(u7: 0.81, reset_7d: 36.hours.from_now)).value
    soon = score(reading(u7: 0.81, reset_7d: 6.hours.from_now)).value

    # 6h of a 24h horizon: 75% of the used week comes back.
    assert_in_delta 0.8 * (0.19 + 0.81 * 0.75) + 0.2, soon, 0.001
    assert_operator soon, :>, far
  end

  test "a window with no reset time gets no relief" do
    assert_in_delta 0.6, score(reading(u7: 0.5, reset_7d: nil)).value, 0.0001
  end

  test "an account with no reading has no score and is not eligible" do
    s = score(nil)

    assert_nil s.value
    assert_not s.eligible?
    assert_equal "no quota reading yet", s.ineligible_reason
  end

  test "a stale reading is not eligible" do
    s = score(reading(at: 3.hours.ago))

    assert_not s.eligible?
    assert_match(/older than/, s.ineligible_reason)
  end

  test "a spent window is not eligible" do
    assert_equal "5-hour window spent", score(reading(u5: 1.0)).ineligible_reason
    assert_equal "7-day window spent", score(reading(u7: 1.0)).ineligible_reason
  end

  test "an account that is not active is not eligible" do
    snapshot = reading
    @account.update!(status: :needs_reauth)

    assert_not score(snapshot).eligible?
  end
end
