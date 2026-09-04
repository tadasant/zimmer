# frozen_string_literal: true

require "test_helper"

# The backlog top-up form, which posts from the card on /inference.
class FleetTopUpPoliciesControllerTest < ActionDispatch::IntegrationTest
  setup { AppSetting.delete_all }

  test "persists all three knobs" do
    patch fleet_top_up_policy_path, params: { app_setting: {
      fleet_idle_max_sessions: "5",
      fleet_idle_threshold_minutes: "10",
      fleet_idle_min_fire_interval_minutes: "20"
    } }

    assert_redirected_to inference_path(anchor: "fleet-top-up")
    assert_match(/Fleet top-up policy updated/, flash[:notice])
    setting = AppSetting.current
    assert_equal 5, setting.fleet_idle_max_sessions
    assert_equal 10, setting.fleet_idle_threshold_minutes
    assert_equal 20, setting.fleet_idle_min_fire_interval_minutes
  end

  # A ceiling of 0 could never be satisfied — the test is `running_sessions < ceiling` —
  # so the event would silently never fire again.
  test "a ceiling of zero is refused without persisting it" do
    AppSetting.editable.update!(fleet_idle_max_sessions: 3)

    patch fleet_top_up_policy_path, params: { app_setting: { fleet_idle_max_sessions: "0" } }

    assert_redirected_to inference_path(anchor: "fleet-top-up")
    assert_match(/not saved/, flash[:alert])
    assert_equal 3, AppSetting.current.fleet_idle_max_sessions
  end

  test "a cooldown past the ceiling is refused" do
    patch fleet_top_up_policy_path, params: { app_setting: { fleet_idle_min_fire_interval_minutes: "20000" } }

    assert_match(/not saved/, flash[:alert])
    assert_equal AppSetting::DEFAULT_FLEET_IDLE_MIN_FIRE_INTERVAL_MINUTES,
                 AppSetting.current.fleet_idle_min_fire_interval_minutes
  end

  # A hand-built PATCH that carries one field must leave the other two alone
  # rather than assigning nil to a NOT NULL column.
  test "omitted fields are left as they were" do
    AppSetting.editable.update!(fleet_idle_max_sessions: 7, fleet_idle_threshold_minutes: 9,
                                fleet_idle_min_fire_interval_minutes: 11)

    patch fleet_top_up_policy_path, params: { app_setting: { fleet_idle_max_sessions: "4" } }

    setting = AppSetting.current
    assert_equal 4, setting.fleet_idle_max_sessions
    assert_equal 9, setting.fleet_idle_threshold_minutes
    assert_equal 11, setting.fleet_idle_min_fire_interval_minutes
  end

  test "a request with no app_setting params at all is a no-op rather than a 500" do
    AppSetting.editable.update!(fleet_idle_max_sessions: 4)

    patch fleet_top_up_policy_path

    assert_redirected_to inference_path(anchor: "fleet-top-up")
    assert_equal 4, AppSetting.current.fleet_idle_max_sessions
  end
end
