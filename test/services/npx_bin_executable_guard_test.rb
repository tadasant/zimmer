# frozen_string_literal: true

require "test_helper"

class NpxBinExecutableGuardTest < ActiveSupport::TestCase
  setup do
    @temp_dir = Dir.mktmpdir("npx_bin_guard_test")
    @original_home = ENV["HOME"]
    ENV["HOME"] = @temp_dir

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
    FileUtils.rm_rf(@temp_dir) if @temp_dir && File.exist?(@temp_dir)
  end

  # Build the tree npx leaves behind: a package whose entrypoint is linked into
  # `.bin` under the hash dir. `mode` is the entrypoint's mode — 0644 is how
  # onepassword-mcp-server ships (zimmer#467), 0755 is a healthy install.
  def install_package(hash, name = "acme-mcp-server", mode: 0o644, entrypoint: "build/index.js")
    package_dir = File.join(@npx_dir, hash, "node_modules", name)
    target = File.join(package_dir, entrypoint)
    FileUtils.mkdir_p(File.dirname(target))
    File.write(target, "#!/usr/bin/env node\n")
    File.chmod(mode, target)

    bin_dir = File.join(@npx_dir, hash, "node_modules", ".bin")
    FileUtils.mkdir_p(bin_dir)
    shim = File.join(bin_dir, name)
    File.symlink(File.join("..", name, entrypoint), shim)

    { shim: shim, target: target }
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
