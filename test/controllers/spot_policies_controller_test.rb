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

  # The preemption switch is separate from the gate's own so an operator can stop
  # the one part of the policy that interrupts work already underway without
  # turning the gate off and letting the whole fleet run unpaced.
  test "the preemption switch is written by the spot policy form" do
    AppSetting.editable.update!(spot_gating_enabled: true, spot_preemption_enabled: true)

    patch spot_policy_path, params: { app_setting: {
      spot_gating_enabled: "1", spot_preemption_enabled: "0"
    } }

    setting = AppSetting.current
    refute setting.spot_preemption_enabled
    assert setting.spot_gating_enabled, "the gate is untouched"
  end

  test "the starvation age ceiling is written by the spot policy form, and zero is a real value" do
    AppSetting.editable.update!(spot_starvation_age_ceiling_hours: 24)

    patch spot_policy_path, params: { app_setting: { spot_starvation_age_ceiling_hours: "48" } }
    assert_equal 48, AppSetting.current.spot_starvation_age_ceiling_hours

    patch spot_policy_path, params: { app_setting: { spot_starvation_age_ceiling_hours: "0" } }
    assert_equal 0, AppSetting.current.spot_starvation_age_ceiling_hours
    assert_nil AppSetting.current.spot_starvation_age_ceiling

    patch spot_policy_path, params: { app_setting: { spot_starvation_age_ceiling_hours: "-1" } }
    assert_equal 0, AppSetting.current.spot_starvation_age_ceiling_hours, "an out-of-range value is refused"
    assert_match(/not saved/, flash[:alert])
  end

  # A hand-built PATCH that omits the key must leave the column as it was rather
  # than casting nil into a NOT NULL column — the same rule every other field on
  # this form follows.
  test "a request that omits the preemption switch leaves it alone" do
    AppSetting.editable.update!(spot_preemption_enabled: false)

    patch spot_policy_path, params: { app_setting: { spot_reserve_weekly_pct: "30" } }

    refute AppSetting.current.spot_preemption_enabled
    assert_equal 30, AppSetting.current.spot_reserve_weekly_pct
  end

  # The audit line is what makes a silent revert reconstructible. A change made
  # here has to be distinguishable from one an agent made through
  # `action_spot_policy`, because "which surface moved this" is the first question
  # anyone asks and nothing else on the row answers it.
  test "a change made through this form is recorded, naming the form" do
    AppSetting.editable.update!(spot_max_concurrent_sessions: 12)

    entries = capture_log_entries do
      patch spot_policy_path, params: { app_setting: { spot_max_concurrent_sessions: "8" } }
    end

    line = entries.map(&:last).find { |message| message.include?("[FleetPolicy]") }
    assert line, "the form moved the cap and nothing recorded it"
    assert_includes line, "spot_max_concurrent_sessions 12 -> 8"
    assert_includes line, SpotPoliciesController::CHANGE_SOURCE
  end
end
