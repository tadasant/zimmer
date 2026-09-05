# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# PiAirBridge writes the config that makes a Pi session's AIR hooks and plugins
# actually run. Nothing else does: `air prepare pi` ignores hook entries outright
# and honors a plugin only as composition sugar for its skills, so if these files
# are wrong a session's hooks exist in the database and nowhere Pi will look.
class PiAirBridgeTest < ActiveSupport::TestCase
  # AirCatalogService resolves with `--no-scope`, so Zimmer's catalog ids are bare.
  HOOK = "git-push-ci-reminder"
  PLUGIN = "ci-workflow"

  setup do
    @session = sessions(:active_session)
    @session.update!(agent_runtime: "pi", catalog_hooks: [], catalog_plugins: [])
    @working_dir = "/clone"
    @fs = MockFileSystemAdapter.new
  end

  # === The hooks the session named directly ===

  test "writes the session's selected hooks into an index keyed on their short ids" do
    @session.update!(catalog_hooks: [ HOOK ])
    write!

    entry = hooks_index.fetch("git-push-ci-reminder")
    assert_equal HooksConfig.find(HOOK).absolute_path, entry["path"]
    assert entry["title"].present?
  end

  # The extension activates every hook in an index it loads — it has no roots
  # concept to filter on — so the index IS the selection.
  test "a hook the session did not select is not in the index" do
    write!

    assert_empty hooks_index
  end

  test "the hooks air config names the generated index and nothing else" do
    write!

    assert_equal [ "./hooks.json" ], json(PiAirBridge.hooks_air_path(@working_dir))["hooks"]
  end

  test "an unknown hook id is dropped rather than raised on" do
    @session.update_column(:catalog_hooks, [ HOOK, "gone-from-the-catalog" ])

    assert_nothing_raised { write! }
    assert_equal [ "git-push-ci-reminder" ], hooks_index.keys
  end

  # === The hooks a selected plugin bundles ===

  test "a selected plugin's bundled hooks go into the plugin index, not the direct one" do
    @session.update!(catalog_plugins: [ PLUGIN ])
    write!

    assert_empty hooks_index
    assert_equal [ "git-push-ci-reminder" ], plugin_hooks_index.keys
  end

  # Both extensions dispatch their own hooks. A hook reachable through both would
  # be spawned twice for every event it matches.
  test "a hook selected directly AND bundled by a selected plugin is not run twice" do
    @session.update!(catalog_hooks: [ HOOK ], catalog_plugins: [ PLUGIN ])
    write!

    assert_empty hooks_index, "the plugin already runs it; pi-hooks must not run it too"
    assert_equal [ "git-push-ci-reminder" ], plugin_hooks_index.keys
  end

  # === The plugin index ===

  test "writes the selected plugin inline, with its hook references rewritten" do
    @session.update!(catalog_plugins: [ PLUGIN ])
    write!

    entry = plugins_index.fetch("ci-workflow")
    assert_equal [ "*" ], entry["default_in_roots"]
    assert_equal [ "@local/git-push-ci-reminder" ], entry["hooks"]
    assert entry["title"].present?
  end

  # No `path` key is what makes the entry authoritative: the extension reads a
  # `.plugin/plugin.json` from disk only when the index entry points at one, and
  # that manifest declares skills and MCP servers this runtime must not activate
  # here (see the two tests below).
  test "the plugin entry carries no path, so the on-disk manifest is not consulted" do
    @session.update!(catalog_plugins: [ PLUGIN ])
    write!

    assert_not plugins_index.fetch("ci-workflow").key?("path")
  end

  # `air prepare pi` already merges a plugin's skills into the activation set and
  # installs them under .pi/skills/. Contributing them again would offer Pi the
  # same skill twice.
  test "plugin skills are left to air prepare" do
    @session.update!(catalog_plugins: [ PLUGIN ])
    write!

    assert_equal [], plugins_index.fetch("ci-workflow")["skills"]
    assert PluginsConfig.find(PLUGIN).skills.any?, "fixture must bundle a skill to make this real"
  end

  # PiMcpConfigPostProcessor writes every plugin-bundled server into .mcp.json
  # with secret resolution and retargeting. pi-mcp-adapter merges both files by
  # name, so letting the extension write its own copy under the qualified name
  # would start a second copy of every plugin server.
  test "plugin MCP servers are left to the MCP post-processor" do
    plugin_id = "screenshots-videos"
    @session.update!(catalog_plugins: [ plugin_id ])
    write!

    assert PluginsConfig.find(plugin_id).mcp_servers.any?,
      "fixture must bundle a server to make this real"
    assert_equal [], plugins_index.fetch("screenshots-videos")["mcp_servers"]
    assert_nil json(File.join(@working_dir, ".pi", "zimmer-air", "pi-plugins.air.json"))["mcp"]
  end

  # A plugin whose bundled hook the catalog no longer knows must not leave a
  # dangling reference in a catalog Zimmer generated itself — the extension would
  # report it as "bundled hook … is not in any hooks index" on every session.
  test "a plugin does not reference a bundled hook the generated index dropped" do
    @session.update!(catalog_plugins: [ PLUGIN ])
    HooksConfig.stubs(:find).returns(nil)
    write!

    assert_empty plugin_hooks_index
    assert_equal [], plugins_index.fetch("ci-workflow")["hooks"]
  end

  test "an unknown plugin id is dropped rather than raised on" do
    @session.update_column(:catalog_plugins, [ "gone-from-the-catalog" ])

    assert_nothing_raised { write! }
    assert_empty plugins_index
  end

  # === Shadowing discovery ===

  # Both extensions fall back to `./air.json` in the working directory, which is a
  # clone of whatever repository the session works on. Writing the files
  # unconditionally is what lets PiRuntimeAdapter always name them.
  test "every file is written even when the session selects nothing" do
    write!

    [ "hooks.json", "pi-hooks.air.json", "plugin-hooks.json", "plugins.json",
     "pi-plugins.air.json" ].each do |name|
      path = File.join(@working_dir, ".pi", "zimmer-air", name)
      assert @fs.exists?(path), "expected #{name} to be written"
    end
  end

  test "rewriting after the selection changes converges rather than accumulating" do
    @session.update!(catalog_hooks: [ HOOK ])
    write!
    assert_equal [ "git-push-ci-reminder" ], hooks_index.keys

    @session.update!(catalog_hooks: [])
    PiAirBridge.new(session: @session, working_directory: @working_dir, file_system: @fs).write!

    assert_empty hooks_index
  end

  # === The spawn environment ===

  test "spawn_env names both generated configs once they exist" do
    write!

    env = PiAirBridge.spawn_env(@working_dir, file_system: @fs)
    assert_equal PiAirBridge.hooks_air_path(@working_dir), env["PI_HOOKS_AIR"]
    assert_equal PiAirBridge.plugins_air_path(@working_dir), env["PI_PLUGINS_CONFIG"]
  end

  # Pointing PI_PLUGINS_CONFIG at a missing file makes the extension throw and
  # fall back to discovery — the exact behavior the variable exists to prevent.
  test "spawn_env is empty when the bridge has not run" do
    assert_empty PiAirBridge.spawn_env(@working_dir, file_system: @fs)
  end

  private

  def write!
    PiAirBridge.new(session: @session, working_directory: @working_dir, file_system: @fs).write!
  end

  def json(path)
    JSON.parse(@fs.read(path))
  end

  def hooks_index
    json(File.join(@working_dir, ".pi", "zimmer-air", "hooks.json"))
  end

  def plugin_hooks_index
    json(File.join(@working_dir, ".pi", "zimmer-air", "plugin-hooks.json"))
  end

  def plugins_index
    json(File.join(@working_dir, ".pi", "zimmer-air", "plugins.json"))
  end
end
