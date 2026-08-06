# frozen_string_literal: true

require "test_helper"

class CloneDiskGuardTest < ActiveSupport::TestCase
  # A volume with more room than any requirement can ask for, which is the
  # short-circuit ensure_space! takes on a healthy host.
  ROOMY = CloneDiskGuard::MAXIMUM_REQUIRED_BYTES * 5

  setup do
    @base = File.join(Dir.tmpdir, "clone-disk-guard-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(@base)
  end

  teardown do
    FileUtils.rm_rf(@base) if @base && File.directory?(@base)
  end

  # --- volume_stats / available_bytes --------------------------------------

  test "volume_stats reports total and available for a real directory" do
    stats = CloneDiskGuard.volume_stats(@base)

    assert_kind_of Integer, stats[:total]
    assert_kind_of Integer, stats[:available]
    assert_operator stats[:total], :>, 0
    assert_operator stats[:available], :>=, 0
  end

  test "volume_stats returns nil for a path that does not exist" do
    assert_nil CloneDiskGuard.volume_stats(File.join(@base, "nope"))
  end

  test "volume_stats returns nil when df fails" do
    CloneDiskGuard.stubs(:logger).returns(stub_everything)
    BoundedSubprocess.stubs(:run).returns([ "", "df: bad", failed_status ])

    assert_nil CloneDiskGuard.volume_stats(@base)
  end

  test "volume_stats returns nil when df output cannot be parsed" do
    CloneDiskGuard.stubs(:logger).returns(stub_everything)
    BoundedSubprocess.stubs(:run).returns([ "Filesystem 1024-blocks\n", "", success_status ])

    assert_nil CloneDiskGuard.volume_stats(@base)
  end

  test "volume_stats returns nil when df raises an unexpected errno" do
    CloneDiskGuard.stubs(:logger).returns(stub_everything)
    BoundedSubprocess.stubs(:run).raises(Errno::EMFILE)

    assert_nil CloneDiskGuard.volume_stats(@base)
  end

  test "volume_stats parses POSIX df output into bytes" do
    df_output = <<~DF
      Filesystem     1024-blocks     Used Available Capacity Mounted on
      /dev/sda1         41251136 12345678   2097152      24% /
    DF
    BoundedSubprocess.stubs(:run).returns([ df_output, "", success_status ])

    stats = CloneDiskGuard.volume_stats(@base)

    assert_equal 41_251_136 * 1024, stats[:total]
    assert_equal 2_097_152 * 1024, stats[:available]
  end

  test "available_bytes reads the available figure from volume_stats" do
    CloneDiskGuard.stubs(:volume_stats).with(@base).returns({ total: 100, available: 42 })

    assert_equal 42, CloneDiskGuard.available_bytes(@base)
  end

  test "available_bytes is nil when the volume cannot be measured" do
    CloneDiskGuard.stubs(:volume_stats).returns(nil)

    assert_nil CloneDiskGuard.available_bytes(@base)
  end

  # --- sizing --------------------------------------------------------------

  test "required_bytes falls back to the floor when no prior clone exists" do
    assert_equal CloneDiskGuard::MINIMUM_FREE_BYTES,
      CloneDiskGuard.required_bytes("https://github.com/acme/widget.git", base: @base)
  end

  test "required_bytes derives from the .git directory of a prior clone" do
    # A 3 GiB object store => 6 GiB derived: above the 2 GiB floor, under the cap.
    git_dir = prior_clone("widget-main-1770000000-abcd1234")
    CloneDiskGuard.stubs(:directory_size).with(git_dir).returns(3 * 1024**3)

    assert_equal 6 * 1024**3,
      CloneDiskGuard.required_bytes("https://github.com/acme/widget.git", base: @base)
  end

  test "required_bytes never drops below the floor for a tiny prior clone" do
    git_dir = prior_clone("widget-main-1770000000-abcd1234")
    CloneDiskGuard.stubs(:directory_size).with(git_dir).returns(10 * 1024 * 1024)

    assert_equal CloneDiskGuard::MINIMUM_FREE_BYTES,
      CloneDiskGuard.required_bytes("https://github.com/acme/widget.git", base: @base)
  end

  test "required_bytes caps a pathologically large prior clone" do
    CloneDiskGuard.stubs(:logger).returns(stub_everything)
    git_dir = prior_clone("widget-main-1770000000-abcd1234")
    CloneDiskGuard.stubs(:directory_size).with(git_dir).returns(500 * 1024**3)

    assert_equal CloneDiskGuard::MAXIMUM_REQUIRED_BYTES,
      CloneDiskGuard.required_bytes("https://github.com/acme/widget.git", base: @base)
  end

  test "required_bytes never asks a small volume for more than its fraction" do
    # A 3 GiB disk cannot be asked for the 2 GiB floor: that turns a host which
    # was cloning small repos perfectly well into one where nothing launches.
    CloneDiskGuard.stubs(:logger).returns(stub_everything)
    total = 3 * 1024**3

    required = CloneDiskGuard.required_bytes(
      "https://github.com/acme/widget.git", base: @base, total: total
    )

    assert_equal (total * CloneDiskGuard::MAX_VOLUME_FRACTION).to_i, required
    assert_operator required, :<, CloneDiskGuard::MINIMUM_FREE_BYTES
  end

  test "measure_recent_clone ignores clones of other repositories" do
    prior_clone("other-main-1770000000-abcd1234")

    assert_nil CloneDiskGuard.measure_recent_clone("https://github.com/acme/widget.git", base: @base)
  end

  test "measure_recent_clone ignores a directory with no .git" do
    FileUtils.mkdir_p(File.join(@base, "widget-main-1770000000-abcd1234"))

    assert_nil CloneDiskGuard.measure_recent_clone("https://github.com/acme/widget.git", base: @base)
  end

  test "measure_recent_clone picks the most recently modified matching clone" do
    old_git = prior_clone("widget-main-1770000000-aaaaaaaa", mtime: 3.days.ago.to_time)
    new_git = prior_clone("widget-main-1780000000-bbbbbbbb", mtime: 1.minute.ago.to_time)

    # `expects` with an exact argument: sizing the older clone would surface as an
    # unexpected invocation.
    assert old_git
    CloneDiskGuard.expects(:directory_size).with(new_git).returns(123)

    assert_equal 123, CloneDiskGuard.measure_recent_clone("git@github.com:acme/widget.git", base: @base)
  end

  test "measure_recent_clone returns nil for a blank repository url" do
    assert_nil CloneDiskGuard.measure_recent_clone("", base: @base)
  end

  test "directory_size measures a real directory" do
    payload = File.join(@base, "payload")
    FileUtils.mkdir_p(payload)
    # Incompressible: `du` reports allocated blocks, and a compressing filesystem
    # (btrfs compress-force, ZFS lz4) would shrink a run of identical bytes to
    # almost nothing.
    File.binwrite(File.join(payload, "blob"), SecureRandom.bytes(200_000))

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

  test "ensure_space! permits the clone when there is room, without sizing" do
    CloneDiskGuard.stubs(:volume_stats).returns({ total: ROOMY, available: ROOMY })
    # The whole point of the short-circuit: a healthy host pays one df and no du.
    CloneDiskGuard.expects(:directory_size).never
    OrphanCloneFilesystemCleanupJob.expects(:reclaim_space).never

    assert_nothing_raised do
      CloneDiskGuard.ensure_space!(repository_url: "https://github.com/acme/widget.git", base: @base)
    end
  end

  test "ensure_space! permits the clone when free space clears the derived requirement" do
    free = CloneDiskGuard::MINIMUM_FREE_BYTES + 1
    CloneDiskGuard.stubs(:volume_stats).returns({ total: 500 * 1024**3, available: free })
    OrphanCloneFilesystemCleanupJob.expects(:reclaim_space).never

    assert_nothing_raised do
      CloneDiskGuard.ensure_space!(repository_url: "https://github.com/acme/widget.git", base: @base)
    end
  end

  test "ensure_space! fails open when free space cannot be determined" do
    CloneDiskGuard.stubs(:logger).returns(stub_everything)
    CloneDiskGuard.stubs(:volume_stats).returns(nil)
    OrphanCloneFilesystemCleanupJob.expects(:reclaim_space).never

    assert_nothing_raised do
      CloneDiskGuard.ensure_space!(repository_url: "https://github.com/acme/widget.git", base: @base)
    end
  end

  test "ensure_space! prunes and proceeds when reclamation frees enough" do
    CloneDiskGuard.stubs(:logger).returns(stub_everything)
    CloneDiskGuard.stubs(:same_device?).returns(true)
    CloneDiskGuard.stubs(:volume_stats)
      .returns({ total: 500 * 1024**3, available: 1024 })      # first probe: far short
      .then.returns({ total: 500 * 1024**3, available: ROOMY }) # after reclamation: plenty
    OrphanCloneFilesystemCleanupJob.expects(:reclaim_space).once.returns(ROOMY)

    assert_nothing_raised do
      CloneDiskGuard.ensure_space!(repository_url: "https://github.com/acme/widget.git", base: @base)
    end
  end

  test "ensure_space! raises an actionable error when reclamation is not enough" do
    CloneDiskGuard.stubs(:logger).returns(stub_everything)
    CloneDiskGuard.stubs(:same_device?).returns(true)
    CloneDiskGuard.stubs(:volume_stats)
      .returns({ total: 500 * 1024**3, available: 100 * 1024 * 1024 })
    OrphanCloneFilesystemCleanupJob.expects(:reclaim_space).once.returns(0)

    error = assert_raises(CloneDiskGuard::InsufficientDiskSpaceError) do
      CloneDiskGuard.ensure_space!(repository_url: "https://github.com/acme/widget.git", base: @base)
    end

    assert_includes error.message, @base
    assert_includes error.message, "100.0 MiB free"
    assert_includes error.message, "2.0 GiB required"
    assert_includes error.message, "grow the volume"
  end

  test "ensure_space! skips reclamation when the guarded volume is not the clones volume" do
    # Deleting real clones cannot relieve pressure on a different device, so the
    # sweeper is never asked — destructive and useless is worse than useless.
    CloneDiskGuard.stubs(:logger).returns(stub_everything)
    CloneDiskGuard.stubs(:same_device?).returns(false)
    CloneDiskGuard.stubs(:volume_stats)
      .returns({ total: 500 * 1024**3, available: 100 * 1024 * 1024 })
    OrphanCloneFilesystemCleanupJob.expects(:reclaim_space).never

    assert_raises(CloneDiskGuard::InsufficientDiskSpaceError) do
      CloneDiskGuard.ensure_space!(repository_url: "https://github.com/acme/widget.git", base: @base)
    end
  end

  test "ensure_space! still raises when reclamation itself blows up" do
    CloneDiskGuard.stubs(:logger).returns(stub_everything)
    CloneDiskGuard.stubs(:same_device?).returns(true)
    CloneDiskGuard.stubs(:volume_stats).returns({ total: 500 * 1024**3, available: 1024 })
    OrphanCloneFilesystemCleanupJob.stubs(:reclaim_space).raises(StandardError, "sweeper exploded")

    assert_raises(CloneDiskGuard::InsufficientDiskSpaceError) do
      CloneDiskGuard.ensure_space!(repository_url: "https://github.com/acme/widget.git", base: @base)
    end
  end

  test "same_device? is false when a path cannot be stat'd" do
    CloneDiskGuard.stubs(:logger).returns(stub_everything)

    assert_not CloneDiskGuard.same_device?(File.join(@base, "missing"), @base)
  end

  test "human_bytes formats in the largest fitting binary unit" do
    assert_equal "0 B", CloneDiskGuard.human_bytes(0)
    assert_equal "0 B", CloneDiskGuard.human_bytes(nil)
    assert_equal "512.0 B", CloneDiskGuard.human_bytes(512)
    assert_equal "1.0 KiB", CloneDiskGuard.human_bytes(1024)
    assert_equal "2.0 GiB", CloneDiskGuard.human_bytes(2 * 1024**3)
  end

  private

  # A directory shaped like a clone of `name`, with a `.git` inside it (which is
  # what measure_recent_clone looks for and sizes). Returns the `.git` path.
  def prior_clone(name, mtime: nil)
    clone_dir = File.join(@base, name)
    git_dir = File.join(clone_dir, ".git")
    FileUtils.mkdir_p(git_dir)
    FileUtils.touch(clone_dir, mtime: mtime) if mtime
    git_dir
  end

  # Real Process::Status objects, so SubprocessStatus is exercised rather than
  # stubbed.
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
