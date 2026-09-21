# frozen_string_literal: true

require "test_helper"

# MCP parity for Settings → Zimmer plugins: search_external_apps /
# action_external_app do what ExternalAppsController does, and are reachable only
# by naming the opt-in `external_apps` group.
class Mcp::Tools::ExternalAppsAdminTest < ActiveSupport::TestCase
  setup do
    @context = Mcp::Context.new(tool_groups: "external_apps", base_url: "http://test.host")
    @trigger = triggers(:enabled_slack_trigger)
  end

  def action(**args)
    Mcp::Tools::ActionExternalApp.new(context: @context).call(args.deep_stringify_keys)
  end

  def search(**args)
    Mcp::Tools::SearchExternalApps.new(context: @context).call(args.deep_stringify_keys)
  end

  test "the tools are opt-in: only external_apps names the write, and external_apps_readonly only the read" do
    assert_equal %w[search_external_apps action_external_app], Mcp::Registry.tools_for([ "external_apps" ]).map(&:tool_name)
    assert_equal %w[search_external_apps], Mcp::Registry.tools_for([ "external_apps_readonly" ]).map(&:tool_name)
    [ Mcp::Registry.parse_groups(nil), [ "self_session" ], [ "triggers" ], [ "sessions" ] ].each do |groups|
      assert_not_includes Mcp::Registry.tools_for(groups).map(&:tool_name), "action_external_app", groups.inspect
    end
  end

  test "create, then mint a key that authenticates only as the plugin, then search it back without the secret" do
    created = action(action: "create", name: "Housing search", description: "Vetting", trigger_ids: [ @trigger.id ])
    app_id = created[:external_app][:id]
    assert_equal [ @trigger.id ], created[:external_app][:triggers].map { |t| t[:id] }
    assert created[:external_app][:enabled]

    minted = action(action: "mint_key", id: app_id)
    secret = minted[:key][:secret]
    assert secret.start_with?(ApiKey::MINTED_PREFIX)
    assert ApiKey.authenticate(secret, grant: ApiKey::EXTERNAL_APP_GRANT).authenticated?
    assert_not ApiKey.authenticate(secret).authenticated?, "a plugin key must not open the full API"

    found = search(id: app_id)[:external_apps].sole
    assert_equal [ minted[:key][:id] ], found[:keys].map { |k| k[:id] }
    assert_not_includes found.to_json, secret
  end

  test "update replaces the allowlist, toggles enabled, and refuses a bad id without changing anything" do
    app_id = action(action: "create", name: "Housing search", trigger_ids: [ @trigger.id ])[:external_app][:id]
    other = triggers(:disabled_slack_trigger)

    updated = action(action: "update", id: app_id, trigger_ids: [ other.id ], enabled: false)
    assert_equal [ other.id ], updated[:external_app][:triggers].map { |t| t[:id] }
    assert_equal false, updated[:external_app][:enabled]

    error = assert_raises(Mcp::ToolError) { action(action: "update", id: app_id, trigger_ids: [ 999_999_999 ], name: "Renamed") }
    assert_includes error.message, "999999999"
    app = ExternalApp.find(app_id)
    assert_equal [ other.id ], app.trigger_ids
    assert_equal "Housing search", app.name, "the rename rolled back with the bad allowlist"
  end

  test "revoke_key revokes only this plugin's keys, and delete removes the plugin and its keys" do
    app_id = action(action: "create", name: "Housing search")[:external_app][:id]
    key_id = action(action: "mint_key", id: app_id)[:key][:id]

    assert_raises(Mcp::ToolError) { action(action: "revoke_key", id: app_id, key_id: ApiKey.create!(name: "other", source: "minted", token_digest: "x" * 64).id) }
    action(action: "revoke_key", id: app_id, key_id: key_id)
    assert_predicate ApiKey.find(key_id), :revoked?

    action(action: "delete", id: app_id)
    assert_nil ExternalApp.find_by(id: app_id)
    assert_nil ApiKey.find_by(id: key_id)
  end

  test "a connection restricted to other agent roots cannot allowlist, mint for or see a plugin outside them" do
    app_id = action(action: "create", name: "Housing search", trigger_ids: [ @trigger.id ])[:external_app][:id]
    restricted = Mcp::Context.new(tool_groups: "external_apps", allowed_agent_roots: "some-other-root", base_url: "http://test.host")
    restricted_action = ->(**args) { Mcp::Tools::ActionExternalApp.new(context: restricted).call(args.deep_stringify_keys) }

    assert_raises(Mcp::ToolError) { restricted_action.(action: "create", name: "Sneaky", trigger_ids: [ @trigger.id ]) }
    assert_nil ExternalApp.find_by(name: "Sneaky")
    assert_raises(Mcp::ToolError) { restricted_action.(action: "mint_key", id: app_id) }
    assert_raises(Mcp::ToolError) { restricted_action.(action: "update", id: app_id, trigger_ids: []) }
    assert_equal [ @trigger.id ], ExternalApp.find(app_id).trigger_ids
    assert_empty Mcp::Tools::SearchExternalApps.new(context: restricted).call({})[:external_apps]

    # Inside its roots it works as usual.
    allowed = Mcp::Context.new(tool_groups: "external_apps", allowed_agent_roots: @trigger.agent_root_name, base_url: "http://test.host")
    assert Mcp::Tools::ActionExternalApp.new(context: allowed).call("action" => "mint_key", "id" => app_id)[:key][:secret]
  end

  test "a duplicate name and an unknown action are readable errors" do
    action(action: "create", name: "Housing search")
    assert_raises(ActiveRecord::RecordInvalid) { action(action: "create", name: "housing search") }
    assert_raises(Mcp::ToolError) { action(action: "explode") }
  end
end
