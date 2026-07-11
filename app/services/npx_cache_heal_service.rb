# frozen_string_literal: true

# Heals a corrupt or mis-resolved per-clone npm `_npx/<hash>` cache that crashes
# an `npx -y <pkg>@latest` MCP server on startup — whether the corruption
# surfaces at package *extraction* time (a half-written tar tree) or later at
# module-*resolution* time (a require/import that can't be satisfied).
#
# Background (see GitHub issues #3924 / #4109):
#   Zimmer isolates the npm cache per clone via NPM_CONFIG_CACHE=<working_dir>/.npm-cache
#   (ClaudeCliAdapter#configure_mcp_env). When concurrent or retried `npx`
#   invocations race into the same shared `_npx/<hash>` directory, the extraction
#   itself can fail against a partially-populated tree, npm printing tar/rename
#   errors while it tries to unpack the package into `_npx/<hash>/node_modules/...`:
#
#     npm warn tar TAR_ENTRY_ERROR ENOENT: no such file or directory, lstat
#       '.../.npm-cache/_npx/dbbb2997d8a4f060/node_modules/ajv/dist/compile'
#     npm error code ENOTEMPTY ... rename '.../_npx/<hash>/node_modules/.foo-XXXX'
#       '.../_npx/<hash>/node_modules/foo' ... directory not empty
#
#   This is the signature that terminally orphaned production session 9570
#   (`pulse-goodjobs-rw`): the connection then just times out on every retry
#   because the poisoned `_npx/<hash>` tree is left behind.
#
#   The SAME half-written tree, when the extraction "succeeds" enough for npx to
#   treat the directory as installed, instead surfaces later as a module-resolution
#   failure — a transitive dependency (e.g. `ajv`, pulled in by `ajv-formats` via
#   the MCP SDK) referenced on disk but not installed:
#
#     Error: Cannot find module 'ajv'
#     Require stack:
#     - .../.npm-cache/_npx/49a1f4c1ceebda27/node_modules/ajv-formats/dist/limit.js
#       code: 'MODULE_NOT_FOUND'
#
#   or as an ESM *resolution* failure, when a version-skewed install leaves a
#   package whose entry point resolves to a bare directory (or a subpath the
#   package never exported). The real-world signature that motivated the ESM
#   variant (the `agent-orchestrator-mcp-server` `zod/v4` crash) is:
#
#     Error [ERR_UNSUPPORTED_DIR_IMPORT]: Directory import
#     '.../.npm-cache/_npx/a5c0f8a8df975b78/node_modules/zod/v4' is not supported
#     resolving ES modules imported from
#     '.../_npx/a5c0f8a8df975b78/node_modules/@modelcontextprotocol/sdk/dist/esm/types.js'
#       code: 'ERR_UNSUPPORTED_DIR_IMPORT'
#
#   These are all the same class of `_npx` corruption — extraction-race and
#   partial-install / version-skew — and the heal is identical for every one.
#
#   A corrupt cache otherwise *sticks*, because `npx` treats the directory as
#   "installed" and never re-extracts it. Removing the corrupt `_npx/<hash>`
#   tree forces the next retry to do a fresh, complete install.
#
# Strategy (detect-and-heal): when an MCP connection failure carries either an
# npm extraction error (TAR_ENTRY_ERROR / ENOTEMPTY) or a Node module-resolution
# error originating from an `_npx` cache, this service deletes the offending cache
# tree so Zimmer's existing MCP-retry path (AgentSessionJob) re-installs it cleanly.
# It is targeted by default (deletes only the specific `_npx/<hash>` directories
# named in the error) and falls back to clearing the whole per-clone `_npx`
# directory when the error references the cache but no specific hash path can be
# parsed out of it.
class NpxCacheHealService
  # Node module-resolution failure markers emitted when a require/import can't be
  # satisfied. A corrupt/version-skewed `_npx` install surfaces as one of these:
  #
  #   * MODULE_NOT_FOUND / ERR_MODULE_NOT_FOUND / "Cannot find module|package" —
  #     a transitive dependency referenced on disk but not installed (partial
  #     install race).
  #   * ERR_UNSUPPORTED_DIR_IMPORT — an ESM import resolves to a bare directory
  #     (e.g. a `zod/v4` subpath present only in a different zod version than the
  #     one the cache resolved).
  #   * ERR_PACKAGE_PATH_NOT_EXPORTED — an ESM import targets a subpath the
  #     resolved package version never declared in its `exports` map.
  #   * "is not supported resolving ES modules" — the human-readable phrasing Node
  #     prints alongside ERR_UNSUPPORTED_DIR_IMPORT, matched as a belt-and-braces
  #     fallback in case the error code is stripped from the persisted text.
  RESOLUTION_FAILURE_MARKERS = /
    MODULE_NOT_FOUND |
    ERR_MODULE_NOT_FOUND |
    Cannot\ find\ module |
    Cannot\ find\ package |
    ERR_UNSUPPORTED_DIR_IMPORT |
    ERR_PACKAGE_PATH_NOT_EXPORTED |
    is\ not\ supported\ resolving\ ES\ modules
  /xi

  # npm package-*extraction* failure markers emitted while `npx` unpacks a package
  # into `_npx/<hash>/node_modules/...`. When concurrent installs race the same
  # cache dir, npm reads/writes a half-populated tree and aborts with one of these:
  #
  #   * TAR_ENTRY_ERROR — npm's bundled tar hit a missing/half-written entry mid
  #     extraction (the `TAR_ENTRY_ERROR ENOENT ... lstat '.../_npx/<hash>/...'`
  #     lines that orphaned session 9570).
  #   * ENOTEMPTY — npm couldn't atomically rename a staging dir over a non-empty
  #     target (`npm error code ENOTEMPTY ... rename ... directory not empty`).
  #
  # Both are highly specific to npm cache corruption; paired with the mandatory
  # `_npx` reference in `npx_cache_corruption?`, an unrelated error would have to
  # both carry one of these markers AND name an `_npx` path in the same failed
  # server's error blob to trigger a heal. In practice a server's persisted error
  # only contains stderr from its own npx invocation, so co-location implies the
  # marker really is about that cache; the worst case if it isn't is a bounded,
  # safe reinstall of the named `_npx/<hash>` tree (never out-of-clone deletion,
  # never data loss — see safe_to_remove?).
  EXTRACTION_FAILURE_MARKERS = /
    TAR_ENTRY_ERROR |
    ENOTEMPTY
  /xi

  # Absolute path to an `_npx/<hash>` cache directory. The hash is npm's
  # content-addressed directory name (lowercase hex). We capture the path up to
  # and including the hash segment so we can delete the whole installed tree.
  NPX_HASH_DIR_PATTERN = %r{(?<dir>/[^\s:'"]*?/_npx/[0-9a-f]+)(?=/|\s|$|'|"|:)}i

  # A bare `_npx/<hash>` token with no absolute path prefix. Used to recover the
  # specific corrupt hash from a truncated/relativized error so the fallback can
  # still target one directory instead of evicting the whole clone cache.
  NPX_HASH_TOKEN_PATTERN = %r{_npx/(?<hash>[0-9a-f]+)}i

  class << self
    # Inspect failed MCP servers and remove any corrupt `_npx` cache trees they
    # blame, so a subsequent retry re-installs cleanly.
    #
    # @param failed_servers [Array<Hash>] entries shaped { "name" => ..., "error" => ... }
    # @param working_directory [String, nil] the session's clone working dir
    #   (NPM_CONFIG_CACHE lives at <working_directory>/.npm-cache)
    # @param logger [Logger] where to record heal actions
    # @return [Hash] { healed: Boolean, removed_paths: Array<String> }
    def heal_from_failures(failed_servers:, working_directory: nil, logger: Rails.logger)
      removed = []

      Array(failed_servers).each do |server|
        error = server["error"].to_s
        next unless npx_cache_corruption?(error)

        paths = corrupt_cache_paths(error, working_directory)
        paths.each do |path|
          next unless safe_to_remove?(path)
          next unless File.exist?(path)

          FileUtils.rm_rf(path)
          removed << path
          logger.warn(
            "[NpxCacheHealService] Removed corrupt _npx cache tree for MCP server " \
            "'#{server["name"]}': #{path}"
          )
        end
      end

      { healed: removed.any?, removed_paths: removed.uniq }
    rescue => e
      logger.error("[NpxCacheHealService] Error while healing npx cache: #{e.message}")
      { healed: false, removed_paths: removed.uniq }
    end

    # @return [Boolean] true if the error text looks like `_npx` cache corruption —
    #   either an npm package-extraction failure (TAR_ENTRY_ERROR / ENOTEMPTY) or a
    #   Node module-resolution failure — originating from an `_npx` cache. We require
    #   BOTH a corruption marker AND an `_npx` reference so a legitimately missing
    #   module, an unrelated ESM error from a non-npx server, or an ENOTEMPTY from an
    #   unrelated directory never triggers a cache wipe.
    def npx_cache_corruption?(error)
      text = error.to_s
      return false unless text.include?("_npx")

      text.match?(RESOLUTION_FAILURE_MARKERS) || text.match?(EXTRACTION_FAILURE_MARKERS)
    end

    private

    # Resolve which cache directories to remove for a given error, preferring the
    # narrowest target so healthy sibling caches survive.
    #
    # 1. Absolute paths: every distinct `_npx/<hash>` directory named in the
    #    error's require stack (deleted as-is).
    # 2. Recovered hashes: when only a bare `_npx/<hash>` token is present (e.g. a
    #    relativized/truncated log), rebuild `<working_directory>/.npm-cache/_npx/<hash>`
    #    so the fallback is still a single-package eviction.
    # 3. Last resort: when the error references `_npx` but no hash at all can be
    #    parsed out, the whole per-clone `_npx` directory under working_directory.
    def corrupt_cache_paths(error, working_directory)
      text = error.to_s

      absolute = text.scan(NPX_HASH_DIR_PATTERN).flatten.uniq
      return absolute if absolute.any?

      hashes = text.scan(NPX_HASH_TOKEN_PATTERN).flatten.uniq
      if hashes.any? && working_directory.present?
        return hashes.map { |hash| File.join(working_directory, ".npm-cache", "_npx", hash) }
      end

      fallback = per_clone_npx_dir(working_directory)
      fallback ? [ fallback ] : []
    end

    def per_clone_npx_dir(working_directory)
      return nil if working_directory.blank?

      File.join(working_directory, ".npm-cache", "_npx")
    end

    # Guard against deleting anything outside a Zimmer clone's npm cache. Only paths
    # that live under ~/.zimmer/clones AND inside a `.npm-cache/_npx`
    # segment are eligible.
    def safe_to_remove?(path)
      return false if path.blank?

      expanded = File.expand_path(path)
      # Reuse CacheClearService's clones-base definition so the security-relevant
      # path has a single source of truth (it's a lambda so it honors Dir.home at
      # call time, which lets tests redirect HOME).
      clones_base = File.expand_path(CacheClearService::CLONES_BASE_DIR.call)

      expanded.start_with?(clones_base + File::SEPARATOR) &&
        expanded.include?("#{File::SEPARATOR}.npm-cache#{File::SEPARATOR}_npx")
    end
  end
end
