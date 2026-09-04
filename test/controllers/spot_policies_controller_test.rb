# frozen_string_literal: true

require "test_helper"

# The spot gate policy form, which posts from the card on /inference.
class SpotPoliciesControllerTest < ActionDispatch::IntegrationTest
  setup { AppSetting.delete_all }

  test "persists the gate toggle and both thresholds" do
    patch spot_policy_path, params: { app_setting: {
      spot_gating_enabled: "1",
      spot_reserve_five_hour_pct: "65",
      spot_reserve_weekly_pct: "70"
    } }

    assert_redirected_to inference_path(anchor: "spot-gate")
    assert_match(/Spot policy updated/, flash[:notice])
    setting = AppSetting.current
    assert setting.spot_gating_enabled
    assert_equal 65, setting.spot_reserve_five_hour_pct
    assert_equal 70, setting.spot_reserve_weekly_pct
  end

  test "the unchecked toggle arrives as the hidden 0 and turns gating off" do
    AppSetting.editable.update!(spot_gating_enabled: true)

    patch spot_policy_path, params: { app_setting: {
      spot_gating_enabled: "0",
      spot_reserve_five_hour_pct: "80",
      spot_reserve_weekly_pct: "80"
    } }

    assert_redirected_to inference_path(anchor: "spot-gate")
    assert_not AppSetting.current.spot_gating_enabled
  end

  test "an out-of-range threshold is refused without persisting it" do
    AppSetting.editable.update!(spot_reserve_five_hour_pct: 80)

    patch spot_policy_path, params: { app_setting: {
      spot_gating_enabled: "1",
      spot_reserve_five_hour_pct: "140",
      spot_reserve_weekly_pct: "80"
    } }

    assert_redirected_to inference_path(anchor: "spot-gate")
    assert_match(/not saved/, flash[:alert])
    assert_equal 80, AppSetting.current.spot_reserve_five_hour_pct
  end

  # A submit that carries only some of the three leaves the rest as they were,
  # rather than assigning nil to a NOT NULL column and 500ing. The card's form
  # always posts all three, so this is about a request built by hand.
  test "a submit missing the toggle leaves gating as it was" do
    AppSetting.editable.update!(spot_gating_enabled: true, spot_reserve_weekly_pct: 80)

    patch spot_policy_path, params: { app_setting: { spot_reserve_weekly_pct: "55" } }

    assert_redirected_to inference_path(anchor: "spot-gate")
    setting = AppSetting.current
    assert setting.spot_gating_enabled, "an omitted toggle must not turn gating off"
    assert_equal 55, setting.spot_reserve_weekly_pct
  end

  # The fleet cap round-trips through the same form as the two targets — it is a
  # spot control, so it lives beside them rather than on the settings page.
  test "persists the max concurrent sessions cap" do
    patch spot_policy_path, params: { app_setting: {
      spot_gating_enabled: "1",
      spot_reserve_five_hour_pct: "80",
      spot_reserve_weekly_pct: "80",
      spot_max_concurrent_sessions: "4"
    } }

    assert_redirected_to inference_path(anchor: "spot-gate")
    assert_equal 4, AppSetting.current.spot_max_concurrent_sessions
  end

  test "a cap of zero is refused — that is what turning the gate off is for" do
    AppSetting.editable.update!(spot_max_concurrent_sessions: 10)

    patch spot_policy_path, params: { app_setting: { spot_max_concurrent_sessions: "0" } }

    assert_match(/not saved/, flash[:alert])
    assert_equal 10, AppSetting.current.spot_max_concurrent_sessions
  end

  test "a scalar app_setting param is refused rather than raising" do
    patch spot_policy_path, params: { app_setting: "nonsense" }

    assert_redirected_to inference_path(anchor: "spot-gate")
  end

  # The session-defaults form on /settings posts to its own endpoint. Neither
  # form carries the other's fields, so a submit from either leaves the other's
  # settings alone — in both directions.
  test "saving session defaults leaves the spot policy alone" do
    AppSetting.editable.update!(
      spot_gating_enabled: true, spot_reserve_five_hour_pct: 65
    )

    patch app_settings_path, params: { app_setting: { default_runtime: "codex", default_model: "gpt-5.5" } }

    setting = AppSetting.current
    assert setting.spot_gating_enabled
    assert_equal 65, setting.spot_reserve_five_hour_pct
  end

  test "saving the spot policy leaves the session defaults and extensions alone" do
    AppSetting.editable.update!(default_runtime: "codex", default_model: "gpt-5.5")
    AppSetting.editable.tap { |s| s.set_extension_enabled("some_experiment", true) }.save!

    patch spot_policy_path, params: { app_setting: {
      spot_gating_enabled: "1",
      spot_reserve_five_hour_pct: "70",
      spot_reserve_weekly_pct: "70"
    } }

    setting = AppSetting.current
    assert_equal "codex", setting.default_runtime
    assert_equal "gpt-5.5", setting.default_model
    assert AppSetting.extension_enabled?("some_experiment")
  end
end
