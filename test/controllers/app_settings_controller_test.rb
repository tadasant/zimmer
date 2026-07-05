# frozen_string_literal: true

require "test_helper"

class AppSettingsControllerTest < ActionDispatch::IntegrationTest
  setup { AppSetting.delete_all }

  test "persists a valid runtime + model pairing as the global session default" do
    patch app_settings_path, params: { app_setting: { default_runtime: "codex", default_model: "gpt-5.5" } }

    assert_redirected_to settings_path
    assert_match(/Settings updated/, flash[:notice])
    setting = AppSetting.current
    assert_equal "codex", setting.default_runtime
    assert_equal "gpt-5.5", setting.default_model
  end

  test "updates the existing singleton row rather than inserting a second" do
    AppSetting.create!(default_runtime: "codex", default_model: "gpt-5.5")

    patch app_settings_path, params: { app_setting: { default_runtime: "claude_code", default_model: "opus" } }

    assert_redirected_to settings_path
    assert_equal 1, AppSetting.count
    assert_equal "claude_code", AppSetting.current.default_runtime
    assert_equal "opus", AppSetting.current.default_model
  end

  test "clears the global default when both fields are blank" do
    AppSetting.create!(default_runtime: "codex", default_model: "gpt-5.5")

    patch app_settings_path, params: { app_setting: { default_runtime: "", default_model: "" } }

    assert_redirected_to settings_path
    setting = AppSetting.current
    assert_nil setting.default_runtime
    assert_nil setting.default_model
  end

  test "rejects an incompatible runtime + model pairing without persisting it" do
    patch app_settings_path, params: { app_setting: { default_runtime: "claude_code", default_model: "gpt-5.5" } }

    assert_redirected_to settings_path
    assert_match(/not saved/, flash[:alert])
    setting = AppSetting.current
    assert_nil setting.default_runtime
    assert_nil setting.default_model
  end

  test "enables an extension via the extensions param" do
    patch app_settings_path, params: { app_setting: { extensions: { "mcp_tool_search" => "1" } } }

    assert_redirected_to settings_path
    assert AppSetting.current.extension_enabled?("mcp_tool_search")
  end

  test "disables an extension via the hidden-field fallback" do
    AppSetting.create!.tap { |s| s.set_extension_enabled("mcp_tool_search", true); s.save! }

    patch app_settings_path, params: { app_setting: { extensions: { "mcp_tool_search" => "0" } } }

    assert_redirected_to settings_path
    refute AppSetting.current.extension_enabled?("mcp_tool_search")
  end

  test "toggling an extension does not clobber existing runtime + model defaults" do
    AppSetting.create!(default_runtime: "codex", default_model: "gpt-5.5")

    patch app_settings_path, params: { app_setting: { extensions: { "mcp_tool_search" => "1" } } }

    assert_redirected_to settings_path
    setting = AppSetting.current
    assert setting.extension_enabled?("mcp_tool_search")
    assert_equal "codex", setting.default_runtime
    assert_equal "gpt-5.5", setting.default_model
  end

  test "saving runtime + model leaves extension enablement untouched" do
    AppSetting.create!.tap { |s| s.set_extension_enabled("mcp_tool_search", true); s.save! }

    patch app_settings_path, params: { app_setting: { default_runtime: "claude_code", default_model: "opus" } }

    assert_redirected_to settings_path
    setting = AppSetting.current
    assert setting.extension_enabled?("mcp_tool_search")
    assert_equal "claude_code", setting.default_runtime
  end

  test "a submit applies each registered extension's checkbox value independently" do
    # Zimmer ships a single built-in extension (mcp_tool_search); the per-id
    # toggle path is exercised by enabling it in one submit and disabling it in
    # the next. An unregistered id co-submitted alongside is ignored, proving the
    # handler keys strictly on the registered set rather than blindly persisting.
    patch app_settings_path, params: {
      app_setting: { extensions: { "mcp_tool_search" => "1", "not_a_real_extension" => "1" } }
    }
    assert_redirected_to settings_path
    setting = AppSetting.current
    assert setting.extension_enabled?("mcp_tool_search")
    refute setting.extension_enabled?("not_a_real_extension")

    patch app_settings_path, params: {
      app_setting: { extensions: { "mcp_tool_search" => "0" } }
    }
    refute AppSetting.current.extension_enabled?("mcp_tool_search")
  end

  test "a scalar extensions param is ignored rather than raising" do
    # A crafted submit where extensions is a scalar (not a nested hash) must not
    # blow up on #each_pair — the toggle block simply does nothing.
    patch app_settings_path, params: { app_setting: { extensions: "1" } }

    assert_redirected_to settings_path
    assert_match(/Settings updated/, flash[:notice])
  end

  test "an unregistered extension id in the extensions param is ignored" do
    patch app_settings_path, params: { app_setting: { extensions: { "not_a_real_extension" => "1" } } }

    assert_redirected_to settings_path
    assert_equal({}, AppSetting.current.extension_states)
  end
end
