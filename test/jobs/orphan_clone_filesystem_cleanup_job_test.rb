# frozen_string_literal: true

require "test_helper"

class OrphanCloneFilesystemCleanupJobTest < ActiveJob::TestCase
  setup do
    @clones_base = File.join(Dir.tmpdir, "test-zimmer-clones-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(@clones_base)

    # Create an old orphan directory (no matching session)
    @orphan_dir = File.join(@clones_base, "pulsemcp-main-1770000000-deadbeef")
    FileUtils.mkdir_p(@orphan_dir)
    # Set mtime to 3 days ago (past the 48h threshold)
    old_time = 3.days.ago.to_time
    FileUtils.touch(@orphan_dir, mtime: old_time)

    # Create a recent directory (should NOT be cleaned)
    @recent_dir = File.join(@clones_base, "pulsemcp-main-1775900000-abcd1234")
    FileUtils.mkdir_p(@recent_dir)
  end

  teardown do
    FileUtils.rm_rf(@clones_base) if @clones_base && File.directory?(@clones_base)
  end

  test "removes orphan clone directories older than threshold" do
    job = OrphanCloneFilesystemCleanupJob.new
    orphans = job.send(:find_orphan_directories, @clones_base)

    assert_includes orphans, @orphan_dir, "Old orphan directory should be identified"
    assert_not_includes orphans, @recent_dir, "Recent directory should not be identified as orphan"
  end

  test "does not remove directories tracked by sessions" do
    session = sessions(:running)
    session.update!(metadata: { "clone_path" => @orphan_dir })

    job = OrphanCloneFilesystemCleanupJob.new
    orphans = job.send(:find_orphan_directories, @clones_base)

    assert_not_includes orphans, @orphan_dir, "Tracked directory should not be identified as orphan"
  end

  test "cleanup_orphan removes directory and calls docker cleanup" do
    job = OrphanCloneFilesystemCleanupJob.new

    assert File.directory?(@orphan_dir)
    job.send(:cleanup_orphan, @orphan_dir)
    assert_not File.directory?(@orphan_dir), "Orphan directory should be removed"
  end

  test "respects batch limit" do
    # Create more orphans than the batch limit
    extra_dirs = (OrphanCloneFilesystemCleanupJob::BATCH_LIMIT + 5).times.map do |i|
      dir = File.join(@clones_base, "pulsemcp-main-17700000#{i.to_s.rjust(2, '0')}-extra#{i}")
      FileUtils.mkdir_p(dir)
      FileUtils.touch(dir, mtime: 3.days.ago.to_time)
      dir
    end

    job = OrphanCloneFilesystemCleanupJob.new
    orphans = job.send(:find_orphan_directories, @clones_base)

    # Should find all orphans (including the setup one)
    assert orphans.size > OrphanCloneFilesystemCleanupJob::BATCH_LIMIT

    # Cleanup the extra dirs
    extra_dirs.each { |d| FileUtils.rm_rf(d) }
  end
end
