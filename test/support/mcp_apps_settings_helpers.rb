# frozen_string_literal: true

# Writing the MCP Apps switches from a test, without assuming the settings row
# does not exist yet.
#
# `app_settings` is a singleton table — `AppSetting#only_one_row` refuses a
# second row — so `AppSetting.create!` in a `setup` block is only safe in a
# worker where nothing has made one. That is true when the file runs on its own
# and false in the full suite, which is the worst possible split: green locally,
# red in CI, and the failure names a validation rather than the test that leaked
# the row. `AppSetting.editable` is the singleton accessor — the existing row, or
# a new one — so these read and write whichever is there.
module McpAppsSettingsHelpers
  # @param enabled [Boolean] the deployment-wide master switch
  # @param servers [Array<String>] the per-server allowlist
  # @return [AppSetting]
  def enable_mcp_apps(enabled: true, servers: [ "notion" ])
    setting = AppSetting.editable
    setting.mcp_apps_enabled = enabled
    setting.mcp_apps_allowed_servers = servers
    setting.save!
    setting
  end

  # The singleton row, for a test that wants to change one field of it.
  def mcp_apps_setting
    AppSetting.editable
  end
end
