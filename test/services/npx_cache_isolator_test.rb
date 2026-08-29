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

  # --------------------------------------------------------------------------
  # Per-config cache decisions
  #
  # #cache_dirs_for is the function that closed zimmer#595: before it, only a
  # colliding server was given a cache at all and everything else fell through to
  # npm's host-shared `~/.npm/_npx`. Every npx entry must now get an answer.
  # --------------------------------------------------------------------------

  test "answers for every npx server, sharing the clone cache unless the server collides" do
    servers = {
      "solo" => npx_entry("solo-pkg@latest"),
      "twin-a" => npx_entry("shared-pkg@latest"),
      "twin-b" => npx_entry("shared-pkg@latest")
    }

    dirs = NpxCacheIsolator.cache_dirs_for(servers, "/clone")

    assert_equal "/clone/.npm-cache", dirs["solo"]
    assert_equal "/clone/.npm-cache/isolated/twin-a", dirs["twin-a"]
    assert_equal "/clone/.npm-cache/isolated/twin-b", dirs["twin-b"]
    assert_equal %w[solo twin-a twin-b], dirs.keys, "answers come back in config order"
  end

  # The gap that let a server reach `~/.npm/_npx`: #cache_key returns nil when it
  # cannot read a package spec, so such an entry is never "colliding" — but it is
  # still an npx invocation and still installs somewhere. It gets the shared cache.
  test "gives an npx server whose package spec is unreadable the shared clone cache" do
    servers = {
      "no-args" => { "command" => "npx", "args" => [] },
      "nil-args" => { "command" => "npx" },
      "flags-only" => { "command" => "npx", "args" => [ "-y" ] }
    }

    dirs = NpxCacheIsolator.cache_dirs_for(servers, "/clone")

    assert_equal [ "/clone/.npm-cache" ] * 3, dirs.values_at("no-args", "nil-args", "flags-only")
  end

  test "answers for no entry that is not an npx invocation" do
    servers = {
      "http" => { "type" => "http", "url" => "https://example.com/mcp" },
      "other-binary" => { "command" => "/usr/local/bin/thing", "args" => [ "--serve" ] },
      "wrapped-npx" => { "command" => "sh", "args" => [ "-c", "npx -y some-pkg@latest" ] },
      "absolute-npx" => { "command" => "/usr/bin/npx", "args" => [ "-y", "some-pkg@latest" ] },
      "malformed" => "not-a-hash"
    }

    assert_empty NpxCacheIsolator.cache_dirs_for(servers, "/clone")
  end

  test "recognizes an npx invocation regardless of whether its package spec parses" do
    assert NpxCacheIsolator.npx_entry?("command" => "npx", "args" => [ "-y", "pkg" ])
    assert NpxCacheIsolator.npx_entry?("command" => "npx")
    assert_not NpxCacheIsolator.npx_entry?("command" => "npm", "args" => [ "exec", "pkg" ])
    assert_not NpxCacheIsolator.npx_entry?("url" => "https://example.com/mcp")
    assert_not NpxCacheIsolator.npx_entry?(nil)
  end

  test "names the clone cache the isolated roots nest inside" do
    shared = NpxCacheIsolator.shared_cache_dir("/clone")

    assert_equal "/clone/.npm-cache", shared
    assert NpxCacheIsolator.cache_dir_for("/clone", "any").start_with?(shared + File::SEPARATOR),
      "an isolated root must never resolve to the shared cache this class exists to keep it off"
  end

  private

  def npx_entry(spec)
    { "command" => "npx", "args" => [ "-y", "--prefix", "/tmp", spec ] }
  end
end
