# frozen_string_literal: true

require "test_helper"

class OrphanCloneFilesystemCleanupJobTest < ActiveJob::TestCase
  setup do
    @clones_base = File.join(Dir.tmpdir, "test-zimmer-clones-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(@clones_base)

    # reclaim_space takes no directory argument — it resolves ClonesDirectory.base
    # itself so no caller can aim recursive deletion elsewhere. Point that at the
    # fixture directory rather than the host's real clones volume.
    ClonesDirectory.stubs(:base).returns(@clones_base)

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

  # --- disk-pressure reclamation ------------------------------------------
  #
  # The pressure path lowers the age bar from 48h to 2h and nothing else. These
  # tests pin the "nothing else" — a pruner that deletes a live session's working
  # directory is far worse than the disk pressure it relieves.

  test "reclaim_space removes orphans past the pressure age threshold" do
    pressure_orphan = File.join(@clones_base, "pulsemcp-main-1770000001-cafebabe")
    FileUtils.mkdir_p(pressure_orphan)
    FileUtils.touch(pressure_orphan, mtime: 4.hours.ago.to_time)

    stub_available_bytes(before: 1_000, after: 5_000)

    # A target the stubbed volume never reaches, so the sweep runs to exhaustion
    # and every eligible directory is visited.
    freed = OrphanCloneFilesystemCleanupJob.reclaim_space(
      target_free_bytes: 1_000_000
    )

    assert_equal 4_000, freed
    assert_not File.directory?(pressure_orphan), "orphan past the pressure threshold should be removed"
    assert_not File.directory?(@orphan_dir), "orphan past the scheduled threshold should be removed too"
    assert File.directory?(@recent_dir), "a directory created just now must survive"
  end

  test "reclaim_space leaves directories younger than the pressure age threshold alone" do
    young_orphan = File.join(@clones_base, "pulsemcp-main-1770000002-11112222")
    FileUtils.mkdir_p(young_orphan)
    FileUtils.touch(young_orphan, mtime: 30.minutes.ago.to_time)

    stub_available_bytes(before: 1_000, after: 1_000)

    OrphanCloneFilesystemCleanupJob.reclaim_space(
      target_free_bytes: 10_000
    )

    assert File.directory?(young_orphan),
      "a directory younger than PRESSURE_AGE_THRESHOLD may still belong to a session that has not " \
      "yet persisted its clone_path"
  end

  test "reclaim_space never removes a clone tracked by a session, however old" do
    session = sessions(:running)
    session.update!(metadata: { "clone_path" => @orphan_dir })

    stub_available_bytes(before: 1_000, after: 1_000)

    OrphanCloneFilesystemCleanupJob.reclaim_space(
      target_free_bytes: 10_000
    )

    assert File.directory?(@orphan_dir), "a tracked clone must survive disk pressure"
  end

  test "reclaim_space never removes a clone owned by a live session" do
    live_dir = File.join(@clones_base, "pulsemcp-main-1770000003-33334444")
    FileUtils.mkdir_p(live_dir)
    FileUtils.touch(live_dir, mtime: 3.days.ago.to_time)
    Session.stubs(:live_clone_paths).returns(Set.new([ File.expand_path(live_dir) ]))

    stub_available_bytes(before: 1_000, after: 1_000)

    OrphanCloneFilesystemCleanupJob.reclaim_space(
      target_free_bytes: 10_000
    )

    assert File.directory?(live_dir), "a live session's clone must survive disk pressure"
  end

  test "reclaim_space stops as soon as the target is met" do
    older = File.join(@clones_base, "pulsemcp-main-1770000004-55556666")
    newer = File.join(@clones_base, "pulsemcp-main-1770000005-77778888")
    FileUtils.mkdir_p(older)
    FileUtils.mkdir_p(newer)
    FileUtils.touch(older, mtime: 5.days.ago.to_time)
    FileUtils.touch(newer, mtime: 4.hours.ago.to_time)

    # `older` is unambiguously the oldest, so it is deleted first; the volume then
    # reports enough room and the loop stops with @orphan_dir and `newer` intact.
    stub_available_bytes(before: 1_000, after: 9_999)

    OrphanCloneFilesystemCleanupJob.reclaim_space(
      target_free_bytes: 5_000
    )

    assert_not File.directory?(older), "the oldest orphan is reclaimed first"
    assert File.directory?(@orphan_dir), "reclamation stops once the target is met"
    assert File.directory?(newer), "reclamation stops once the target is met"
    assert File.directory?(@recent_dir)
  end

  test "reclaim_space returns zero when nothing is eligible" do
    FileUtils.rm_rf(@orphan_dir)
    stub_available_bytes(before: 1_000, after: 1_000)

    freed = OrphanCloneFilesystemCleanupJob.reclaim_space(
      target_free_bytes: 10_000
    )

    assert_equal 0, freed
  end

  test "reclaim_space returns zero for a clones base that does not exist" do
    ClonesDirectory.stubs(:base).returns(File.join(@clones_base, "missing"))

    assert_equal 0, OrphanCloneFilesystemCleanupJob.reclaim_space(target_free_bytes: 10_000)
  end

  test "reclaim_space keeps going when one deletion fails" do
    other = File.join(@clones_base, "pulsemcp-main-1770000006-99990000")
    FileUtils.mkdir_p(other)
    FileUtils.touch(other, mtime: 4.hours.ago.to_time)

    stub_available_bytes(before: 1_000, after: 1_000)
    DockerComposeCleanupService.stubs(:cleanup).with(@orphan_dir).raises(StandardError, "docker down")
    DockerComposeCleanupService.stubs(:cleanup).with(other)

    OrphanCloneFilesystemCleanupJob.reclaim_space(
      target_free_bytes: 10_000
    )

    assert File.directory?(@orphan_dir), "the failing directory is left for the next sweep"
    assert_not File.directory?(other), "the other orphan is still reclaimed"
  end

  test "the scheduled sweep still uses the patient age threshold" do
    pressure_only = File.join(@clones_base, "pulsemcp-main-1770000007-aaaabbbb")
    FileUtils.mkdir_p(pressure_only)
    FileUtils.touch(pressure_only, mtime: 4.hours.ago.to_time)

    job = OrphanCloneFilesystemCleanupJob.new
    orphans = job.send(:find_orphan_directories, @clones_base)

    assert_not_includes orphans, pressure_only,
      "4 hours is past PRESSURE_AGE_THRESHOLD but well inside AGE_THRESHOLD"
    assert_includes orphans, @orphan_dir
  end

  private

  # The reclamation loop probes free space through CloneDiskGuard; stub the
  # volume so these tests do not depend on the host's actual disk.
  def stub_available_bytes(before:, after:)
    CloneDiskGuard.stubs(:available_bytes).returns(before).then.returns(after)
  end
end
