# frozen_string_literal: true

require "test_helper"

class ExperimentalSettingsRegistryTest < ActiveSupport::TestCase
  test "MCP tool search is registered and reads the live setting" do
    setting = ExperimentalSettingsRegistry.find("mcp_tool_search")

    assert setting
    row = AppSetting.editable
    row.mcp_tool_search_enabled = false
    row.save!

    assert_equal false, setting.current_value

    row.mcp_tool_search_enabled = true
    row.save!

    assert_equal true, setting.current_value
  end

  test "every registered setting can be rendered as a toggle and written back" do
    # The registry is the single source for the settings form, the write path and
    # the session tagging. A setting that cannot name its own form field would be
    # togglable nowhere and tagged anyway.
    ExperimentalSettingsRegistry.all.each do |setting|
      assert setting.key.present?
      assert setting.title.present?
      assert setting.param_name.start_with?("app_setting[")
      assert setting.dom_id.present?
      next if setting.extension?

      assert AppSetting.new.respond_to?(:"#{setting.attribute}="),
        "#{setting.key} names an AppSetting column that does not exist"
    end
  end

  test "current_values is what gets written onto a session" do
    values = ExperimentalSettingsRegistry.current_values

    assert_equal ExperimentalSettingsRegistry.keys.sort, values.keys.sort
    values.each_value { |v| assert_includes [ true, false ], v }
  end

  test "a backfillable setting knows what it was on either side of the date it landed" do
    setting = ExperimentalSettingsRegistry.find("mcp_tool_search")

    assert setting.backfillable?
    assert_equal false, setting.value_at(setting.landed_at - 1.second)
    assert_equal true, setting.value_at(setting.landed_at)
    assert_equal true, setting.value_at(setting.landed_at + 1.second)
  end
end
