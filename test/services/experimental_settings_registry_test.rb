# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

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

  test "a setting whose read fails harmlessly resolves to the shipped default" do
    # An unreadable settings row must not stop a session spawning, so the read
    # degrades through AppSetting::NULL to what the setting ships as. Note this
    # stubs the query, not AppSetting.current — current is the thing that
    # degrades, so stubbing it out would test nothing this path does.
    setting = ExperimentalSettingsRegistry.find("mcp_tool_search")
    AppSetting.stubs(:order).raises(ActiveRecord::StatementInvalid, "relation does not exist")

    assert_equal AppSetting::DEFAULT_MCP_TOOL_SEARCH_ENABLED, setting.current_value
  end

  test "a setting read inside an aborted transaction raises instead of resolving to nil" do
    # #924: this read runs inside the resume transition's transaction. Returning
    # nil there let the transition carry on across a connection Postgres had
    # already given up on, and the four statements after it each reported an
    # InFailedSqlTransaction that named nothing useful.
    setting = ExperimentalSettingsRegistry.find("mcp_tool_search")

    error = assert_raises(ActiveRecord::StatementInvalid) do
      ActiveRecord::Base.transaction(requires_new: true) do
        begin
          ActiveRecord::Base.connection.execute("SELECT no_such_column_anywhere")
        rescue ActiveRecord::StatementInvalid
          # The transaction is aborted now, exactly as it was in production.
        end

        setting.current_value
      end
    end

    assert_kind_of PG::InFailedSqlTransaction, error.cause
  end

  test "a backfillable setting knows what it was on either side of the date it landed" do
    setting = ExperimentalSettingsRegistry.find("mcp_tool_search")

    assert setting.backfillable?
    assert_equal false, setting.value_at(setting.landed_at - 1.second)
    assert_equal true, setting.value_at(setting.landed_at)
    assert_equal true, setting.value_at(setting.landed_at + 1.second)
  end
end
