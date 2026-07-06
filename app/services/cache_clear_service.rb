# frozen_string_literal: true

# Service to clear package manager caches that may become corrupted
#
# Supported caches:
# - npm _npx cache: Can become corrupted if containers are killed mid-install,
#   causing ENOTEMPTY errors when starting MCP servers
# - Per-clone npm caches: ClaudeCliAdapter isolates npm caches per working directory
#   (via NPM_CONFIG_CACHE=<working_dir>/.npm-cache). These per-clone caches can also
#   become corrupted and must be cleared alongside the global cache.
# - pip cache: Can become corrupted similarly
#
# Usage:
#   CacheClearService.clear_all  # Clear all caches
#   CacheClearService.clear_npm  # Clear just npm cache
#   CacheClearService.clear_pip  # Clear just pip cache
#   CacheClearService.clear_all_and_reinstall  # Clear caches and reinstall MCP packages
class CacheClearService
  # Cache directories to clear
  CACHES = {
    npm_npx: {
      name: "npm npx cache",
      path: -> { File.join(Dir.home, ".npm", "_npx") },
      description: "npx package cache (fixes ENOTEMPTY errors)"
    },
    npm_cache: {
      name: "npm cache",
      path: -> { File.join(Dir.home, ".npm", "_cacache") },
      description: "npm download cache"
    },
    pip: {
      name: "pip cache",
      path: -> { File.join(Dir.home, ".cache", "pip") },
      description: "pip package cache"
    }
  }.freeze

  # Base directory for agent clones (single source of truth: ClonesDirectory).
  # Kept as a lambda so it resolves the configurable/durable base at call time.
  CLONES_BASE_DIR = -> { ClonesDirectory.base }

  class << self
    # Clear all supported caches
    # @return [Hash] Results for each cache { cache_key => { cleared: bool, error: string|nil, path: string } }
    def clear_all
      results = CACHES.keys.each_with_object({}) do |cache_key, hash|
        hash[cache_key] = clear_cache(cache_key)
      end

      results[:clone_npm_caches] = clear_clone_npm_caches

      results
    end

    # Clear all caches and then reinstall MCP packages
    # This enqueues a background job to pre-install packages after clearing
    # @return [Hash] Results for each cache plus :reinstall_queued status
    def clear_all_and_reinstall
      results = clear_all

      # Only queue reinstall if at least one npm cache was cleared
      npm_cleared = results[:npm_npx]&.dig(:cleared) ||
                    results[:npm_cache]&.dig(:cleared) ||
                    results[:clone_npm_caches]&.dig(:cleared)

      if npm_cleared
        McpPackageReinstallJob.perform_later
        results[:reinstall] = { queued: true, message: "MCP package reinstall job queued" }
      else
        results[:reinstall] = { queued: false, message: "No npm cache cleared, skipping reinstall" }
      end

      results
    end

    # Clear the npm npx cache
    # @return [Hash] { cleared: bool, error: string|nil, path: string }
    def clear_npm
      clear_cache(:npm_npx)
    end

    # Clear the pip cache
    # @return [Hash] { cleared: bool, error: string|nil, path: string }
    def clear_pip
      clear_cache(:pip)
    end

    private

    def clear_cache(cache_key)
      config = CACHES[cache_key]
      return { cleared: false, error: "Unknown cache: #{cache_key}" } unless config

      path = config[:path].call

      unless File.exist?(path)
        return { cleared: false, path: path, message: "Directory does not exist" }
      end

      begin
        FileUtils.rm_rf(path)
        { cleared: true, path: path }
      rescue StandardError => e
        { cleared: false, path: path, error: e.message }
      end
    end

    # Clear .npm-cache directories inside agent clone working directories.
    #
    # ClaudeCliAdapter#configure_mcp_env sets NPM_CONFIG_CACHE to
    # <working_dir>/.npm-cache for each session, isolating npx installs
    # per clone. These per-clone caches can become corrupted just like
    # the global cache and need to be cleared too.
    #
    # Uses Dir.glob to find .npm-cache dirs at any depth under the clones
    # base directory (they can be nested in subdirectories for subagents).
    def clear_clone_npm_caches
      clones_dir = CLONES_BASE_DIR.call

      unless File.directory?(clones_dir)
        return { cleared: false, path: clones_dir, message: "Clones directory does not exist" }
      end

      cache_dirs = Dir.glob(File.join(clones_dir, "**", ".npm-cache"))
      if cache_dirs.empty?
        return { cleared: false, path: clones_dir, message: "No per-clone .npm-cache directories found" }
      end

      cleared_paths = []
      errors = []

      cache_dirs.each do |dir|
        FileUtils.rm_rf(dir)
        cleared_paths << dir
      rescue StandardError => e
        errors << "#{dir}: #{e.message}"
      end

      result = { cleared: cleared_paths.any?, cleared_count: cleared_paths.size, paths: cleared_paths }
      result[:errors] = errors if errors.any?
      result
    end
  end
end
