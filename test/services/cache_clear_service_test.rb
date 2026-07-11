# frozen_string_literal: true

require "test_helper"

class CacheClearServiceTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @temp_dir = Dir.mktmpdir("cache_clear_test")
    @original_home = ENV["HOME"]
  end

  teardown do
    ENV["HOME"] = @original_home
    FileUtils.rm_rf(@temp_dir) if @temp_dir && File.exist?(@temp_dir)
  end

  test "clear_all clears all cache directories that exist" do
    # Set up fake home directory
    ENV["HOME"] = @temp_dir

    # Create npm npx cache directory
    npm_npx_path = File.join(@temp_dir, ".npm", "_npx")
    FileUtils.mkdir_p(npm_npx_path)
    File.write(File.join(npm_npx_path, "test_file"), "test")

    # Create pip cache directory
    pip_path = File.join(@temp_dir, ".cache", "pip")
    FileUtils.mkdir_p(pip_path)
    File.write(File.join(pip_path, "test_file"), "test")

    results = CacheClearService.clear_all

    assert results[:npm_npx][:cleared], "npm npx cache should be cleared"
    assert results[:pip][:cleared], "pip cache should be cleared"
    refute File.exist?(npm_npx_path), "npm npx directory should be deleted"
    refute File.exist?(pip_path), "pip directory should be deleted"
  end

  test "clear_all handles non-existent directories gracefully" do
    ENV["HOME"] = @temp_dir

    # Don't create any cache directories

    results = CacheClearService.clear_all

    refute results[:npm_npx][:cleared]
    assert_equal "Directory does not exist", results[:npm_npx][:message]
    refute results[:pip][:cleared]
    assert_equal "Directory does not exist", results[:pip][:message]
  end

  test "clear_npm clears only npm npx cache" do
    ENV["HOME"] = @temp_dir

    npm_npx_path = File.join(@temp_dir, ".npm", "_npx")
    FileUtils.mkdir_p(npm_npx_path)
    File.write(File.join(npm_npx_path, "test_file"), "test")

    result = CacheClearService.clear_npm

    assert result[:cleared]
    assert_equal npm_npx_path, result[:path]
    refute File.exist?(npm_npx_path)
  end

  test "clear_pip clears only pip cache" do
    ENV["HOME"] = @temp_dir

    pip_path = File.join(@temp_dir, ".cache", "pip")
    FileUtils.mkdir_p(pip_path)
    File.write(File.join(pip_path, "test_file"), "test")

    result = CacheClearService.clear_pip

    assert result[:cleared]
    assert_equal pip_path, result[:path]
    refute File.exist?(pip_path)
  end

  test "CACHES constant includes expected cache types" do
    assert CacheClearService::CACHES.key?(:npm_npx)
    assert CacheClearService::CACHES.key?(:npm_cache)
    assert CacheClearService::CACHES.key?(:pip)
  end

  test "clear_all_and_reinstall queues reinstall job when npm cache cleared" do
    ENV["HOME"] = @temp_dir

    # Create npm npx cache directory
    npm_npx_path = File.join(@temp_dir, ".npm", "_npx")
    FileUtils.mkdir_p(npm_npx_path)
    File.write(File.join(npm_npx_path, "test_file"), "test")

    assert_enqueued_with(job: McpPackageReinstallJob) do
      results = CacheClearService.clear_all_and_reinstall

      assert results[:npm_npx][:cleared]
      assert results[:reinstall][:queued]
      assert_equal "MCP package reinstall job queued", results[:reinstall][:message]
    end
  end

  test "clear_all_and_reinstall does not queue reinstall job when no npm cache cleared" do
    ENV["HOME"] = @temp_dir

    # Don't create any cache directories

    assert_no_enqueued_jobs only: McpPackageReinstallJob do
      results = CacheClearService.clear_all_and_reinstall

      refute results[:reinstall][:queued]
      assert_equal "No npm cache cleared, skipping reinstall", results[:reinstall][:message]
    end
  end

  test "clear_all_and_reinstall queues reinstall when npm_cache cleared but not npm_npx" do
    ENV["HOME"] = @temp_dir

    # Create npm cache directory (not npx)
    npm_cache_path = File.join(@temp_dir, ".npm", "_cacache")
    FileUtils.mkdir_p(npm_cache_path)
    File.write(File.join(npm_cache_path, "test_file"), "test")

    assert_enqueued_with(job: McpPackageReinstallJob) do
      results = CacheClearService.clear_all_and_reinstall

      assert results[:npm_cache][:cleared]
      assert results[:reinstall][:queued]
    end
  end

  test "clear_all clears per-clone .npm-cache directories" do
    ENV["HOME"] = @temp_dir

    # Create clones directory with per-clone npm caches at various depths
    clones_dir = File.join(@temp_dir, ".zimmer", "clones")
    clone1_cache = File.join(clones_dir, "repo-main-123-abc", "agent-orchestrator", ".npm-cache")
    clone2_cache = File.join(clones_dir, "repo-main-456-def", "agents", "subagent", ".npm-cache")

    FileUtils.mkdir_p(clone1_cache)
    FileUtils.mkdir_p(File.join(clone1_cache, "_npx", "abc123"))
    File.write(File.join(clone1_cache, "_npx", "abc123", "package.json"), "{}")

    FileUtils.mkdir_p(clone2_cache)
    FileUtils.mkdir_p(File.join(clone2_cache, "_npx", "def456"))
    File.write(File.join(clone2_cache, "_npx", "def456", "package.json"), "{}")

    results = CacheClearService.clear_all

    assert results[:clone_npm_caches][:cleared], "per-clone npm caches should be cleared"
    assert_equal 2, results[:clone_npm_caches][:cleared_count]
    refute File.exist?(clone1_cache), "clone1 .npm-cache should be deleted"
    refute File.exist?(clone2_cache), "clone2 .npm-cache should be deleted"
  end

  test "clear_all handles no per-clone caches gracefully" do
    ENV["HOME"] = @temp_dir

    # Create clones directory but no .npm-cache dirs inside
    clones_dir = File.join(@temp_dir, ".zimmer", "clones")
    FileUtils.mkdir_p(File.join(clones_dir, "repo-main-123-abc"))

    results = CacheClearService.clear_all

    refute results[:clone_npm_caches][:cleared]
    assert_equal "No per-clone .npm-cache directories found", results[:clone_npm_caches][:message]
  end

  test "clear_all handles missing clones directory gracefully" do
    ENV["HOME"] = @temp_dir

    # Don't create the clones directory at all

    results = CacheClearService.clear_all

    refute results[:clone_npm_caches][:cleared]
    assert_equal "Clones directory does not exist", results[:clone_npm_caches][:message]
  end

  test "clear_all_and_reinstall queues reinstall when only clone npm caches cleared" do
    ENV["HOME"] = @temp_dir

    # Create only a per-clone cache (no global npm cache)
    clones_dir = File.join(@temp_dir, ".zimmer", "clones")
    clone_cache = File.join(clones_dir, "repo-main-123-abc", ".npm-cache")
    FileUtils.mkdir_p(clone_cache)
    File.write(File.join(clone_cache, "test_file"), "test")

    assert_enqueued_with(job: McpPackageReinstallJob) do
      results = CacheClearService.clear_all_and_reinstall

      assert results[:clone_npm_caches][:cleared]
      assert results[:reinstall][:queued]
    end
  end
end
