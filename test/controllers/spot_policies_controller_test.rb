# frozen_string_literal: true

require "test_helper"

# The spot gate policy form, which posts from the card on /quotas.
class SpotPoliciesControllerTest < ActionDispatch::IntegrationTest
  setup { AppSetting.delete_all }

  test "persists the gate toggle and both thresholds" do
    patch spot_policy_path, params: { app_setting: {
      spot_gating_enabled: "1",
      spot_gate_five_hour_threshold_pct: "65",
      spot_gate_weekly_threshold_pct: "70"
    } }

    assert_redirected_to quotas_path(anchor: "spot-gate")
    assert_match(/Spot policy updated/, flash[:notice])
    setting = AppSetting.current
    assert setting.spot_gating_enabled
    assert_equal 65, setting.spot_gate_five_hour_threshold_pct
    assert_equal 70, setting.spot_gate_weekly_threshold_pct
  end

  test "the unchecked toggle arrives as the hidden 0 and turns gating off" do
    AppSetting.editable.update!(spot_gating_enabled: true)

    patch spot_policy_path, params: { app_setting: {
      spot_gating_enabled: "0",
      spot_gate_five_hour_threshold_pct: "80",
      spot_gate_weekly_threshold_pct: "80"
    } }

    assert_redirected_to quotas_path(anchor: "spot-gate")
    assert_not AppSetting.current.spot_gating_enabled
  end

  test "an out-of-range threshold is refused without persisting it" do
    AppSetting.editable.update!(spot_gate_five_hour_threshold_pct: 80)

    patch spot_policy_path, params: { app_setting: {
      spot_gating_enabled: "1",
      spot_gate_five_hour_threshold_pct: "140",
      spot_gate_weekly_threshold_pct: "80"
    } }

    assert_redirected_to quotas_path(anchor: "spot-gate")
    assert_match(/not saved/, flash[:alert])
    assert_equal 80, AppSetting.current.spot_gate_five_hour_threshold_pct
  end

  # The session-defaults form on /settings posts to its own endpoint. Neither
  # form carries the other's fields, so a submit from either leaves the other's
  # settings alone.
  test "saving session defaults leaves the spot policy alone" do
    AppSetting.editable.update!(
      spot_gating_enabled: true, spot_gate_five_hour_threshold_pct: 65
    )

    patch app_settings_path, params: { app_setting: { default_runtime: "codex", default_model: "gpt-5.5" } }

    setting = AppSetting.current
    assert setting.spot_gating_enabled
    assert_equal 65, setting.spot_gate_five_hour_threshold_pct
  end
end
