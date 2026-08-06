# frozen_string_literal: true

require "test_helper"

class CloneDiskGuardTest < ActiveSupport::TestCase
  setup do
    @base = File.join(Dir.tmpdir, "clone-disk-guard-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(@base)
  end

  teardown do
    FileUtils.rm_rf(@base) if @base && File.directory?(@base)
  end

  # --- available_bytes -----------------------------------------------------

  test "available_bytes reports a positive figure for a real directory" do
    bytes = CloneDiskGuard.available_bytes(@base)

    assert_kind_of Integer, bytes
    assert_operator bytes, :>, 0
  end

  test "available_bytes returns nil for a path that does not exist" do
    assert_nil CloneDiskGuard.available_bytes(File.join(@base, "nope"))
  end

  test "available_bytes returns nil when df fails" do
    CloneDiskGuard.stubs(:logger).returns(stub_everything)
    BoundedSubprocess.stubs(:run).returns([ "", "df: bad", failed_status ])

    assert_nil CloneDiskGuard.available_bytes(@base)
  end

  test "available_bytes returns nil when df output cannot be parsed" do
    CloneDiskGuard.stubs(:logger).returns(stub_everything)
    BoundedSubprocess.stubs(:run).returns([ "Filesystem 1024-blocks\n", "", success_status ])

    assert_nil CloneDiskGuard.available_bytes(@base)
  end

  test "available_bytes parses POSIX df output into bytes" do
    df_output = <<~DF
      Filesystem     1024-blocks     Used Available Capacity Mounted on
      /dev/sda1         41251136 12345678   2097152      24% /
    DF
    BoundedSubprocess.stubs(:run).returns([ df_output, "", success_status ])

    assert_equal 2_097_152 * 1024, CloneDiskGuard.available_bytes(@base)
  end

  # --- sizing --------------------------------------------------------------

  test "required_bytes falls back to the floor when no prior clone exists" do
    assert_equal CloneDiskGuard::MINIMUM_FREE_BYTES,
      CloneDiskGuard.required_bytes("https://github.com/acme/widget.git", base: @base)
  end

  test "required_bytes derives from a prior clone of the same repo" do
    # 4 GiB prior clone => 8 GiB derived, above the 2 GiB floor and under the cap.
    prior = File.join(@base, "widget-main-1770000000-abcd1234")
    FileUtils.mkdir_p(prior)
    CloneDiskGuard.stubs(:directory_size).with(prior).returns(4 * 1024**3)

    assert_equal 8 * 1024**3,
      CloneDiskGuard.required_bytes("https://github.com/acme/widget.git", base: @base)
  end

  test "required_bytes never drops below the floor for a tiny prior clone" do
    prior = File.join(@base, "widget-main-1770000000-abcd1234")
    FileUtils.mkdir_p(prior)
    CloneDiskGuard.stubs(:directory_size).with(prior).returns(10 * 1024 * 1024)

    assert_equal CloneDiskGuard::MINIMUM_FREE_BYTES,
      CloneDiskGuard.required_bytes("https://github.com/acme/widget.git", base: @base)
  end

  test "required_bytes caps a pathologically large prior clone" do
    CloneDiskGuard.stubs(:logger).returns(stub_everything)
    prior = File.join(@base, "widget-main-1770000000-abcd1234")
    FileUtils.mkdir_p(prior)
    CloneDiskGuard.stubs(:directory_size).with(prior).returns(500 * 1024**3)

    assert_equal CloneDiskGuard::MAXIMUM_REQUIRED_BYTES,
      CloneDiskGuard.required_bytes("https://github.com/acme/widget.git", base: @base)
  end

  test "measure_recent_clone ignores clones of other repositories" do
    FileUtils.mkdir_p(File.join(@base, "other-main-1770000000-abcd1234"))

    assert_nil CloneDiskGuard.measure_recent_clone("https://github.com/acme/widget.git", base: @base)
  end

  test "measure_recent_clone picks the most recently modified matching clone" do
    old_clone = File.join(@base, "widget-main-1770000000-aaaaaaaa")
    new_clone = File.join(@base, "widget-main-1780000000-bbbbbbbb")
    FileUtils.mkdir_p(old_clone)
    FileUtils.mkdir_p(new_clone)
    FileUtils.touch(old_clone, mtime: 3.days.ago.to_time)
    FileUtils.touch(new_clone, mtime: 1.minute.ago.to_time)

    CloneDiskGuard.expects(:directory_size).with(new_clone).returns(123)

    assert_equal 123, CloneDiskGuard.measure_recent_clone("git@github.com:acme/widget.git", base: @base)
  end

  test "measure_recent_clone returns nil for a blank repository url" do
    assert_nil CloneDiskGuard.measure_recent_clone("", base: @base)
  end

  test "directory_size measures a real directory" do
    payload = File.join(@base, "payload")
    FileUtils.mkdir_p(payload)
    File.binwrite(File.join(payload, "blob"), "x" * 200_000)

    size = CloneDiskGuard.directory_size(payload)

    assert_kind_of Integer, size
    assert_operator size, :>=, 200_000
  end

  test "directory_size returns nil when du times out" do
    CloneDiskGuard.stubs(:logger).returns(stub_everything)
    BoundedSubprocess.stubs(:run).raises(BoundedSubprocess::TimeoutError, "timed out")

    assert_nil CloneDiskGuard.directory_size(@base)
  end

  # --- ensure_space! -------------------------------------------------------

  test "ensure_space! permits the clone when there is room" do
    CloneDiskGuard.stubs(:available_bytes).returns(50 * 1024**3)
    OrphanCloneFilesystemCleanupJob.expects(:reclaim_space).never

    assert_nothing_raised do
      CloneDiskGuard.ensure_space!(repository_url: "https://github.com/acme/widget.git", base: @base)
    end
  end

  test "ensure_space! fails open when free space cannot be determined" do
    CloneDiskGuard.stubs(:logger).returns(stub_everything)
    CloneDiskGuard.stubs(:available_bytes).returns(nil)
    OrphanCloneFilesystemCleanupJob.expects(:reclaim_space).never

    assert_nothing_raised do
      CloneDiskGuard.ensure_space!(repository_url: "https://github.com/acme/widget.git", base: @base)
    end
  end

  test "ensure_space! prunes and proceeds when reclamation frees enough" do
    CloneDiskGuard.stubs(:logger).returns(stub_everything)
    CloneDiskGuard.stubs(:available_bytes)
      .returns(1024)         # first probe: far short
      .then.returns(50 * 1024**3) # after reclamation: plenty
    OrphanCloneFilesystemCleanupJob.expects(:reclaim_space).once.returns(50 * 1024**3)

    assert_nothing_raised do
      CloneDiskGuard.ensure_space!(repository_url: "https://github.com/acme/widget.git", base: @base)
    end
  end

  test "ensure_space! raises an actionable error when reclamation is not enough" do
    CloneDiskGuard.stubs(:logger).returns(stub_everything)
    CloneDiskGuard.stubs(:available_bytes).returns(100 * 1024 * 1024)
    OrphanCloneFilesystemCleanupJob.expects(:reclaim_space).once.returns(0)

    error = assert_raises(CloneDiskGuard::InsufficientDiskSpaceError) do
      CloneDiskGuard.ensure_space!(repository_url: "https://github.com/acme/widget.git", base: @base)
    end

    assert_includes error.message, @base
    assert_includes error.message, "100.0 MB free"
    assert_includes error.message, "2.0 GB required"
    assert_includes error.message, "grow the volume"
  end

  test "ensure_space! still raises when reclamation itself blows up" do
    CloneDiskGuard.stubs(:logger).returns(stub_everything)
    CloneDiskGuard.stubs(:available_bytes).returns(1024)
    OrphanCloneFilesystemCleanupJob.stubs(:reclaim_space).raises(StandardError, "sweeper exploded")

    assert_raises(CloneDiskGuard::InsufficientDiskSpaceError) do
      CloneDiskGuard.ensure_space!(repository_url: "https://github.com/acme/widget.git", base: @base)
    end
  end

  test "human_bytes formats in the largest fitting unit" do
    assert_equal "0 B", CloneDiskGuard.human_bytes(0)
    assert_equal "0 B", CloneDiskGuard.human_bytes(nil)
    assert_equal "512.0 B", CloneDiskGuard.human_bytes(512)
    assert_equal "1.0 KB", CloneDiskGuard.human_bytes(1024)
    assert_equal "2.0 GB", CloneDiskGuard.human_bytes(2 * 1024**3)
  end

  private

  # Real Process::Status objects, so SubprocessStatus is exercised rather than
  # stubbed out.
  def success_status
    exit_status(0)
  end

  def failed_status
    exit_status(1)
  end

  def exit_status(code)
    _pid, status = Process.wait2(Process.spawn("/bin/sh", "-c", "exit #{code}"))
    status
  end
end
