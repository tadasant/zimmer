# frozen_string_literal: true

require "test_helper"

# Every change to the fleet-scheduling policy leaves a record.
#
# The settings this covers — the spot gate, the concurrency limit, the backlog
# top-up ceiling — are the ones that decide how much work the fleet does, and
# they can be moved from three separate surfaces. Until this audit line, moving
# one wrote nothing anywhere: the only symptom of a cap silently going back down
# was the fleet running slower, and the only way to reconstruct what happened was
# to read every agent transcript in the window and eliminate the rest.
class AppSettingFleetPolicyAuditTest < ActiveSupport::TestCase
  setup { AppSetting.delete_all }

  def fleet_policy_lines(entries)
    entries.select { |_severity, message| message.include?("[FleetPolicy]") }
  end

  test "a change to the concurrency limit is recorded, old value to new" do
    setting = AppSetting.editable
    setting.update!(spot_max_concurrent_sessions: 12)

    entries = capture_log_entries do
      setting.policy_change_source = "test"
      setting.update!(spot_max_concurrent_sessions: 8)
    end

    lines = fleet_policy_lines(entries)
    assert_equal 1, lines.size, "expected exactly one audit line, got #{lines.inspect}"
    severity, message = lines.first
    assert_equal "WARN", severity,
      "INFO never leaves the box — the OTel exporter ships WARN and above"
    assert_match(/spot_max_concurrent_sessions 12 -> 8/, message)
    assert_match(/changed via test/, message)
  end

  test "every operator-settable scheduling column is recorded when it moves" do
    setting = AppSetting.editable
    setting.update!(
      spot_gating_enabled: false,
      spot_reserve_five_hour_pct: 20,
      spot_reserve_weekly_pct: 20,
      spot_max_concurrent_sessions: 10,
      spot_preemption_enabled: true,
      fleet_idle_max_sessions: 3,
      fleet_idle_threshold_minutes: 5,
      fleet_idle_min_fire_interval_minutes: 60
    )

    entries = capture_log_entries do
      setting.update!(
        spot_gating_enabled: true,
        spot_reserve_five_hour_pct: 30,
        spot_reserve_weekly_pct: 40,
        spot_max_concurrent_sessions: 12,
        spot_preemption_enabled: false,
        fleet_idle_max_sessions: 12,
        fleet_idle_threshold_minutes: 7,
        fleet_idle_min_fire_interval_minutes: 10
      )
    end

    message = fleet_policy_lines(entries).map(&:last).join(" ")
    (AppSetting::FLEET_POLICY_ATTRIBUTES - [ "genesis_class_overrides" ]).each do |attribute|
      assert_includes message, attribute, "#{attribute} moved and nothing recorded it"
    end
  end

  test "a genesis reclassification is recorded" do
    setting = AppSetting.editable
    setting.save!

    entries = capture_log_entries do
      setting.set_genesis_class("web_ui", SessionGenesis::SPOT)
      setting.save!
    end

    message = fleet_policy_lines(entries).map(&:last).join(" ")
    assert_match(/genesis_class_overrides/, message)
    assert_match(/web_ui/, message)
  end

  test "a write that moves nothing in the policy is silent" do
    setting = AppSetting.editable
    setting.update!(spot_max_concurrent_sessions: 12)

    entries = capture_log_entries do
      # The pollers write these columns several times an hour. Folding them into
      # the audit would bury the handful of lines that matter.
      setting.update!(fleet_idle_since: Time.current, quota_pool_available: true)
      setting.update!(default_runtime: "codex")
    end

    assert_empty fleet_policy_lines(entries)
  end

  test "a change with no named surface is still recorded, as unattributed" do
    setting = AppSetting.editable
    setting.update!(spot_max_concurrent_sessions: 12)

    entries = capture_log_entries { setting.update!(spot_max_concurrent_sessions: 9) }

    message = fleet_policy_lines(entries).map(&:last).join(" ")
    assert_match(/changed via #{Regexp.escape(AppSetting::UNATTRIBUTED_SOURCE)}/, message)
  end

  # The coverage guard. Every field the two /inference forms and the MCP tool can
  # write has to be one the audit records — a knob added to a surface and
  # forgotten here would move silently, which is the whole bug this exists for.
  test "every field the write surfaces expose is in FLEET_POLICY_ATTRIBUTES" do
    reachable =
      SpotPoliciesController::FIELDS.map(&:to_s) +
      FleetTopUpPoliciesController::FIELDS.map(&:to_s) +
      Mcp::Tools::ActionSpotPolicy::TOP_UP_FIELDS.values.map(&:to_s)

    assert_empty reachable.uniq - AppSetting::FLEET_POLICY_ATTRIBUTES,
      "these settings can be changed but their change is not recorded"
  end
end
