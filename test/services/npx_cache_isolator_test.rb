# frozen_string_literal: true

require "test_helper"

# Tests for NpxCacheIsolator — the collision detector behind the per-server npm
# cache that stops two MCP servers running the same `npx` package from racing to
# populate one `_npx/<hash>` directory.
#
# The cache key it computes has to agree with npx's own, which keys purely on the
# sorted package-spec list. That equivalence is verified against the real binary
# in the PR's verification notes; these tests pin the parsing that feeds it.
class NpxCacheIsolatorTest < ActiveSupport::TestCase
  # --------------------------------------------------------------------------
  # Package-spec extraction
  # --------------------------------------------------------------------------

  test "reads the package spec from the first positional argument" do
    assert_equal [ "onepassword-mcp-server@latest" ],
      NpxCacheIsolator.package_specs([ "-y", "onepassword-mcp-server@latest" ])
  end

  test "skips the value of npx flags that take one" do
    # A catalog entry that carries `--prefix /tmp` puts "/tmp" exactly where a
    # naive parser would read the package name.
    assert_equal [ "onepassword-mcp-server@latest" ],
      NpxCacheIsolator.package_specs([ "-y", "--prefix", "/tmp", "onepassword-mcp-server@latest" ])
  end

  test "reads explicit --package specs and ignores the command that follows" do
    assert_equal [ "cowsay@1.6.0" ],
      NpxCacheIsolator.package_specs([ "-y", "--package", "cowsay@1.6.0", "--", "node", "--version" ])
    assert_equal [ "cowsay@1.6.0" ],
      NpxCacheIsolator.package_specs([ "-y", "--package=cowsay@1.6.0", "node", "--version" ])
  end

  test "ignores the server's own arguments after the package spec" do
    assert_equal [ "@modelcontextprotocol/server-filesystem" ],
      NpxCacheIsolator.package_specs([ "-y", "@modelcontextprotocol/server-filesystem", "/srv", "--readonly" ])
  end

  test "returns nothing for an argument list with no package at all" do
    assert_empty NpxCacheIsolator.package_specs([ "-y" ])
    assert_empty NpxCacheIsolator.package_specs([])
    assert_empty NpxCacheIsolator.package_specs(nil)
  end

  # --------------------------------------------------------------------------
  # Collision detection
  # --------------------------------------------------------------------------

  test "names both servers when two entries run the same npx package" do
    servers = {
      "1password-tadas-rw" => npx_entry("onepassword-mcp-server@latest"),
      "1password-pulsemcp-rw" => npx_entry("onepassword-mcp-server@latest"),
      "context7" => npx_entry("@upstash/context7-mcp@latest")
    }

    assert_equal %w[1password-tadas-rw 1password-pulsemcp-rw],
      NpxCacheIsolator.colliding_server_names(servers)
  end

  test "names nothing when every npx server runs a different package" do
    servers = {
      "context7" => npx_entry("@upstash/context7-mcp@latest"),
      "playwright" => npx_entry("@playwright/mcp@latest")
    }

    assert_empty NpxCacheIsolator.colliding_server_names(servers)
  end

  # Two entries pinned to different versions install into different `_npx`
  # directories, so there is nothing to race and nothing to isolate.
  test "treats differently-versioned specs of one package as distinct" do
    servers = {
      "pinned" => npx_entry("cowsay@1.6.0"),
      "latest" => npx_entry("cowsay@latest")
    }

    assert_empty NpxCacheIsolator.colliding_server_names(servers)
  end

  test "ignores non-npx and HTTP entries" do
    servers = {
      "zimmer" => { "url" => "https://zimmer.example.com/mcp", "headers" => {} },
      "local-a" => { "command" => "node", "args" => [ "server.js" ] },
      "local-b" => { "command" => "node", "args" => [ "server.js" ] }
    }

    assert_empty NpxCacheIsolator.colliding_server_names(servers)
  end

  # --------------------------------------------------------------------------
  # Cache directory
  # --------------------------------------------------------------------------

  test "gives each colliding server a distinct cache directory under the clone" do
    first = NpxCacheIsolator.cache_dir_for("/clone", "1password-tadas-rw")
    second = NpxCacheIsolator.cache_dir_for("/clone", "1password-pulsemcp-rw")

    assert_not_equal first, second
    assert_equal "/clone/.npm-cache/isolated/1password-tadas-rw", first
    # Nested under the clone's existing .npm-cache so CacheClearService's
    # `**/.npm-cache` sweep still reclaims it.
    assert first.start_with?("/clone/.npm-cache/")
  end

  test "sanitizes a server name that is not filesystem-safe" do
    assert_equal "/clone/.npm-cache/isolated/weird_name_1",
      NpxCacheIsolator.cache_dir_for("/clone", "weird/name 1")
  end

  private

  def npx_entry(spec)
    { "command" => "npx", "args" => [ "-y", "--prefix", "/tmp", spec ] }
  end
end
