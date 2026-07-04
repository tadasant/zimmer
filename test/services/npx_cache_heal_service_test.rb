# frozen_string_literal: true

require "test_helper"

class NpxCacheHealServiceTest < ActiveSupport::TestCase
  setup do
    @temp_dir = Dir.mktmpdir("npx_heal_test")
    @original_home = ENV["HOME"]
    ENV["HOME"] = @temp_dir

    # Mirror the production layout: ~/.agent-orchestrator/clones/<clone>/<subdir>
    @working_directory = File.join(
      @temp_dir, ".agent-orchestrator", "clones", "pulsemcp-main-abc",
      "agents", "agent-roots", "tadas-groceries"
    )
    @npx_dir = File.join(@working_directory, ".npm-cache", "_npx")
    FileUtils.mkdir_p(@npx_dir)

    @logger = Logger.new(File::NULL)
  end

  teardown do
    ENV["HOME"] = @original_home
    FileUtils.rm_rf(@temp_dir) if @temp_dir && File.exist?(@temp_dir)
  end

  # Build the combined error string the way McpLogPollerService persists it:
  # the root-cause stderr lines joined together, ending with "Connection failed".
  def good_eggs_error(hash)
    cache = File.join(@npx_dir, hash, "node_modules")
    [
      "Error: Cannot find module 'ajv'",
      "Require stack: - #{cache}/ajv-formats/dist/limit.js " \
      "- #{cache}/ajv-formats/dist/index.js code: 'MODULE_NOT_FOUND'",
      "Connection failed after 2045ms: MCP error -32000: Connection closed"
    ].join(" | ")
  end

  def make_hash_dir(hash)
    dir = File.join(@npx_dir, hash)
    FileUtils.mkdir_p(File.join(dir, "node_modules", "ajv-formats"))
    File.write(File.join(dir, "node_modules", "ajv-formats", "package.json"), "{}")
    dir
  end

  # The real ERR_UNSUPPORTED_DIR_IMPORT crash signature persisted by AO for the
  # agent-orchestrator-mcp-server `zod/v4` failure (see AO session 8162). Node's
  # ESM loader aborts when an import resolves to a bare directory.
  def dir_import_error(hash)
    cache = File.join(@npx_dir, hash, "node_modules")
    [
      "Starting connection with timeout of 180000ms",
      "Server stderr: node:internal/modules/esm/resolve:263",
      "Error [ERR_UNSUPPORTED_DIR_IMPORT]: Directory import '#{cache}/zod/v4' " \
      "is not supported resolving ES modules imported from " \
      "'#{cache}/@modelcontextprotocol/sdk/dist/esm/types.js'",
      "code: 'ERR_UNSUPPORTED_DIR_IMPORT',",
      "url: 'file://#{cache}/zod/v4'",
      "Connection failed after 1436ms: MCP error -32000: Connection closed"
    ].join("\n")
  end

  test "removes the specific _npx hash tree named in a MODULE_NOT_FOUND error" do
    hash = "49a1f4c1ceebda27"
    dir = make_hash_dir(hash)
    other = make_hash_dir("deadbeefdeadbeef")

    failed = [ { "name" => "good-eggs", "error" => good_eggs_error(hash) } ]

    result = NpxCacheHealService.heal_from_failures(
      failed_servers: failed, working_directory: @working_directory, logger: @logger
    )

    assert result[:healed]
    assert_includes result[:removed_paths], dir
    refute File.exist?(dir), "corrupt hash tree should be removed"
    assert File.exist?(other), "unrelated hash tree should be left intact"
  end

  test "removes the _npx hash tree named in an ERR_UNSUPPORTED_DIR_IMPORT (zod/v4) error" do
    hash = "a5c0f8a8df975b78"
    dir = make_hash_dir(hash)
    other = make_hash_dir("deadbeefdeadbeef")

    failed = [ { "name" => "agent-orchestrator-prod-sessions", "error" => dir_import_error(hash) } ]

    result = NpxCacheHealService.heal_from_failures(
      failed_servers: failed, working_directory: @working_directory, logger: @logger
    )

    assert result[:healed], "an ERR_UNSUPPORTED_DIR_IMPORT referencing _npx must trigger healing"
    assert_includes result[:removed_paths], dir
    refute File.exist?(dir), "corrupt hash tree should be removed"
    assert File.exist?(other), "unrelated hash tree should be left intact"
  end

  test "is a no-op for an ERR_UNSUPPORTED_DIR_IMPORT that does not reference an _npx cache" do
    # Same ESM directory-import crash, but from a server whose modules live
    # outside the per-clone npx cache — healing must not over-match and wipe.
    failed = [ { "name" => "some-local-server",
                 "error" => "Error [ERR_UNSUPPORTED_DIR_IMPORT]: Directory import " \
                            "'/opt/app/node_modules/zod/v4' is not supported resolving ES modules " \
                            "code: 'ERR_UNSUPPORTED_DIR_IMPORT'" } ]

    result = NpxCacheHealService.heal_from_failures(
      failed_servers: failed, working_directory: @working_directory, logger: @logger
    )

    refute result[:healed], "an ESM dir-import error with no _npx reference must NOT trigger healing"
    assert_empty result[:removed_paths]
  end

  test "is a no-op when the error is not a module-resolution failure" do
    dir = make_hash_dir("49a1f4c1ceebda27")
    failed = [ { "name" => "good-eggs", "error" => "Connection timed out after 30000ms" } ]

    result = NpxCacheHealService.heal_from_failures(
      failed_servers: failed, working_directory: @working_directory, logger: @logger
    )

    refute result[:healed]
    assert_empty result[:removed_paths]
    assert File.exist?(dir), "cache must be untouched for non-module errors"
  end

  test "is a no-op for a module error that does not reference an _npx cache" do
    failed = [ { "name" => "some-server",
                 "error" => "Error: Cannot find module './missing' code: 'MODULE_NOT_FOUND'" } ]

    result = NpxCacheHealService.heal_from_failures(
      failed_servers: failed, working_directory: @working_directory, logger: @logger
    )

    refute result[:healed]
    assert_empty result[:removed_paths]
  end

  test "falls back to clearing the per-clone _npx dir when no hash path is parseable" do
    make_hash_dir("49a1f4c1ceebda27")
    # References _npx + MODULE_NOT_FOUND but with no absolute hash path (e.g. truncated log)
    failed = [ { "name" => "good-eggs",
                 "error" => "Cannot find module 'ajv' from the _npx cache code: 'MODULE_NOT_FOUND'" } ]

    result = NpxCacheHealService.heal_from_failures(
      failed_servers: failed, working_directory: @working_directory, logger: @logger
    )

    assert result[:healed]
    assert_includes result[:removed_paths], @npx_dir
    refute File.exist?(@npx_dir), "whole per-clone _npx dir should be cleared as fallback"
  end

  test "recovers the specific hash when only a bare _npx/<hash> token is present" do
    hash = "49a1f4c1ceebda27"
    dir = make_hash_dir(hash)
    other = make_hash_dir("deadbeefdeadbeef")
    # No absolute path in the log — just a relativized `_npx/<hash>` token. The
    # fallback must rebuild the single corrupt dir, not evict the whole cache.
    failed = [ { "name" => "good-eggs",
                 "error" => "Cannot find module 'ajv' in _npx/#{hash}/node_modules code: 'MODULE_NOT_FOUND'" } ]

    result = NpxCacheHealService.heal_from_failures(
      failed_servers: failed, working_directory: @working_directory, logger: @logger
    )

    assert result[:healed]
    assert_includes result[:removed_paths], dir
    refute File.exist?(dir), "the recovered hash tree should be removed"
    assert File.exist?(other), "unrelated hash trees must survive the targeted fallback"
  end

  test "refuses to remove paths outside the clones base dir" do
    outside = File.join(@temp_dir, "evil", ".npm-cache", "_npx", "49a1f4c1ceebda27")
    FileUtils.mkdir_p(outside)
    failed = [ { "name" => "x",
                 "error" => "Cannot find module 'ajv' #{outside}/node_modules/ajv code: 'MODULE_NOT_FOUND'" } ]

    result = NpxCacheHealService.heal_from_failures(
      failed_servers: failed, working_directory: @working_directory, logger: @logger
    )

    refute result[:healed]
    assert File.exist?(outside), "paths outside the clones base dir must not be deleted"
  end

  test "refuses to delete a path that uses .. to escape the clones base" do
    # Raw string literally begins with the clones base, but `..` segments resolve
    # it out of the clones tree. The guard must expand the path before checking.
    clones_base = File.join(@temp_dir, ".agent-orchestrator", "clones")
    raw = File.join(clones_base, "pulsemcp-main-abc", "..", "..", "..",
      "evil", ".npm-cache", "_npx", "deadbeefdeadbeef")
    target = File.expand_path(raw)
    FileUtils.mkdir_p(target)
    failed = [ { "name" => "x",
                 "error" => "Cannot find module 'ajv' #{raw}/node_modules code: 'MODULE_NOT_FOUND'" } ]

    result = NpxCacheHealService.heal_from_failures(
      failed_servers: failed, working_directory: @working_directory, logger: @logger
    )

    refute result[:healed]
    assert File.exist?(target), "a .. traversal escaping the clones base must not be deleted"
  end

  test "does not fall back to clearing _npx when working_directory is blank" do
    failed = [ { "name" => "good-eggs",
                 "error" => "Cannot find module 'ajv' from the _npx cache MODULE_NOT_FOUND" } ]

    result = NpxCacheHealService.heal_from_failures(
      failed_servers: failed, working_directory: nil, logger: @logger
    )

    refute result[:healed]
  end

  test "handles multiple failed servers and dedups removed paths" do
    hash_a = "49a1f4c1ceebda27"
    hash_b = "0011223344556677"
    dir_a = make_hash_dir(hash_a)
    dir_b = make_hash_dir(hash_b)

    failed = [
      { "name" => "good-eggs", "error" => good_eggs_error(hash_a) },
      { "name" => "good-eggs-again", "error" => good_eggs_error(hash_a) },
      { "name" => "notion", "error" => good_eggs_error(hash_b) }
    ]

    result = NpxCacheHealService.heal_from_failures(
      failed_servers: failed, working_directory: @working_directory, logger: @logger
    )

    assert result[:healed]
    assert_equal [ dir_a, dir_b ].sort, result[:removed_paths].sort
    refute File.exist?(dir_a)
    refute File.exist?(dir_b)
  end

  test "npx_cache_resolution_failure? requires both a marker and an _npx reference" do
    # MODULE_NOT_FOUND family
    assert NpxCacheHealService.npx_cache_resolution_failure?("MODULE_NOT_FOUND in /x/_npx/abc")
    assert NpxCacheHealService.npx_cache_resolution_failure?("Cannot find module 'ajv' _npx")
    # ESM directory-import / subpath-export family
    assert NpxCacheHealService.npx_cache_resolution_failure?("ERR_UNSUPPORTED_DIR_IMPORT /x/_npx/abc/zod/v4")
    assert NpxCacheHealService.npx_cache_resolution_failure?("ERR_PACKAGE_PATH_NOT_EXPORTED /x/_npx/abc/pkg")
    assert NpxCacheHealService.npx_cache_resolution_failure?("is not supported resolving ES modules in _npx")
    # Marker present but no _npx reference — must not match
    refute NpxCacheHealService.npx_cache_resolution_failure?("MODULE_NOT_FOUND somewhere else")
    refute NpxCacheHealService.npx_cache_resolution_failure?("ERR_UNSUPPORTED_DIR_IMPORT /opt/app/zod/v4")
    # _npx present but no resolution marker — must not match
    refute NpxCacheHealService.npx_cache_resolution_failure?("connection timed out _npx")
  end
end
