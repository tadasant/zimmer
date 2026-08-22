# frozen_string_literal: true

require "test_helper"

class AppSettingsControllerTest < ActionDispatch::IntegrationTest
  # The extensions param is handled generically off the registry, and Zimmer
  # ships no built-in extension today, so these register a fake one. That is the
  # honest test of the handler: it must key on whatever is registered.
  class FakeSettingsExtension < Zimmer::Extension
    def id = "fake_experiment"
    def title = "Fake experiment"
  end

  setup do
    AppSetting.delete_all
    Zimmer::ExtensionRegistry.register(FakeSettingsExtension.new)
  end

  teardown do
    Zimmer::ExtensionRegistry.reset!
    Zimmer::ExtensionRegistry.register_builtins!
  end

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

  test "turns MCP tool search off via its own toggle" do
    patch app_settings_path, params: { app_setting: { mcp_tool_search_enabled: "0" } }

    assert_redirected_to settings_path
    refute AppSetting.current.mcp_tool_search_enabled?
  end

  test "turns MCP tool search back on" do
    AppSetting.create!(mcp_tool_search_enabled: false)

    patch app_settings_path, params: { app_setting: { mcp_tool_search_enabled: "1" } }

    assert_redirected_to settings_path
    assert AppSetting.current.mcp_tool_search_enabled?
  end

  test "saving runtime + model leaves MCP tool search untouched" do
    AppSetting.create!(mcp_tool_search_enabled: false)

    patch app_settings_path, params: { app_setting: { default_runtime: "claude_code", default_model: "opus" } }

    assert_redirected_to settings_path
    setting = AppSetting.current
    refute setting.mcp_tool_search_enabled?
    assert_equal "claude_code", setting.default_runtime
  end

  test "toggling MCP tool search does not clobber runtime + model defaults" do
    AppSetting.create!(default_runtime: "codex", default_model: "gpt-5.5")

    patch app_settings_path, params: { app_setting: { mcp_tool_search_enabled: "0" } }

    assert_redirected_to settings_path
    setting = AppSetting.current
    refute setting.mcp_tool_search_enabled?
    assert_equal "codex", setting.default_runtime
    assert_equal "gpt-5.5", setting.default_model
  end

  test "enables an extension via the extensions param" do
    patch app_settings_path, params: { app_setting: { extensions: { "fake_experiment" => "1" } } }

    assert_redirected_to settings_path
    assert AppSetting.current.extension_enabled?("fake_experiment")
  end

  test "disables an extension via the hidden-field fallback" do
    AppSetting.create!.tap { |s| s.set_extension_enabled("fake_experiment", true); s.save! }

    patch app_settings_path, params: { app_setting: { extensions: { "fake_experiment" => "0" } } }

    assert_redirected_to settings_path
    refute AppSetting.current.extension_enabled?("fake_experiment")
  end

  test "toggling an extension does not clobber existing runtime + model defaults" do
    AppSetting.create!(default_runtime: "codex", default_model: "gpt-5.5")

    patch app_settings_path, params: { app_setting: { extensions: { "fake_experiment" => "1" } } }

    assert_redirected_to settings_path
    setting = AppSetting.current
    assert setting.extension_enabled?("fake_experiment")
    assert_equal "codex", setting.default_runtime
    assert_equal "gpt-5.5", setting.default_model
  end

  test "saving runtime + model leaves extension enablement untouched" do
    AppSetting.create!.tap { |s| s.set_extension_enabled("fake_experiment", true); s.save! }

    patch app_settings_path, params: { app_setting: { default_runtime: "claude_code", default_model: "opus" } }

    assert_redirected_to settings_path
    setting = AppSetting.current
    assert setting.extension_enabled?("fake_experiment")
    assert_equal "claude_code", setting.default_runtime
  end

  test "a submit applies each registered extension's checkbox value independently" do
    # The per-id toggle path is exercised by enabling the registered extension in
    # one submit and disabling it in the next. An unregistered id co-submitted
    # alongside is ignored, proving the handler keys strictly on the registered
    # set rather than blindly persisting.
    patch app_settings_path, params: {
      app_setting: { extensions: { "fake_experiment" => "1", "not_a_real_extension" => "1" } }
    }
    assert_redirected_to settings_path
    setting = AppSetting.current
    assert setting.extension_enabled?("fake_experiment")
    refute setting.extension_enabled?("not_a_real_extension")

    patch app_settings_path, params: {
      app_setting: { extensions: { "fake_experiment" => "0" } }
    }
    refute AppSetting.current.extension_enabled?("fake_experiment")
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
