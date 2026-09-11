# frozen_string_literal: true

require "test_helper"

# MCP parity for the Settings page: the Session Defaults and Experimental forms
# AppSettingsController writes, reachable by an agent through get_app_settings /
# action_app_settings — with the same validation, and nowhere a connection has
# not asked for it.
class Mcp::Tools::AppSettingsTest < ActiveSupport::TestCase
  # Zimmer ships no built-in extension today, so this registers one, the way
  # AppSettingsControllerTest does: the honest test of a handler keyed off the
  # registry is that it takes whatever is registered and nothing else.
  class FakeExperimentExtension < Zimmer::Extension
    def id = "fake_experiment"
    def title = "Fake experiment"
  end

  # Registered but not experimental: the page renders no toggle for it, so the
  # tool has no key for it either.
  class FakeStableExtension < Zimmer::Extension
    def id = "fake_stable"
    def experimental? = false
  end

  setup do
    AppSetting.delete_all
    Zimmer::ExtensionRegistry.register(FakeExperimentExtension.new)
    Zimmer::ExtensionRegistry.register(FakeStableExtension.new)
    @context = Mcp::Context.new(base_url: "http://test.host")
  end

  teardown do
    Zimmer::ExtensionRegistry.reset!
    Zimmer::ExtensionRegistry.register_builtins!
  end

  def get_settings(context: @context)
    Mcp::Tools::GetAppSettings.new(context: context).call({})
  end

  def action(context: @context, **args)
    Mcp::Tools::ActionAppSettings.new(context: context).call(args.stringify_keys)
  end

  # --- registry ---------------------------------------------------------------

  test "both tools are in the settings group, and settings_readonly drops the write" do
    assert_equal %w[get_app_settings action_app_settings], Mcp::Registry.tools_for(%w[settings]).map(&:tool_name)
    assert_equal %w[get_app_settings], Mcp::Registry.tools_for(%w[settings_readonly]).map(&:tool_name)
  end

  # The gate-self-modification facet, pinned: a connection that did not ask for
  # `settings` — the unscoped `zimmer` surface and the self_session server
  # injected into every session above all — reaches neither tool.
  test "no connection that did not name settings reaches either tool" do
    tools = %w[get_app_settings action_app_settings]
    groups_without_settings = Mcp::Registry::VALID_GROUPS.reject { |g| g.start_with?("settings") }

    [ Mcp::Registry.parse_groups(nil), [ "self_session" ], [ "health" ], [ "sessions", "self_session" ],
      groups_without_settings ].each do |groups|
      names = Mcp::Registry.tools_for(groups).map(&:tool_name)
      assert_empty names & tools, "#{groups.join(',')} reaches #{(names & tools).join(', ')}"
    end
  end

  # --- read -------------------------------------------------------------------

  test "get_app_settings marks every value at its shipped default on a fresh row" do
    output = get_settings

    assert_includes output, "**Runtime:** `claude_code` (Claude Code) — shipped default, no override set"
    assert_includes output, "**Model:** `#{ModelCatalog.default_for('claude_code')}` — that runtime's own default, no override set"
    assert_match(/MCP tool search\*\* \(`mcp_tool_search`\): \*\*on\*\* — shipped default\./, output)
    assert_match(/\(`session_scoped_credentials`\): \*\*off\*\* — shipped default\./, output)
    assert_match(/Fake experiment\*\* \(`extension\.fake_experiment`\): \*\*off\*\* — shipped default\./, output)
  end

  test "get_app_settings reports an override as one, with the shipped default beside it" do
    AppSetting.create!(default_runtime: "codex", default_model: "gpt-5.5", mcp_tool_search_enabled: false)

    output = get_settings

    assert_includes output, "**Runtime:** `codex` (Codex) — operator override"
    assert_includes output, "**Model:** `gpt-5.5` — operator override"
    assert_match(/\(`mcp_tool_search`\): \*\*off\*\* — operator override; shipped default is on\./, output)
  end

  test "get_app_settings lists every runtime with its models, so a caller can pick a valid pair" do
    output = get_settings

    RuntimeRegistry.registered_runtimes.each do |runtime|
      ModelCatalog.model_ids_for(runtime).each { |model| assert_includes output, "`#{model}`" }
    end
  end

  # --- set_session_defaults ---------------------------------------------------

  test "set_session_defaults persists a valid pair and echoes before and after" do
    result = action(action: "set_session_defaults", runtime: "codex", model: "gpt-5.5")

    setting = AppSetting.current
    assert_equal "codex", setting.default_runtime
    assert_equal "gpt-5.5", setting.default_model
    assert_includes result, "**Before:** runtime `claude_code` (shipped default), model `#{ModelCatalog.default_for('claude_code')}` (runtime default)"
    assert_includes result, "**After:** runtime `codex` (override), model `gpt-5.5` (override)"
    assert_equal 1, AppSetting.count
  end

  test "set_session_defaults changes only the half it is given" do
    AppSetting.create!(default_runtime: "claude_code", default_model: "opus")

    action(action: "set_session_defaults", model: "sonnet")

    setting = AppSetting.current
    assert_equal "claude_code", setting.default_runtime
    assert_equal "sonnet", setting.default_model
  end

  test "set_session_defaults clears an override with an empty string, as the form's blank input does" do
    AppSetting.create!(default_runtime: "codex", default_model: "gpt-5.5")

    action(action: "set_session_defaults", runtime: "", model: "")

    setting = AppSetting.current
    assert_nil setting.default_runtime
    assert_nil setting.default_model
  end

  test "set_session_defaults clears only the model, keeping the runtime" do
    AppSetting.create!(default_runtime: "codex", default_model: "gpt-5.5")

    action(action: "set_session_defaults", model: "")

    setting = AppSetting.current
    assert_equal "codex", setting.default_runtime
    assert_nil setting.default_model
  end

  test "set_session_defaults that moves nothing says so and writes no audit line" do
    AppSetting.create!(default_runtime: "codex", default_model: "gpt-5.5")

    result = nil
    entries = capture_log_entries { result = action(action: "set_session_defaults", runtime: "codex", model: "gpt-5.5") }

    assert_equal "Session defaults unchanged: runtime `codex` (override), model `gpt-5.5` (override).", result
    assert_empty entries.select { |_severity, message| message.include?("[AppSettings]") }
  end

  # The model's validation, reached through the tool: the pair the Settings form
  # refuses is refused here, and nothing is written.
  test "set_session_defaults refuses a model the runtime cannot run, and saves nothing" do
    error = assert_raises(Mcp::ToolError) do
      action(action: "set_session_defaults", runtime: "claude_code", model: "gpt-5.5")
    end

    assert_match(/Session defaults not saved: Default model gpt-5.5 is not available for Claude Code/, error.message)
    assert_includes error.message, "Valid models for `claude_code`: #{ModelCatalog.model_ids_for('claude_code').join(', ')}"
    assert_nil AppSetting.current.default_runtime
    assert_nil AppSetting.current.default_model
  end

  test "set_session_defaults refuses switching runtime away from a model it cannot run" do
    AppSetting.create!(default_runtime: "claude_code", default_model: "opus")

    error = assert_raises(Mcp::ToolError) { action(action: "set_session_defaults", runtime: "codex") }

    assert_match(/opus is not available for Codex/, error.message)
    assert_equal "claude_code", AppSetting.current.default_runtime
  end

  test "set_session_defaults refuses an unregistered runtime" do
    error = assert_raises(Mcp::ToolError) { action(action: "set_session_defaults", runtime: "not_a_runtime") }

    assert_match(/not_a_runtime is not a registered runtime/, error.message)
    assert_includes error.message, "Valid runtimes: #{RuntimeRegistry.registered_runtimes.join(', ')}"
    assert_nil AppSetting.current.default_runtime
  end

  test "set_session_defaults with neither half is refused rather than saved as an empty edit" do
    error = assert_raises(Mcp::ToolError) { action(action: "set_session_defaults", runtime: nil) }

    assert_match(/Nothing to change/, error.message)
    assert_equal 0, AppSetting.count
  end

  # --- set_experimental_setting -----------------------------------------------

  test "set_experimental_setting turns MCP tool search off and back on" do
    off = action(action: "set_experimental_setting", setting: "mcp_tool_search", enabled: false)
    refute AppSetting.mcp_tool_search_enabled?
    assert_includes off, "MCP tool search (`mcp_tool_search`) is now **off** (was on; shipped default on)"

    action(action: "set_experimental_setting", setting: "mcp_tool_search", enabled: true)
    assert AppSetting.mcp_tool_search_enabled?
  end

  test "set_experimental_setting reaches every AppSetting-backed toggle the page renders" do
    ExperimentalSettingsRegistry::BUILT_INS.each do |experimental|
      target = !experimental.current_value

      action(action: "set_experimental_setting", setting: experimental.key, enabled: target)

      assert_equal target, AppSetting.current.public_send(:"#{experimental.attribute}?"), experimental.key
    end
  end

  test "set_experimental_setting enables a registered experimental extension" do
    result = action(action: "set_experimental_setting", setting: "extension.fake_experiment", enabled: true)

    assert AppSetting.current.extension_enabled?("fake_experiment")
    assert_includes result, "Fake experiment (`extension.fake_experiment`) is now **on** (was off"
  end

  test "set_experimental_setting on an extension leaves every other extension's stored state alone" do
    AppSetting.create!(extension_states: { "some_other_extension" => true })

    action(action: "set_experimental_setting", setting: "extension.fake_experiment", enabled: true)

    assert_equal({ "some_other_extension" => true, "fake_experiment" => true }, AppSetting.current.extension_states)
  end

  test "set_experimental_setting refuses a registered extension the page renders no toggle for" do
    error = assert_raises(Mcp::ToolError) do
      action(action: "set_experimental_setting", setting: "extension.fake_stable", enabled: true)
    end

    assert_match(/Unknown experimental setting: extension\.fake_stable/, error.message)
    assert_equal 0, AppSetting.count
  end

  # A no-op returns before any write, so an extension's shipped default is never
  # pinned into extension_states as an explicit value.
  test "set_experimental_setting to the value it already has writes nothing and says so" do
    result = action(action: "set_experimental_setting", setting: "extension.fake_experiment", enabled: false)

    assert_includes result, "is already **off** — nothing changed"
    assert_equal 0, AppSetting.count
  end

  # The controller's "registered ids only" rule, reached from the registry: an
  # extension that is not registered has no key, so nothing can be written for it.
  test "set_experimental_setting refuses an unregistered extension and writes no junk key" do
    error = assert_raises(Mcp::ToolError) do
      action(action: "set_experimental_setting", setting: "extension.not_registered", enabled: true)
    end

    assert_match(/Unknown experimental setting: extension\.not_registered/, error.message)
    assert_includes error.message, "extension.fake_experiment"
    assert_equal 0, AppSetting.count
  end

  test "set_experimental_setting refuses a key the page does not render" do
    error = assert_raises(Mcp::ToolError) do
      action(action: "set_experimental_setting", setting: "spot_gating", enabled: true)
    end

    assert_match(/Unknown experimental setting: spot_gating\. Valid: mcp_tool_search, session_scoped_credentials/, error.message)
  end

  test "set_experimental_setting requires enabled, and writes nothing without it" do
    error = assert_raises(Mcp::ToolError) { action(action: "set_experimental_setting", setting: "mcp_tool_search") }

    assert_match(/Missing required parameter: enabled/, error.message)
    assert_equal 0, AppSetting.count
  end

  test "an unknown action is refused" do
    error = assert_raises(Mcp::ToolError) { action(action: "set_spot_gating") }
    assert_match(/Unknown action: set_spot_gating/, error.message)
  end

  # --- the audit line ---------------------------------------------------------

  test "a settings write is recorded, naming the tool, the action and the calling session" do
    context = Mcp::Context.new(base_url: "http://test.host", session_id: 4242)

    entries = capture_log_entries do
      action(context: context, action: "set_experimental_setting", setting: "mcp_tool_search", enabled: false)
    end

    severity, line = entries.find { |_severity, message| message.include?("[AppSettings]") }
    assert line, "the tool moved a setting and nothing recorded it"
    assert_equal "WARN", severity
    assert_includes line, "#{Mcp::Tools::ActionAppSettings::CHANGE_SOURCE} set_experimental_setting session #4242"
    assert_includes line, "mcp_tool_search_enabled true -> false"
  end

  test "set_session_defaults is recorded old value to new" do
    AppSetting.create!(default_model: "opus")

    entries = capture_log_entries { action(action: "set_session_defaults", model: "sonnet") }

    line = entries.map(&:last).find { |message| message.include?("[AppSettings]") }
    assert_includes line, "#{Mcp::Tools::ActionAppSettings::CHANGE_SOURCE} set_session_defaults"
    assert_includes line, 'default_model "opus" -> "sonnet"'
  end
end
