# frozen_string_literal: true

# Restores the execute bit on the bin shims inside a session's per-clone npm
# `_npx` cache, so an MCP server whose package ships a non-executable entrypoint
# cannot permanently orphan the session.
#
# Background (zimmer#467):
#   An `npx -y <pkg>@latest` MCP server is launched through the shim npm links at
#   `_npx/<hash>/node_modules/.bin/<name>`, a symlink to the package's entrypoint.
#   npm normally chmods that entrypoint to 0755 when it links the shim — which is
#   what makes a package that ships its bin as `-rw-r--r--` work anyway. When that
#   chmod does not land, `exec` fails with EACCES and `/bin/sh` reports:
#
#     sh: 1: onepassword-mcp-server: Permission denied
#
#   Nothing about that state is transient: the tree is fully populated and stably
#   wrong, so every retry fails identically and NpxCacheHealService's heal-by-delete
#   cannot help either. Production session 4388 was terminally orphaned three times
#   in 31 minutes and a human had to detach the server by hand.
#
#   Zimmer's own `--prefix /tmp` injection was the trigger there (it aimed npm's
#   bin-linking at a directory that does not exist on the host) and is gone. This
#   guard is the defense that does not depend on that: the missing mode bit
#   originates in the published tarball
#   (`npm pack onepassword-mcp-server@0.5.4` → `-rw-r--r-- package/build/index.js`),
#   which Zimmer does not control.
#
# Strategy: before every spawn that has MCP servers (ClaudeSpawnEnv#configure_mcp_env),
# walk the clone's `_npx/*/node_modules/.bin/*` shims, resolve each to its target,
# and add the execute bits to any target that has none. Cheap and idempotent — a
# healthy tree is a handful of `stat` calls, and a clone with no `_npx` cache yet
# (every first launch) is a single failed glob.
#
# The repair therefore lands on the launch AFTER the one that installed the broken
# package. That is the retry the MCP-failure ladder already schedules
# (AgentSessionJob#schedule_mcp_retry respawns the process), so a session that hits
# this recovers on its own instead of orphaning.
class NpxBinExecutableGuard
  # The execute bits (u+x, g+x, o+x). A target with none of them set is what
  # `exec` refuses with EACCES.
  EXECUTE_BITS = 0o111

  class << self
    # Add the execute bit to every non-executable bin target in the clone's npx cache.
    #
    # @param working_directory [String, nil] the session's clone working dir
    #   (NPM_CONFIG_CACHE lives at <working_directory>/.npm-cache)
    # @param logger [Logger] where to record repairs
    # @return [Array<String>] the target paths that were made executable
    def repair!(working_directory:, logger: Rails.logger)
      npx_dir = npx_cache_dir(working_directory)
      return [] unless npx_dir && File.directory?(npx_dir)

      repaired = shim_paths(npx_dir).filter_map { |shim| repair_shim(shim, npx_dir, logger) }

      if repaired.any?
        logger.warn(
          "[NpxBinExecutableGuard] Restored the execute bit on #{repaired.size} npx bin " \
          "target(s) under #{npx_dir}: #{repaired.join(', ')}"
        )
      end

      repaired
    rescue => e
      # Never let a best-effort repair block a spawn: the worst case without it is
      # the pre-existing failure mode, and the worst case with a raise here is a
      # session that cannot start at all.
      logger.error("[NpxBinExecutableGuard] Error repairing npx bin permissions: #{e.message}")
      []
    end

    private

    # Only the top-level shims npx itself execs. Nested `node_modules/*/node_modules/.bin`
    # entries belong to transitive dependencies, which are invoked through node, not
    # exec'd — walking the whole tree on every spawn would cost far more than it buys.
    def shim_paths(npx_dir)
      Dir.glob(File.join(npx_dir, "*", "node_modules", ".bin", "*"))
    end

    # @return [String, nil] the repaired target path, or nil when nothing was done
    def repair_shim(shim, npx_dir, logger)
      # File.exist? follows symlinks, so a dangling shim (its package half-removed
      # by NpxCacheHealService) is skipped rather than raising in realpath.
      return nil unless File.exist?(shim)

      target = File.realpath(shim)
      return nil unless File.file?(target)
      return nil unless within?(target, npx_dir)

      mode = File.stat(target).mode
      return nil unless (mode & EXECUTE_BITS).zero?

      File.chmod(mode | EXECUTE_BITS, target)
      target
    rescue => e
      logger.warn("[NpxBinExecutableGuard] Could not repair #{shim}: #{e.message}")
      nil
    end

    # Guard against chmod'ing anything outside the clone's own npx cache — a shim
    # symlink is attacker-controllable in principle (it is whatever a published
    # package's `bin` map points at), so a target that escapes the tree is skipped.
    def within?(target, npx_dir)
      File.expand_path(target).start_with?(File.expand_path(npx_dir) + File::SEPARATOR)
    end

    # The per-clone `_npx` tree, or nil when this session has no clone-local cache.
    # Mirrors NpxCacheHealService's path convention and its clones-base safety check,
    # so both services agree on which directories Zimmer is allowed to touch.
    def npx_cache_dir(working_directory)
      return nil if working_directory.blank?

      path = File.expand_path(File.join(working_directory, ".npm-cache", "_npx"))
      clones_base = File.expand_path(CacheClearService::CLONES_BASE_DIR.call)
      return nil unless path.start_with?(clones_base + File::SEPARATOR)

      path
    end
  end
end
