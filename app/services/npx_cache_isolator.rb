# frozen_string_literal: true

# Decides which npm cache each `npx`-launched MCP server in a config is pointed at:
# the clone's own cache always, and a per-server root within it for two servers
# that run the SAME package and would otherwise race to populate one tree.
#
# There are two failures here, at two scales.
#
# **Off the clone entirely.** `NPM_CONFIG_CACHE=<working_dir>/.npm-cache` used to be
# set only on the agent process (ClaudeSpawnEnv#configure_mcp_env) and inherited from
# there. Codex never sets it: CodexRuntimeAdapter's spawn env has no such variable,
# and Codex builds each stdio server's environment from a fixed whitelist plus exactly
# what the entry's own `env`/`env_vars` name — so under Codex every npx MCP server
# resolved against npm's user-level `~/.npm/_npx`. That cache is shared by every
# session on the host and sits outside every clone-scoped mechanism Zimmer has:
# NpxCacheHealService and CacheClearService walk the clone, and NpxBinExecutableGuard
# walks it and only runs on the Claude path anyway. `ENOTEMPTY … rename` on
# `/home/rails/.npm/_npx/a4bcc792b5155234/node_modules/playwright` is what two
# concurrent sessions installing into one host-wide tree looks like (zimmer#595).
#
# Inheritance is the wrong mechanism for a config generator to depend on either way,
# so the cache location is written into every npx entry's own `env` table, where no
# runtime's environment rules can drop it.
#
# **Colliding inside one clone.** npx keys its install directory purely on the
# package spec:
#
#   _npx/<sha512(specs.sort.join("\n"))[0,16]>
#
# so two entries whose command is the byte-identical `npx -y <pkg>@latest` resolve
# to the same `_npx/<hash>` directory inside that one clone cache and, on a cold
# cache, both try to install into it at once. The loser dies mid-extraction:
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
# Only *colliding* servers get a root of their own. The common case — every npx
# server running a different package — shares the single per-clone cache, so
# tarballs are still downloaded once and the disk footprint is unchanged. The
# cost of isolation is one duplicated download of the shared package, paid
# concurrently, which is strictly cheaper than the failed connect + 30s retry it
# replaces.
#
# Both answers live under `<clone>/.npm-cache`, which is what keeps
# NpxCacheHealService's `_npx` globs and CacheClearService's `**/.npm-cache` sweep
# able to reach them.
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
  #
  # This list cannot be exhaustive — npx accepts any npm config flag in
  # `--foo bar` form — and it does not need to be. The key it feeds is a
  # *grouping* key, so getting one wrong is bounded either way: two servers that
  # did not need isolating get it (one duplicated download) or two that did are
  # left sharing a cache (today's behavior). It is never unsafe, only imprecise.
  VALUE_FLAGS = %w[--prefix -c --call --userconfig --cache --node-options --shell].freeze

  # npx flags that name a package explicitly instead of inferring it from the
  # first positional argument. npx builds its cache key from these when present.
  PACKAGE_FLAGS = %w[-p --package].freeze

  module_function

  # Whether an entry launches its server through `npx`, and so has an npm cache
  # worth pointing anywhere. Matched exactly, and by the same predicate #cache_key
  # uses, so the pinning and the collision detection can never disagree about
  # which entries are in scope.
  #
  # Exactly `npx` and nothing else: `sh -c "npx …"`, an absolute `/usr/bin/npx`,
  # `npm exec`, `bunx` and `pnpm dlx` are all out of scope and keep whatever cache
  # they inherit. Every catalog entry Zimmer ships uses the bare form, and widening
  # the match would mean guessing which argument of a wrapper is the package.
  def npx_entry?(entry)
    entry.is_a?(Hash) && entry["command"] == "npx"
  end

  # The npm cache the whole clone shares — the one ClaudeSpawnEnv#configure_mcp_env
  # also names, and the parent of every isolated root below.
  #
  # @param working_directory [String] the session's clone working directory
  # @return [String] absolute path
  def shared_cache_dir(working_directory)
    File.join(working_directory, ".npm-cache")
  end

  # Where each npx server in a config should keep its npm cache: its own isolated
  # root when it shares a package with another server here, the clone's shared
  # cache otherwise. Every npx entry gets an answer — a server that collides with
  # nothing still must not be left to npm's host-wide default.
  #
  # @param servers [Hash] server name => entry
  # @param working_directory [String] the session's clone working directory
  # @return [Hash{String => String}] server name => absolute cache path, in config order
  def cache_dirs_for(servers, working_directory)
    colliding = colliding_server_names(servers)
    shared = shared_cache_dir(working_directory)

    servers.each_with_object({}) do |(name, entry), dirs|
      next unless npx_entry?(entry)

      dirs[name] = colliding.include?(name) ? cache_dir_for(working_directory, name) : shared
    end
  end

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
    return nil unless npx_entry?(entry)

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
        # End of npx's own flags. With an explicit --package already read, what
        # follows is the command; otherwise the next argument is the package.
        break if specs.any?

        index += 1
      elsif PACKAGE_FLAGS.include?(arg)
        specs << args[index + 1].to_s
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

  # A filesystem-safe directory name for a server. `.` and `..` are rejected
  # rather than sanitized: both resolve back to a shared parent, which would put
  # the server on the very cache this class exists to keep it off. Every other
  # name collapses to a plain segment inside the clone.
  def sanitize(server_name)
    sanitized = server_name.to_s.gsub(/[^A-Za-z0-9._-]/, "_")
    return "unnamed" if sanitized.blank? || sanitized.delete(".").empty?

    sanitized
  end
end
