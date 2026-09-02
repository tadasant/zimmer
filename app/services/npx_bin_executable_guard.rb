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
#   Zimmer no longer renders npx servers with `--prefix /tmp`, which pointed npm's
#   bin-link destination at `/tmp/node_modules/.bin` — a directory absent on the
#   host. That is the best explanation of the failing clone's end state rather than
#   an observed step (see the issue's own "what I did not verify"), and this guard
#   is deliberately the half that does not rest on the diagnosis: the missing mode
#   bit originates in the published tarball
#   (`npm pack onepassword-mcp-server@0.5.4` → `-rw-r--r-- package/build/index.js`),
#   which Zimmer does not control at all.
#
# Strategy: before every spawn that has MCP servers (ClaudeSpawnEnv#configure_mcp_env),
# walk the `_npx/*/node_modules/.bin/*` shims in every one of the clone's npx cache
# roots — the shared one and each isolated per-server root NpxCacheLayout knows about
# — resolve each shim to its target, and add the execute bits to any target that has
# none. Cheap and idempotent — a healthy tree is a handful of `stat` calls, and a
# clone with no `_npx` cache yet (every first launch) is a couple of failed globs.
#
# Walking every root is not incidental. A server that shares an npx package with
# another server in the same config is given a cache root of its own
# (NpxCacheIsolator), and the two servers that do that in production —
# `1password-tadas-rw` and `1password-pulsemcp-rw`, both `npx -y
# onepassword-mcp-server@latest` — run the very package whose published tarball
# ships its entrypoint `-rw-r--r--`. A guard that walked only the shared root would
# miss exactly the servers it was written for (zimmer#498).
#
# The repair therefore lands on the launch AFTER the one that installed the broken
# package. That is the retry the MCP-failure ladder already schedules
# (AgentSessionJob#schedule_mcp_retry respawns the process), so a session that hits
# this recovers on its own instead of orphaning.
class NpxBinExecutableGuard
  # The read bits (u+r, g+r, o+r), and the shift that turns each one into the
  # execute bit beside it. Repairing 0644 as 0755 and 0600 as 0700 grants execute
  # exactly where read was already granted, rather than widening the file.
  READ_BITS = 0o444
  READ_TO_EXECUTE_SHIFT = 2

  class << self
    # Add the execute bit to every non-executable bin target in the clone's npx cache.
    #
    # @param working_directory [String, nil] the session's clone working dir
    #   (NPM_CONFIG_CACHE lives at <working_directory>/.npm-cache)
    # @param logger [Logger] where to record repairs
    # @return [Array<String>] the target paths that were made executable
    def repair!(working_directory:, logger: Rails.logger)
      npx_cache_dirs(working_directory).flat_map { |npx_dir| repair_root(npx_dir, logger) }
    rescue => e
      # Never let a best-effort repair block a spawn: the worst case without it is
      # the pre-existing failure mode, and the worst case with a raise here is a
      # session that cannot start at all.
      logger.error("[NpxBinExecutableGuard] Error repairing npx bin permissions: #{e.message}")
      []
    end

    private

    # Repair one cache root. Roots are independent: one that has been removed
    # underneath us, or that we cannot resolve, is skipped rather than aborting
    # the sweep over its siblings.
    #
    # @return [Array<String>] the target paths repaired in this root
    def repair_root(npx_dir, logger)
      return [] unless File.directory?(npx_dir)

      # Resolve the base the same way targets are resolved. expand_path does not
      # follow symlinks, so a symlinked HOME or AGENT_CLONES_DIR would fail every
      # containment check and turn the guard into a silent no-op — the symptom of
      # which is indistinguishable from the bug it exists to fix.
      root = File.realpath(npx_dir)

      repaired = shim_paths(root).filter_map { |shim| repair_shim(shim, root, logger) }

      if repaired.any?
        logger.warn(
          "[NpxBinExecutableGuard] Restored the execute bit on #{repaired.size} npx bin " \
          "target(s) under #{root}: #{repaired.join(', ')}"
        )
      end

      repaired
    rescue SystemCallError => e
      logger.warn("[NpxBinExecutableGuard] Could not walk #{npx_dir}: #{e.message}")
      []
    end

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

      unless within?(target, npx_dir)
        logger.warn(
          "[NpxBinExecutableGuard] Refusing to repair #{shim}: it resolves to #{target}, " \
          "outside the clone's own npx cache"
        )
        return nil
      end

      # File.executable? tests the effective uid, so it also catches a target whose
      # execute bits belong to somebody else (0o744 owned by another user execs with
      # the same EACCES). A chmod that then fails is rescued and logged below, which
      # beats skipping in silence.
      return nil if File.executable?(target)

      # Permission bits only: setuid/setgid/sticky are dropped rather than carried
      # into a file this guard is about to make executable.
      mode = File.stat(target).mode & 0o777
      File.chmod(mode | execute_bits_for(mode), target)
      target
    rescue => e
      logger.warn("[NpxBinExecutableGuard] Could not repair #{shim}: #{e.message}")
      nil
    end

    # Mirror the target's read bits into its execute bits (0644 -> 0755, 0600 ->
    # 0700). A file with no read bit at all is not a shape npm produces; grant the
    # owner alone in that case rather than leaving it unlaunchable.
    def execute_bits_for(mode)
      mirrored = (mode & READ_BITS) >> READ_TO_EXECUTE_SHIFT
      mirrored.zero? ? 0o100 : mirrored
    end

    # Guard against chmod'ing anything outside the clone's own npx cache — a shim
    # symlink is attacker-controllable in principle (it is whatever a published
    # package's `bin` map points at), so a target that escapes the tree is skipped.
    def within?(target, npx_dir)
      File.expand_path(target).start_with?(File.expand_path(npx_dir) + File::SEPARATOR)
    end

    # Every `_npx` tree this clone has — the shared one and each isolated
    # per-server root — filtered to those Zimmer is allowed to touch.
    #
    # Both the layout and the safety check come from NpxCacheLayout, which
    # NpxCacheHealService also reads, so the two services cannot drift about which
    # directories exist or which of them are in bounds. Containment is applied per
    # root: one root that escapes the clones directory is dropped on its own
    # rather than disqualifying its siblings.
    def npx_cache_dirs(working_directory)
      NpxCacheLayout.npx_dirs(working_directory).select { |dir| NpxCacheLayout.within_clone_cache?(dir) }
    end
  end
end
