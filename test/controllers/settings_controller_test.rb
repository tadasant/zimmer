# frozen_string_literal: true

require "test_helper"

class SettingsControllerTest < ActionDispatch::IntegrationTest
  test "should get show" do
    get settings_url
    assert_response :success
  end

  test "should render settings page with correct title" do
    get settings_url
    assert_select "h1", "Settings"
  end

  test "should have back link to sessions index" do
    get settings_url
    assert_select "a[href=?]", root_path
  end

  test "should have notifications section" do
    get settings_url
    assert_select "h2", "Notifications"
  end

  test "should have push subscription controller on the page" do
    get settings_url
    assert_select "[data-controller='push-subscription']"
  end

  test "should have toggle target for push notifications" do
    get settings_url
    assert_select "[data-push-subscription-target='toggle']"
  end

  # Session Defaults Section
  test "should have session defaults section with an editable form" do
    get settings_url
    assert_select "h2", "Session Defaults"
    assert_select "form[action=?]", app_settings_path
    assert_select "select[name='app_setting[default_runtime]']"
    assert_select "[data-controller='runtime-select']"
    assert_select "[data-controller='model-select']"
    assert_select "input[type=submit][value=?]", "Save session defaults"
  end

  # Experimental Section — first-class settings first, then a data-driven row per
  # registered experimental extension (keyed on its id).
  test "should have experimental section with the MCP tool search toggle" do
    get settings_url
    assert_select "h2", "Experimental"
    assert_select "form[action=?]", app_settings_path
    assert_select "input[type=checkbox][name='app_setting[mcp_tool_search_enabled]']"
    assert_select "input[type=submit][value=?]", "Save experimental settings"
  end

  test "the MCP tool search toggle renders checked by default and unchecked when off" do
    AppSetting.delete_all

    get settings_url
    assert_select "input[name='app_setting[mcp_tool_search_enabled]'][checked]"

    AppSetting.create!(mcp_tool_search_enabled: false)
    get settings_url
    assert_select "input[name='app_setting[mcp_tool_search_enabled]'][checked]", count: 0
    assert_select "input[type=checkbox][name='app_setting[mcp_tool_search_enabled]']"
  ensure
    AppSetting.delete_all
  end

  # The banner names the recommended state, and MCP tool search is the one row
  # whose recommendation is ON — so an inverted comparison in the shared partial
  # would label the deviating setting as the recommended one, which is worse than
  # no label at all.
  test "the MCP tool search banner marks ON as the recommended default and OFF as a deviation" do
    AppSetting.delete_all

    get settings_url
    assert_select "#experimental-settings", text: /MCP tool search is\s+ON \(recommended default\)/

    AppSetting.create!(mcp_tool_search_enabled: false)
    get settings_url
    assert_select "#experimental-settings", text: /MCP tool search is\s+OFF\./
    assert_select "#experimental-settings", text: /MCP tool search is\s+OFF \(recommended default\)/, count: 0
  ensure
    AppSetting.delete_all
  end

  # The mirrored case: an extension's recommendation is its own default_enabled?,
  # which is OFF — so the same partial has to label the opposite state.
  test "an experimental extension banner marks its own default as recommended" do
    Zimmer::ExtensionRegistry.register(Class.new(Zimmer::Extension) do
      def id = "fake_experiment"
      def title = "Fake experiment"
    end.new)
    AppSetting.delete_all

    get settings_url
    assert_select "#experimental-settings", text: /Fake experiment is\s+OFF \(recommended default\)/

    AppSetting.editable.tap { |s| s.set_extension_enabled("fake_experiment", true) }.save!
    get settings_url
    assert_select "#experimental-settings", text: /Fake experiment is\s+ON\./
    assert_select "#experimental-settings", text: /Fake experiment is\s+ON \(recommended default\)/, count: 0
  ensure
    AppSetting.delete_all
    Zimmer::ExtensionRegistry.reset!
    Zimmer::ExtensionRegistry.register_builtins!
  end

  test "renders a row for each registered experimental extension" do
    ext = Class.new(Zimmer::Extension) do
      def id = "fake_experiment"
      def title = "Fake experiment"
    end.new
    Zimmer::ExtensionRegistry.register(ext)

    get settings_url
    assert_select "input[type=checkbox][name='app_setting[extensions][fake_experiment]']"
  ensure
    Zimmer::ExtensionRegistry.reset!
    Zimmer::ExtensionRegistry.register_builtins!
  end

  # The spot gate moved to /quotas, where the windows it reads are reported.
  test "should not render the spot gate" do
    get settings_url
    assert_select "#spot-gate", count: 0
    assert_select "h2", text: "Spot vs priority", count: 0
  end

  # Catalog Pins Section
  test "should have catalog pins section with an editable form" do
    skip "Requires a remote (github://) catalog; Zimmer default catalog is local-only."
    get settings_url
    assert_select "h2", "Catalog Pins"
    # form_with method: :patch renders a POST form with a hidden _method override.
    assert_select "form[action=?]", catalog_pins_path
    assert_select "input[name='pins[][ref]']"
    assert_select "input[type=submit][value=?]", "Save catalog pins"
  end

  # Deployment Information Section
  test "should have deployment information section" do
    get settings_url
    assert_select "h2", "Deployment Information"
  end

  test "should display git information" do
    get settings_url
    assert_select "h3", "Git"
    assert_select "dt", "Commit SHA"
    assert_select "dt", "Branch"
  end

  test "should display environment information" do
    get settings_url
    assert_select "h3", "Environment"
    assert_select "dt", "Rails Environment"
    assert_select "dt", "Ruby Version"
    assert_select "dt", "Rails Version"
  end

  test "should display mcp servers section" do
    get settings_url
    assert_select "h3", "MCP Servers"
    assert_select "details summary", /View full configuration.*servers/
  end

  test "should show server count in mcp configuration" do
    get settings_url
    server_count = ServersConfig.names.count
    assert_select "details summary", /#{server_count} servers/
  end

  test "should display agent roots section" do
    get settings_url
    assert_select "h3", "Agent Roots"
    assert_select "details summary", /View full configuration.*agent roots/
  end

  test "should show agent roots count" do
    get settings_url
    agent_roots_count = AgentRootsConfig.names.count
    assert_select "details summary", /#{agent_roots_count} agent roots/
  end

  test "should display skills section" do
    get settings_url
    assert_select "h3", "Skills"
    assert_select "details summary", /View full configuration.*skills/
  end

  test "should show skills count" do
    get settings_url
    skills_count = SkillsConfig.names.count
    assert_select "details summary", /#{skills_count} skills/
  end

  # Test routing
  test "should route GET /settings to settings#show" do
    assert_routing(
      { method: :get, path: "/settings" },
      { controller: "settings", action: "show" }
    )
  end
end
