# frozen_string_literal: true

require "test_helper"

class NpxBinExecutableGuardTest < ActiveSupport::TestCase
  setup do
    @temp_dir = Dir.mktmpdir("npx_bin_guard_test")
    @original_home = ENV["HOME"]
    @original_clones_dir = ENV["AGENT_CLONES_DIR"]
    ENV["HOME"] = @temp_dir
    # ClonesDirectory.base prefers AGENT_CLONES_DIR over HOME. Left set, it would
    # point the clones base somewhere else entirely and every assertion below would
    # pass or fail for the wrong reason.
    ENV.delete("AGENT_CLONES_DIR")

    # Mirror the production layout: ~/.zimmer/clones/<clone>/<subdir>
    @working_directory = File.join(
      @temp_dir, ".zimmer", "clones", "zimmer-main-abc", "agents", "agent-roots", "zimmer"
    )
    @npx_dir = File.join(@working_directory, ".npm-cache", "_npx")
    FileUtils.mkdir_p(@npx_dir)

    @logger = Logger.new(File::NULL)
  end

  teardown do
    ENV["HOME"] = @original_home
    ENV["AGENT_CLONES_DIR"] = @original_clones_dir
    FileUtils.rm_rf(@temp_dir) if @temp_dir && File.exist?(@temp_dir)
  end

  # Build the tree npx leaves behind: a package whose entrypoint is linked into
  # `.bin` under the hash dir. `mode` is the entrypoint's mode — 0644 is how
  # onepassword-mcp-server ships (zimmer#467), 0755 is a healthy install.
  # `npx_dir` defaults to the clone's shared cache root; pass an isolated one to
  # build the tree NpxCacheIsolator produces.
  def install_package(hash, name = "acme-mcp-server", mode: 0o644, entrypoint: "build/index.js", npx_dir: @npx_dir)
    package_dir = File.join(npx_dir, hash, "node_modules", name)
    target = File.join(package_dir, entrypoint)
    FileUtils.mkdir_p(File.dirname(target))
    File.write(target, "#!/usr/bin/env node\n")
    File.chmod(mode, target)

    bin_dir = File.join(npx_dir, hash, "node_modules", ".bin")
    FileUtils.mkdir_p(bin_dir)
    shim = File.join(bin_dir, name)
    File.symlink(File.join("..", name, entrypoint), shim)

    { shim: shim, target: target }
  end

  # Where NpxCacheIsolator points a server that shares an npx package with another
  # server in the same config.
  def isolated_npx_dir(server_name)
    File.join(@working_directory, ".npm-cache", "isolated", server_name, "_npx")
  end

  def repair
    NpxBinExecutableGuard.repair!(working_directory: @working_directory, logger: @logger)
  end

  test "restores the execute bit on a bin target that ships without one" do
    paths = install_package("49a1f4c1ceebda27")
    refute File.executable?(paths[:target]), "fixture must start non-executable"

    repaired = repair

    assert_equal [ paths[:target] ], repaired
    assert File.executable?(paths[:target])
    # The shim resolves and execs — the EACCES that orphaned session 4388 is gone.
    assert_equal 0o755, File.stat(paths[:target]).mode & 0o777
  end

  test "leaves a healthy install untouched" do
    paths = install_package("deadbeefdeadbeef", mode: 0o755)

    assert_empty repair
    assert_equal 0o755, File.stat(paths[:target]).mode & 0o777
  end

  test "preserves the read bits it found rather than forcing 0755" do
    paths = install_package("aaaabbbbccccdddd", mode: 0o600)

    assert_equal [ paths[:target] ], repair
    assert_equal 0o700, File.stat(paths[:target]).mode & 0o777
  end

  test "grants the owner alone when the target carries no read bit at all" do
    paths = install_package("bbbbccccddddeeee", mode: 0o000)

    assert_equal [ paths[:target] ], repair
    assert_equal 0o100, File.stat(paths[:target]).mode & 0o777
  end

  test "repairs every hash tree in the cache" do
    first = install_package("1111111111111111", "first-mcp-server")
    second = install_package("2222222222222222", "second-mcp-server")

    assert_equal [ first[:target], second[:target] ].sort, repair.sort
    assert File.executable?(first[:target])
    assert File.executable?(second[:target])
  end

  # NpxCacheIsolator gives every server that shares an npx package with another
  # server in the same config a cache root of its own, so its `_npx` tree does not
  # sit directly under `.npm-cache`. The two servers that collide in production —
  # `1password-tadas-rw` and `1password-pulsemcp-rw` — both run
  # `npx -y onepassword-mcp-server@latest`, the very package that ships its
  # entrypoint `-rw-r--r--`. Before zimmer#498 the guard globbed only the shared
  # root, so isolation silently opted those servers out of this repair.
  test "restores the execute bit inside a per-server isolated cache root" do
    paths = install_package(
      "04f14e66d79e7af4", "onepassword-mcp-server",
      npx_dir: isolated_npx_dir("1password-tadas-rw")
    )
    refute File.executable?(paths[:target]), "fixture must start non-executable"

    assert_equal [ paths[:target] ], repair
    assert File.executable?(paths[:target])
    assert_equal 0o755, File.stat(paths[:target]).mode & 0o777
  end

  test "sweeps the shared root and every isolated root in one pass" do
    shared = install_package("1111111111111111", "solo-mcp-server")
    # Two isolated roots holding the same package under the same npx hash — the
    # collision that made the isolator hand them separate roots in the first place.
    tadas = install_package(
      "04f14e66d79e7af4", "onepassword-mcp-server",
      npx_dir: isolated_npx_dir("1password-tadas-rw")
    )
    pulsemcp = install_package(
      "04f14e66d79e7af4", "onepassword-mcp-server",
      npx_dir: isolated_npx_dir("1password-pulsemcp-rw")
    )

    assert_equal [ shared[:target], tadas[:target], pulsemcp[:target] ].sort, repair.sort
    assert File.executable?(tadas[:target])
    assert File.executable?(pulsemcp[:target])
  end

  # Containment is enforced per root, so an isolated root gets the same refusal the
  # shared root does rather than inheriting a check made against a different tree.
  test "skips a shim in an isolated root whose target escapes the cache" do
    outside = File.join(@temp_dir, "isolated-escapee.js")
    File.write(outside, "#!/usr/bin/env node\n")
    File.chmod(0o644, outside)

    bin_dir = File.join(isolated_npx_dir("1password-tadas-rw"), "04f14e66d79e7af4", "node_modules", ".bin")
    FileUtils.mkdir_p(bin_dir)
    File.symlink(outside, File.join(bin_dir, "escaping-server"))

    log = StringIO.new
    assert_empty NpxBinExecutableGuard.repair!(
      working_directory: @working_directory, logger: Logger.new(log)
    )
    refute File.executable?(outside), "a target outside the cache must never be chmod'ed"
    assert_match(/Refusing to repair/, log.string)
  end

  # Each root is its own containment boundary: a shim that reaches out of its
  # isolated root into a sibling cache root is refused even though the target is
  # still somewhere under the clone's `.npm-cache`.
  test "skips a shim in an isolated root whose target resolves into another root" do
    other_root_target = File.join(
      @npx_dir, "2222222222222222", "node_modules", "borrowed-server", "build", "index.js"
    )
    FileUtils.mkdir_p(File.dirname(other_root_target))
    File.write(other_root_target, "#!/usr/bin/env node\n")
    File.chmod(0o644, other_root_target)

    bin_dir = File.join(isolated_npx_dir("1password-tadas-rw"), "04f14e66d79e7af4", "node_modules", ".bin")
    FileUtils.mkdir_p(bin_dir)
    File.symlink(other_root_target, File.join(bin_dir, "borrowed-server"))

    assert_empty repair
    refute File.executable?(other_root_target)
  end

  test "repairs a bin entry npm wrote as a regular file rather than a symlink" do
    bin_dir = File.join(@npx_dir, "aaaa1111bbbb2222", "node_modules", ".bin")
    FileUtils.mkdir_p(bin_dir)
    shim = File.join(bin_dir, "inline-server")
    File.write(shim, "#!/usr/bin/env node\n")
    File.chmod(0o644, shim)

    assert_equal [ shim ], repair
    assert File.executable?(shim)
  end

  test "repairs a target whose execute bits belong to another user" do
    paths = install_package("cccc3333dddd4444", mode: 0o644)
    # 0o744 owned by somebody else execs with the same EACCES, so the effective-uid
    # check — not the raw bits — is what has to decide.
    File.chmod(0o744, paths[:target])
    File.stub(:executable?, false) do
      assert_equal [ paths[:target] ], repair
    end
  end

  test "logs the shim it refuses when a target escapes the cache" do
    outside = File.join(@temp_dir, "escapee.js")
    File.write(outside, "#!/usr/bin/env node\n")
    File.chmod(0o644, outside)
    bin_dir = File.join(@npx_dir, "eeee5555ffff6666", "node_modules", ".bin")
    FileUtils.mkdir_p(bin_dir)
    File.symlink(outside, File.join(bin_dir, "escaping-server"))

    log = StringIO.new
    assert_empty NpxBinExecutableGuard.repair!(
      working_directory: @working_directory, logger: Logger.new(log)
    )
    assert_match(/Refusing to repair/, log.string)
    assert_match(/escapee\.js/, log.string)
  end

  test "swallows an unexpected error rather than blocking the spawn" do
    install_package("7777aaaa8888bbbb")
    log = StringIO.new

    Dir.stub(:glob, ->(*) { raise Errno::EIO }) do
      assert_empty NpxBinExecutableGuard.repair!(
        working_directory: @working_directory, logger: Logger.new(log)
      )
    end

    assert_match(/Error repairing npx bin permissions/, log.string)
  end

  test "is idempotent" do
    paths = install_package("3333333333333333")

    assert_equal [ paths[:target] ], repair
    assert_empty repair
    assert File.executable?(paths[:target])
  end

  test "skips a dangling shim left by a half-removed package" do
    paths = install_package("4444444444444444")
    FileUtils.rm_rf(File.dirname(File.dirname(paths[:target])))

    assert_empty repair
  end

  test "skips a shim whose target escapes the npx cache" do
    outside = File.join(@temp_dir, "outside-target.js")
    File.write(outside, "#!/usr/bin/env node\n")
    File.chmod(0o644, outside)

    bin_dir = File.join(@npx_dir, "5555555555555555", "node_modules", ".bin")
    FileUtils.mkdir_p(bin_dir)
    File.symlink(outside, File.join(bin_dir, "escaping-server"))

    assert_empty repair
    refute File.executable?(outside), "a target outside the cache must never be chmod'ed"
  end

  test "skips a shim that resolves to a directory" do
    bin_dir = File.join(@npx_dir, "6666666666666666", "node_modules", ".bin")
    package_dir = File.join(@npx_dir, "6666666666666666", "node_modules", "weird-server")
    FileUtils.mkdir_p(bin_dir)
    FileUtils.mkdir_p(package_dir)
    File.symlink(File.join("..", "weird-server"), File.join(bin_dir, "weird-server"))

    assert_empty repair
  end

  test "is a no-op when the clone has no npx cache yet (every first launch)" do
    FileUtils.rm_rf(File.join(@working_directory, ".npm-cache"))

    assert_empty repair
  end

  test "is a no-op for a blank working directory" do
    assert_empty NpxBinExecutableGuard.repair!(working_directory: nil, logger: @logger)
    assert_empty NpxBinExecutableGuard.repair!(working_directory: "", logger: @logger)
  end

  test "refuses to touch a cache outside the clones directory" do
    outside_working_dir = File.join(@temp_dir, "not-a-clone")
    bin_dir = File.join(outside_working_dir, ".npm-cache", "_npx", "7777777777777777", "node_modules", ".bin")
    package_dir = File.join(outside_working_dir, ".npm-cache", "_npx", "7777777777777777", "node_modules", "acme")
    FileUtils.mkdir_p(bin_dir)
    FileUtils.mkdir_p(package_dir)
    target = File.join(package_dir, "index.js")
    File.write(target, "#!/usr/bin/env node\n")
    File.chmod(0o644, target)
    File.symlink(File.join("..", "acme", "index.js"), File.join(bin_dir, "acme"))

    assert_empty NpxBinExecutableGuard.repair!(working_directory: outside_working_dir, logger: @logger)
    refute File.executable?(target)
  end

  test "a chmod failure on one shim does not abort the rest of the sweep" do
    broken = install_package("8888888888888888", "broken-server")
    healthy_fix = install_package("9999999999999999", "fixable-server")

    original_chmod = File.method(:chmod)
    File.stub(:chmod, ->(mode, path) {
      raise Errno::EPERM, path if path == broken[:target]

      original_chmod.call(mode, path)
    }) do
      assert_equal [ healthy_fix[:target] ], NpxBinExecutableGuard.repair!(
        working_directory: @working_directory, logger: @logger
      )
    end
  end
end
