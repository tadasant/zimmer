# frozen_string_literal: true

require "test_helper"

class AtomicCloneRemovalTest < ActiveSupport::TestCase
  setup do
    @base = File.join(Dir.tmpdir, "test-zimmer-clones-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(@base)

    @clone = File.join(@base, "zimmer-main-1770000000-deadbeef")
    FileUtils.mkdir_p(File.join(@clone, ".github", "workflows"))
    File.write(File.join(@clone, ".github", "workflows", "ci.yml"), "name: ci\n")
    File.write(File.join(@clone, "README.md"), "hello\n")
  end

  teardown do
    FileUtils.rm_rf(@base) if @base && File.directory?(@base)
  end

  def tombstones
    Dir.children(@base).select { |entry| AtomicCloneRemoval.tombstone?(entry) }
  end

  test "removes the clone tree and leaves no tombstone behind" do
    assert AtomicCloneRemoval.remove(@clone)

    assert_not File.exist?(@clone)
    assert_empty tombstones
    assert_equal [], Dir.children(@base)
  end

  test "an interrupt between the rename and the delete leaves a tombstone, never a half-tree at the clone path" do
    file_system = RealFileSystemAdapter.new
    file_system.stubs(:rm_rf).raises(Errno::EIO, "simulated interrupt")

    assert_raises(Errno::EIO) do
      AtomicCloneRemoval.remove(@clone, file_system: file_system)
    end

    assert_not File.exist?(@clone), "the clone path must be gone the instant the rename lands"
    assert_equal 1, tombstones.size

    # The whole tree survives under the tombstone — nothing was unlinked in place.
    tombstone = File.join(@base, tombstones.first)
    assert File.exist?(File.join(tombstone, "README.md"))
    assert File.exist?(File.join(tombstone, ".github", "workflows", "ci.yml"))
  end

  test "a leftover tombstone is reaped by the next sweep" do
    file_system = RealFileSystemAdapter.new
    file_system.stubs(:rm_rf).raises(Errno::EIO, "simulated interrupt")
    assert_raises(Errno::EIO) { AtomicCloneRemoval.remove(@clone, file_system: file_system) }
    assert_equal 1, tombstones.size

    assert_equal 1, AtomicCloneRemoval.reap_tombstones(@base)
    assert_empty tombstones
  end

  test "reap_tombstones never touches a real clone" do
    tombstone = File.join(@base, "zimmer-main-1770000000-cafebabe.deleting-0123abcd")
    FileUtils.mkdir_p(tombstone)

    assert_equal 1, AtomicCloneRemoval.reap_tombstones(@base)

    assert_not File.exist?(tombstone)
    assert File.directory?(@clone), "a clone directory must survive a tombstone reap"
  end

  test "reap_tombstones honors its limit and leaves the rest for the next run" do
    5.times { |i| FileUtils.mkdir_p(File.join(@base, "zimmer-main-177000000#{i}-aaaaaaaa.deleting-0123abc#{i}")) }

    assert_equal 2, AtomicCloneRemoval.reap_tombstones(@base, limit: 2)
    assert_equal 3, tombstones.size
  end

  test "reap_tombstones does not count a tombstone that survived the delete" do
    # FileUtils.rm_rf is rm_r(force: true): it swallows every error and returns
    # normally, so a tombstone with an unwritable subtree would otherwise be
    # reported as reaped on every run, forever, while sitting on disk.
    tombstone = File.join(@base, "zimmer-main-1770000000-cafebabe.deleting-0123abcd")
    FileUtils.mkdir_p(tombstone)
    FileUtils.stubs(:rm_rf).returns([ tombstone ])

    assert_equal 0, AtomicCloneRemoval.reap_tombstones(@base)
    assert File.directory?(tombstone), "the fixture must still be there — otherwise this proves nothing"
  end

  test "reap_tombstones takes a tombstone that is not a directory" do
    # ForkSessionService disposes of a destination that may be "a partially written
    # tree, a bare directory, or nothing", so a tombstone is not always a directory.
    file_tombstone = File.join(@base, "zimmer-main-1770000000-cafebabe.deleting-0123abcd")
    File.write(file_tombstone, "not a directory")
    dangling = File.join(@base, "zimmer-main-1770000001-cafebabe.deleting-0123abce")
    File.symlink(File.join(@base, "gone"), dangling)

    assert_equal 2, AtomicCloneRemoval.reap_tombstones(@base)

    assert_not File.exist?(file_tombstone)
    assert_not File.symlink?(dangling)
  end

  test "reap_tombstones is a no-op on a base that does not exist" do
    assert_equal 0, AtomicCloneRemoval.reap_tombstones(File.join(@base, "nope"))
    assert_equal 0, AtomicCloneRemoval.reap_tombstones(nil)
  end

  test "a rename that cannot be done degrades to an in-place delete rather than skipping it" do
    file_system = RealFileSystemAdapter.new
    file_system.stubs(:rename).raises(Errno::EXDEV, "simulated cross-device rename")

    assert AtomicCloneRemoval.remove(@clone, file_system: file_system)

    assert_not File.exist?(@clone), "the clone must still be deleted when the rename is impossible"
    assert_empty tombstones
  end

  test "a clone that vanished under the rename is not an error" do
    file_system = RealFileSystemAdapter.new
    file_system.stubs(:rename).raises(Errno::ENOENT, "gone")

    assert_not AtomicCloneRemoval.remove(@clone, file_system: file_system)
  end

  test "removing a path that is already a tombstone deletes it in place instead of nesting tombstones" do
    tombstone = File.join(@base, "zimmer-main-1770000000-cafebabe.deleting-0123abcd")
    FileUtils.mkdir_p(tombstone)

    assert AtomicCloneRemoval.remove(tombstone)

    assert_not File.exist?(tombstone)
    assert_empty tombstones
  end

  test "an empty clone directory handed over as a Pathname is still removed" do
    # Pathname answers `empty?`, and Pathname#empty? is true for an empty
    # DIRECTORY — so a `blank?` guard here would silently decline to delete a clone
    # whose `git clone` was killed before it wrote anything. Two call sites hand
    # this a Pathname.
    empty_clone = File.join(@base, "zimmer-main-1770000000-0badf00d")
    FileUtils.mkdir_p(empty_clone)

    assert AtomicCloneRemoval.remove(Pathname.new(empty_clone))

    assert_not File.exist?(empty_clone)
    assert_empty tombstones
  end

  test "a missing or blank path is a no-op" do
    assert_not AtomicCloneRemoval.remove(File.join(@base, "never-existed"))
    assert_not AtomicCloneRemoval.remove(nil)
    assert_not AtomicCloneRemoval.remove("")
  end

  test "tombstone? matches only the deletion marker" do
    assert AtomicCloneRemoval.tombstone?("zimmer-main-1770000000-deadbeef.deleting-0123abcd")
    assert AtomicCloneRemoval.tombstone?("/var/clones/zimmer-main-1770000000-deadbeef.deleting-0123abcd")

    assert_not AtomicCloneRemoval.tombstone?("zimmer-main-1770000000-deadbeef")
    assert_not AtomicCloneRemoval.tombstone?("zimmer-deleting-main-1770000000-deadbeef")
    assert_not AtomicCloneRemoval.tombstone?("zimmer-main-1770000000-deadbeef.deleting-nothex01")
  end

  test "the tombstone is a sibling of the clone, so the rename stays on one filesystem" do
    tombstone = AtomicCloneRemoval.tombstone_path_for(@clone)

    assert_equal @base, File.dirname(tombstone)
    assert AtomicCloneRemoval.tombstone?(tombstone)
    assert_not_equal tombstone, AtomicCloneRemoval.tombstone_path_for(@clone), "each removal gets its own tombstone"
  end

  test "a trailing separator on the clone path does not push the tombstone into the tree" do
    tombstone = AtomicCloneRemoval.tombstone_path_for("#{@clone}/")

    assert_equal @base, File.dirname(tombstone)
  end

  test "works through an injected adapter" do
    file_system = MockFileSystemAdapter.new
    file_system.mkdir_p("/clones/zimmer-main-1-a/.github")
    file_system.write("/clones/zimmer-main-1-a/README.md", "hi")

    assert AtomicCloneRemoval.remove("/clones/zimmer-main-1-a", file_system: file_system)

    assert_not file_system.exists?("/clones/zimmer-main-1-a")
    assert_not file_system.exists?("/clones/zimmer-main-1-a/README.md")
    assert_empty file_system.directories.select { |d| AtomicCloneRemoval.tombstone?(d) }
  end
end
