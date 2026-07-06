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

  # Experimental Section — data-driven from the extension registry, so each
  # registered experimental extension renders a checkbox keyed on its id.
  test "should have experimental section with the tool-search toggle" do
    get settings_url
    assert_select "h2", "Experimental"
    assert_select "form[action=?]", app_settings_path
    assert_select "input[type=checkbox][name='app_setting[extensions][mcp_tool_search]']"
    assert_select "input[type=submit][value=?]", "Save experimental settings"
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
