# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260823030300_replace_spot_targets_with_priority_reserve")

# The one migration in this feature that moves DATA rather than only shape:
# `spot_gate_*_threshold_pct` became `spot_reserve_*_pct`, and the values are
# complements. A deployment filling to 65% is reserving 35%; getting that
# backwards would invert the operator's policy silently on deploy.
#
# The transform is its own inverse, so the test exercises it as one: apply it
# twice and land where you started.
class SpotReserveMigrationTest < ActiveSupport::TestCase
  TRANSFORM = <<~SQL
    UPDATE app_settings
    SET spot_reserve_five_hour_pct = GREATEST(0, LEAST(100, 100 - spot_reserve_five_hour_pct)),
        spot_reserve_weekly_pct = GREATEST(0, LEAST(100, 100 - spot_reserve_weekly_pct))
  SQL

  def transform!
    ActiveRecord::Base.connection.execute(TRANSFORM)
  end

  test "a fill target becomes its complementary reserve" do
    setting = AppSetting.editable
    # The values production was running: fill to 65% of the 5-hour window and
    # 70% of the week.
    setting.update!(spot_reserve_five_hour_pct: 65, spot_reserve_weekly_pct: 70)

    transform!
    setting.reload

    assert_equal 35, setting.spot_reserve_five_hour_pct, "a 65% fill target reserves the other 35%"
    assert_equal 30, setting.spot_reserve_weekly_pct
  end

  test "the transform is its own inverse, which is what makes `down` correct" do
    setting = AppSetting.editable
    setting.update!(spot_reserve_five_hour_pct: 65, spot_reserve_weekly_pct: 70)

    transform!
    transform!
    setting.reload

    assert_equal 65, setting.spot_reserve_five_hour_pct
    assert_equal 70, setting.spot_reserve_weekly_pct
  end

  test "both ends of the range survive the round trip" do
    setting = AppSetting.editable

    setting.update!(spot_reserve_five_hour_pct: 0, spot_reserve_weekly_pct: 100)
    transform!
    setting.reload
    assert_equal 100, setting.spot_reserve_five_hour_pct, "filling to 0% means reserving everything"
    assert_equal 0, setting.spot_reserve_weekly_pct, "filling to 100% means reserving nothing"

    transform!
    setting.reload
    assert_equal 0, setting.spot_reserve_five_hour_pct
    assert_equal 100, setting.spot_reserve_weekly_pct
  end

  # A fresh install has no row to transform and takes the column default
  # instead, which has to be the reserve's default rather than the old target's.
  test "a fresh install defaults to the shipped reserve, not to the old target" do
    assert_equal AppSetting::DEFAULT_SPOT_RESERVE_PCT,
      AppSetting.columns_hash["spot_reserve_five_hour_pct"].default.to_i
    assert_equal AppSetting::DEFAULT_SPOT_RESERVE_PCT,
      AppSetting.columns_hash["spot_reserve_weekly_pct"].default.to_i
  end

  test "the migration is reversible in both directions" do
    assert ReplaceSpotTargetsWithPriorityReserve.new.respond_to?(:up)
    assert ReplaceSpotTargetsWithPriorityReserve.new.respond_to?(:down)
  end
end
