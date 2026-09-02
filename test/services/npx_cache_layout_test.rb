# frozen_string_literal: true

require "test_helper"

class NpxCacheLayoutTest < ActiveSupport::TestCase
  setup do
    @temp_dir = Dir.mktmpdir("npx_cache_layout_test")
    @original_home = ENV["HOME"]
    @original_clones_dir = ENV["AGENT_CLONES_DIR"]
    ENV["HOME"] = @temp_dir
    # ClonesDirectory.base prefers AGENT_CLONES_DIR over HOME. Left set, it would
    # point the clones base somewhere else entirely and every containment
    # assertion below would pass or fail for the wrong reason.
    ENV.delete("AGENT_CLONES_DIR")

    @working_directory = File.join(
      @temp_dir, ".zimmer", "clones", "zimmer-main-abc", "agents", "agent-roots", "zimmer"
    )
  end

  teardown do
    ENV["HOME"] = @original_home
    ENV["AGENT_CLONES_DIR"] = @original_clones_dir
    FileUtils.rm_rf(@temp_dir) if @temp_dir && File.exist?(@temp_dir)
  end

  # --------------------------------------------------------------------------
  # Construction
  # --------------------------------------------------------------------------

  test "names the clone's shared npm cache" do
    assert_equal "/clone/.npm-cache", NpxCacheLayout.shared_cache_dir("/clone")
  end

  test "nests an isolated root inside the shared cache" do
    isolated = NpxCacheLayout.isolated_cache_dir("/clone", "1password-tadas-rw")

    assert_equal "/clone/.npm-cache/isolated/1password-tadas-rw", isolated
    # Nested rather than beside it, so CacheClearService's `**/.npm-cache` sweep
    # still reclaims it and the containment check below still recognizes it.
    assert isolated.start_with?(NpxCacheLayout.shared_cache_dir("/clone") + File::SEPARATOR)
  end

  test "gives two servers running the same package different roots" do
    assert_not_equal NpxCacheLayout.isolated_cache_dir("/clone", "1password-tadas-rw"),
      NpxCacheLayout.isolated_cache_dir("/clone", "1password-pulsemcp-rw")
  end

  test "sanitizes a server name that is not filesystem-safe" do
    assert_equal "/clone/.npm-cache/isolated/weird_name_1",
      NpxCacheLayout.isolated_cache_dir("/clone", "weird/name 1")
  end

  test "refuses a traversing server name rather than resolving it back to a parent" do
    assert_equal "unnamed", NpxCacheLayout.sanitize_server_name("..")
    assert_equal "unnamed", NpxCacheLayout.sanitize_server_name(".")
    assert_equal "unnamed", NpxCacheLayout.sanitize_server_name("")
    assert_equal "unnamed", NpxCacheLayout.sanitize_server_name(nil)
  end

  # --------------------------------------------------------------------------
  # Discovery — the half NpxBinExecutableGuard and NpxCacheHealService share
  # --------------------------------------------------------------------------

  test "lists the shared root whether or not it exists yet" do
    assert_equal [ File.join(@working_directory, ".npm-cache", "_npx") ],
      NpxCacheLayout.npx_dirs(@working_directory)
  end

  test "lists every isolated root alongside the shared one" do
    tadas = File.join(@working_directory, ".npm-cache", "isolated", "1password-tadas-rw", "_npx")
    pulsemcp = File.join(@working_directory, ".npm-cache", "isolated", "1password-pulsemcp-rw", "_npx")
    FileUtils.mkdir_p(tadas)
    FileUtils.mkdir_p(pulsemcp)

    dirs = NpxCacheLayout.npx_dirs(@working_directory)

    assert_includes dirs, File.join(@working_directory, ".npm-cache", "_npx")
    assert_includes dirs, tadas
    assert_includes dirs, pulsemcp
    assert_equal 3, dirs.size
  end

  test "targets one hash tree in every root when given a hash" do
    isolated = File.join(@working_directory, ".npm-cache", "isolated", "1password-tadas-rw", "_npx")
    FileUtils.mkdir_p(File.join(isolated, "04f14e66d79e7af4"))
    # A sibling hash in the same root must not be swept in with it.
    FileUtils.mkdir_p(File.join(isolated, "aaaaaaaaaaaaaaaa"))

    dirs = NpxCacheLayout.npx_dirs(@working_directory, "04f14e66d79e7af4")

    assert_includes dirs, File.join(@working_directory, ".npm-cache", "_npx", "04f14e66d79e7af4")
    assert_includes dirs, File.join(isolated, "04f14e66d79e7af4")
    assert_equal 2, dirs.size
  end

  test "lists nothing for a blank working directory" do
    assert_empty NpxCacheLayout.npx_dirs(nil)
    assert_empty NpxCacheLayout.npx_dirs("")
  end

  # --------------------------------------------------------------------------
  # Containment — what Zimmer is allowed to delete from or chmod
  # --------------------------------------------------------------------------

  test "accepts a shared and an isolated npx path inside a clone" do
    assert NpxCacheLayout.within_clone_cache?(
      File.join(@working_directory, ".npm-cache", "_npx")
    )
    assert NpxCacheLayout.within_clone_cache?(
      File.join(@working_directory, ".npm-cache", "isolated", "1password-tadas-rw", "_npx", "04f14e66d79e7af4")
    )
  end

  test "refuses a path outside the clones directory" do
    assert_not NpxCacheLayout.within_clone_cache?(File.join(@temp_dir, ".npm-cache", "_npx"))
    assert_not NpxCacheLayout.within_clone_cache?(File.join(Dir.home, ".npm", "_npx"))
  end

  test "refuses a path in a clone that is not an npm cache" do
    assert_not NpxCacheLayout.within_clone_cache?(@working_directory)
    assert_not NpxCacheLayout.within_clone_cache?(File.join(@working_directory, ".npm-cache"))
    assert_not NpxCacheLayout.within_clone_cache?(File.join(@working_directory, "app", "services"))
  end

  test "refuses a blank path" do
    assert_not NpxCacheLayout.within_clone_cache?(nil)
    assert_not NpxCacheLayout.within_clone_cache?("")
  end
end
