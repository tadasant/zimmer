# frozen_string_literal: true

# Keeps two MCP servers that run the SAME `npx` package out of each other's npm
# cache, so they cannot race to populate it.
#
# Zimmer isolates the npm cache per clone (NPM_CONFIG_CACHE=<working_dir>/.npm-cache,
# see ClaudeSpawnEnv#configure_mcp_env). That stops one session corrupting another's
# cache — but it does nothing for two servers inside ONE session. npx keys its
# install directory purely on the package spec:
#
#   _npx/<sha512(specs.sort.join("\n"))[0,16]>
#
# so two entries whose command is the byte-identical `npx -y <pkg>@latest` resolve
# to the same `_npx/<hash>` directory and, on a cold cache, both try to install
# into it at once. The loser dies mid-extraction:
#
#   npm error code ENOTEMPTY
#   npm error syscall rename
#   npm error path  .../.npm-cache/_npx/04f14e66d79e7af4/node_modules/which
#   npm error dest  .../.npm-cache/_npx/04f14e66d79e7af4/node_modules/.which-JV7jxD8y
#
# That is not hypothetical or rare: the `zimmer-router` agent root carries both
# `1password-tadas-rw` and `1password-pulsemcp-rw`, and both run
# `npx -y onepassword-mcp-server@latest`. Every cold-clone router session is
# exposed, and it is what killed production session 4668 five seconds into its
# first turn.
#
# The fix is prevention rather than repair: when a config contains two or more
# stdio entries that resolve to the same npx install, each of them is given its
# own NPM_CONFIG_CACHE, so their `_npx/<hash>` trees are in different directories
# and there is nothing to race over. NpxCacheHealService still cleans up after a
# corruption that happens anyway (a killed install, a full disk); this stops the
# one cause Zimmer can see coming.
#
# Only *colliding* servers are isolated. The common case — every npx server
# running a different package — keeps the single shared per-clone cache, so
# tarballs are still downloaded once and the disk footprint is unchanged. The
# cost of isolation is one duplicated download of the shared package, paid
# concurrently, which is strictly cheaper than the failed connect + 30s retry it
# replaces.
#
# Runtime-agnostic: operates on the `{ "command" => ..., "args" => [...] }` shape
# shared by Claude's `.mcp.json` entries and Codex's `.codex/config.toml`
# `[mcp_servers.*]` tables.
module NpxCacheIsolator
  # The npm variable that decides where `_npx/<hash>` lives.
  NPM_CACHE_VAR = "NPM_CONFIG_CACHE"

  # Isolated caches live under the clone's existing `.npm-cache` rather than
  # beside it, so CacheClearService's `**/.npm-cache` sweep still reclaims them
  # and NpxCacheHealService's clone-scoped safety check still recognizes them.
  ISOLATED_SUBDIR = "isolated"

  # npx flags that take a separate value argument. Their value must be skipped or
  # it would be mistaken for the package spec — a catalog entry that carries, say,
  # `--prefix /tmp` would otherwise be keyed on "/tmp".
  VALUE_FLAGS = %w[--prefix -c --call --userconfig --cache --node-options --shell].freeze

  # npx flags that name a package explicitly instead of inferring it from the
  # first positional argument. npx builds its cache key from these when present.
  PACKAGE_FLAGS = %w[-p --package].freeze

  module_function

  # The names of servers that share an npx install directory with at least one
  # other server in the same config.
  #
  # @param servers [Hash] server name => entry
  # @return [Array<String>] colliding server names, in config order
  def colliding_server_names(servers)
    by_cache_key = Hash.new { |hash, key| hash[key] = [] }

    servers.each do |name, entry|
      key = cache_key(entry)
      next if key.nil?

      by_cache_key[key] << name
    end

    by_cache_key.values.select { |names| names.size > 1 }.flatten
  end

  # The directory to point one isolated server's npm cache at.
  #
  # Named after the server rather than the package so two servers running the
  # same package land in different trees — which is the entire point. The name is
  # sanitized for the filesystem; two names that sanitize to the same string would
  # simply share a cache again, i.e. degrade to today's behavior rather than to
  # something worse.
  #
  # @param working_directory [String] the session's clone working directory
  # @param server_name [String]
  # @return [String] absolute path
  def cache_dir_for(working_directory, server_name)
    File.join(working_directory, ".npm-cache", ISOLATED_SUBDIR, sanitize(server_name))
  end

  # npx's own cache key for an entry: the sorted package specs, or nil when the
  # entry is not an npx invocation (an HTTP server, a different command, or an
  # npx call we could not read a package spec out of).
  def cache_key(entry)
    return nil unless entry.is_a?(Hash)
    return nil unless entry["command"] == "npx"

    specs = package_specs(entry["args"])
    return nil if specs.empty?

    specs.sort.join("\n")
  end

  # The package specs an `npx` argument list installs, mirroring how npx itself
  # decides: every `--package`/`-p` value, or — when none is given — the first
  # positional argument (which npx treats as both the package and the binary).
  def package_specs(args)
    return [] unless args.is_a?(Array)

    specs = []
    index = 0

    while index < args.length
      arg = args[index].to_s

      if arg == "--"
        break
      elsif PACKAGE_FLAGS.include?(arg)
        specs << args[index + 1]
        index += 2
      elsif (flag = PACKAGE_FLAGS.find { |candidate| arg.start_with?("#{candidate}=") })
        specs << arg.delete_prefix("#{flag}=")
        index += 1
      elsif VALUE_FLAGS.include?(arg)
        index += 2
      elsif arg.start_with?("-")
        # A boolean flag (-y, --yes, --silent, …) or a `--flag=value` form, both
        # of which occupy a single argument.
        index += 1
      else
        # First positional argument. With no explicit --package it IS the package
        # npx installs; with one, it is the command npx runs out of that package.
        specs << arg if specs.empty?
        break
      end
    end

    specs.compact_blank
  end

  def sanitize(server_name)
    server_name.to_s.gsub(/[^A-Za-z0-9._-]/, "_")
  end
end
