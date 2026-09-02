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

  # A dot-prefixed root is a root the constructor can write and a sweep can miss,
  # which is the construct/discover asymmetry this module exists to close.
  test "strips a leading dot so a server never gets a hidden root" do
    assert_equal "hidden-server", NpxCacheLayout.sanitize_server_name(".hidden-server")
    assert_equal "/clone/.npm-cache/isolated/hidden-server",
      NpxCacheLayout.isolated_cache_dir("/clone", ".hidden-server")
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

  # Discovery has to find every root construction can produce, including the two
  # shapes a glob would silently drop.
  test "lists an isolated root whose directory name starts with a dot" do
    hidden = File.join(@working_directory, ".npm-cache", "isolated", ".hidden-server", "_npx")
    FileUtils.mkdir_p(hidden)

    assert_includes NpxCacheLayout.npx_dirs(@working_directory), hidden
  end

  test "lists isolated roots in a clone path that contains a glob metacharacter" do
    # `git check-ref-format --branch 'foo{bar'` succeeds, and GitCloneService puts
    # the branch name in the clone path.
    working_directory = File.join(@temp_dir, ".zimmer", "clones", "zimmer-foo{bar-123", "app")
    isolated = File.join(working_directory, ".npm-cache", "isolated", "1password-tadas-rw", "_npx")
    FileUtils.mkdir_p(isolated)

    assert_includes NpxCacheLayout.npx_dirs(working_directory), isolated
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

  # A directory under `.npm-cache` can be a symlink to anywhere on the host: the
  # path as written is inside the clone, the path it resolves to is not.
  test "the resolved check refuses a root that only looks like it is in the clone" do
    outside = File.join(@temp_dir, "outside-cache", "_npx")
    FileUtils.mkdir_p(outside)
    smuggler = File.join(@working_directory, ".npm-cache", "smuggler")
    FileUtils.mkdir_p(smuggler)
    File.symlink(File.dirname(outside), File.join(smuggler, "link"))

    written = File.join(smuggler, "link", "_npx")
    assert NpxCacheLayout.within_clone_cache?(written), "the path as written is inside the clone"
    assert_not NpxCacheLayout.resolved_within_clone_cache?(File.realpath(written))
  end

  # The counterpart: resolving both sides is what keeps a deployment whose HOME is
  # a symlink from failing every check and turning its callers into no-ops.
  test "the resolved check accepts a clone reached through a symlinked home" do
    real_home = File.join(@temp_dir, "real-home")
    FileUtils.mkdir_p(real_home)
    linked_home = File.join(@temp_dir, "linked-home")
    File.symlink(real_home, linked_home)
    ENV["HOME"] = linked_home

    npx_dir = File.join(real_home, ".zimmer", "clones", "clone-a", ".npm-cache", "_npx")
    FileUtils.mkdir_p(npx_dir)

    assert NpxCacheLayout.resolved_within_clone_cache?(File.realpath(npx_dir))
  end
end
