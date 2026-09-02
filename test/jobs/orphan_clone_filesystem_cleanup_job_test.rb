# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

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

  # zimmer#808. `find_orphan_directories` builds its ownership snapshot before the
  # loop, and each removal costs a Docker Compose teardown bounded at 120s plus a
  # recursive delete. Blinding the snapshot leaves only the guard that asks at the
  # instant of deletion.
  test "refuses to remove a clone a live session owns even when the orphan snapshot missed it" do
    session = sessions(:running)
    session.update!(metadata: { "clone_path" => @orphan_dir })

    job = OrphanCloneFilesystemCleanupJob.new
    job.stubs(:find_orphan_directories).returns([ @orphan_dir ])

    job.perform

    assert File.directory?(@orphan_dir), "a live session's clone must survive the orphan sweep"
  end

  test "does not remove directories tracked by sessions" do
    session = sessions(:running)
    session.update!(metadata: { "clone_path" => @orphan_dir })

    job = OrphanCloneFilesystemCleanupJob.new
    orphans = job.send(:find_orphan_directories, @clones_base)

    assert_not_includes orphans, @orphan_dir, "Tracked directory should not be identified as orphan"
  end

  test "a clone saved only by its basename is flagged as clone_path drift" do
    # The stored path is under a different base, so only the basename identifies
    # it. The directory is safe either way; the point is that nothing else in the
    # pipeline would notice the drift (#671). StaleCloneCleanupJob's removed
    # sweep carried this tripwire; it lives here now.
    sessions(:running).update!(
      metadata: { "clone_path" => File.join("/some/relocated/base", File.basename(@orphan_dir)) }
    )

    job = OrphanCloneFilesystemCleanupJob.new
    job.expects(:flag_path_drift).once

    assert_not_includes job.send(:find_orphan_directories, @clones_base), @orphan_dir
  end

  test "a tracked clone whose stored path matches exactly is silent — drift is the only thing worth saying" do
    sessions(:running).update!(metadata: { "clone_path" => @orphan_dir })

    Rails.logger.expects(:warn).with(regexp_matches(/matched by basename, not by path/)).never

    job = OrphanCloneFilesystemCleanupJob.new
    assert_not_includes job.send(:find_orphan_directories, @clones_base), @orphan_dir
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

  test "reclaim_space stops when the wall-clock budget is exhausted" do
    # This loop runs synchronously on the session launch path and cleanup_orphan
    # tears down Docker Compose first (120s cap each), so an unbounded sweep would
    # wedge the session in `waiting` for hours.
    other = File.join(@clones_base, "pulsemcp-main-1770000008-ccccdddd")
    FileUtils.mkdir_p(other)
    FileUtils.touch(other, mtime: 4.hours.ago.to_time)

    stub_available_bytes(before: 1_000, after: 1_000)
    job = OrphanCloneFilesystemCleanupJob.new
    # First check starts the clock, second reports the budget already blown.
    job.stubs(:monotonic_now).returns(0).then.returns(OrphanCloneFilesystemCleanupJob::RECLAIM_BUDGET_SECONDS + 1)

    job.reclaim_space(target_free_bytes: 10_000)

    assert File.directory?(@orphan_dir), "no removal should happen once the budget is gone"
    assert File.directory?(other)
  end

  test "the durable volume is not reapable outside production or staging" do
    # Orphan-hood is a set difference against the CONNECTED database. `bin/rails
    # test` and `bin/dev` both resolve the clones base to ~/.zimmer/clones, so on
    # a machine that also hosts a real Zimmer they would compute every live clone
    # as an orphan. This test runs in `test`, which is exactly that case.
    durable_base = File.join(File.expand_path("~"), ".zimmer", "clones")
    job = OrphanCloneFilesystemCleanupJob.new

    assert_not job.send(:reclaimable_root?, durable_base)
  end

  test "the durable volume is reapable in the deployments that own it" do
    durable_base = File.join(File.expand_path("~"), ".zimmer", "clones")
    job = OrphanCloneFilesystemCleanupJob.new

    OrphanCloneFilesystemCleanupJob::SWEEPS_DEFAULT_DURABLE_ROOT.each do |env|
      Rails.stubs(:env).returns(ActiveSupport::StringInquirer.new(env))
      assert job.send(:reclaimable_root?, durable_base), "#{env} owns the volume and must be able to reap it"
    end
  end

  test "a relocated clones base is reapable anywhere" do
    # The fixture base is already outside ~/.zimmer, which is exactly the
    # AGENT_CLONES_DIR case: no fence, because no live deployment owns it.
    assert OrphanCloneFilesystemCleanupJob.new.send(:reclaimable_root?, @clones_base)
  end

  test "reclaim_space does nothing when the root is fenced" do
    OrphanCloneFilesystemCleanupJob.any_instance.stubs(:reclaimable_root?).returns(false)
    OrphanCloneFilesystemCleanupJob.any_instance.expects(:find_orphan_directories).never

    assert_equal 0, OrphanCloneFilesystemCleanupJob.reclaim_space(target_free_bytes: 10_000)
    assert File.directory?(@orphan_dir)
  end

  test "the scheduled sweep does nothing when the root is fenced" do
    OrphanCloneFilesystemCleanupJob.any_instance.stubs(:reclaimable_root?).returns(false)
    OrphanCloneFilesystemCleanupJob.any_instance.expects(:find_orphan_directories).never

    OrphanCloneFilesystemCleanupJob.new.perform

    assert File.directory?(@orphan_dir)
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

  # --- interrupted-delete tombstones (#412) --------------------------------
  #
  # AtomicCloneRemoval renames a clone to `<clone>.deleting-<hex>` before deleting
  # it, so an interrupt leaves a tombstone rather than a half-tree wearing the
  # clone's name. A tombstone is not a clone: this sweep must never reason about
  # it as one, and must take the bytes back.

  test "a deletion tombstone is never identified as an orphan clone" do
    tombstone = File.join(@clones_base, "pulsemcp-main-1770000009-eeeeffff.deleting-0123abcd")
    FileUtils.mkdir_p(tombstone)
    FileUtils.touch(tombstone, mtime: 3.days.ago.to_time)

    orphans = OrphanCloneFilesystemCleanupJob.new.send(:find_orphan_directories, @clones_base)

    assert_not_includes orphans, tombstone,
      "a tombstone belongs to the tombstone reaper, not to the ownership-and-age sweep"
  end

  test "the scheduled sweep reaps leftover tombstones" do
    tombstone = File.join(@clones_base, "pulsemcp-main-1770000010-eeeeffff.deleting-0123abcd")
    FileUtils.mkdir_p(File.join(tombstone, "app"))

    OrphanCloneFilesystemCleanupJob.new.perform

    assert_not File.exist?(tombstone), "an interrupted delete must not leave bytes on the volume forever"
  end

  test "a tombstone is reaped however young it is" do
    # No age bar applies: a tombstone is doomed the moment it is created, so the
    # startup race the age thresholds exist for cannot apply to one.
    tombstone = File.join(@clones_base, "pulsemcp-main-1770000011-eeeeffff.deleting-0123abcd")
    FileUtils.mkdir_p(tombstone)

    OrphanCloneFilesystemCleanupJob.new.perform

    assert_not File.exist?(tombstone)
    assert File.directory?(@recent_dir), "a real clone still gets the age bar"
  end

  test "reclaim_space takes tombstones first and stops there when that is enough" do
    tombstone = File.join(@clones_base, "pulsemcp-main-1770000012-eeeeffff.deleting-0123abcd")
    FileUtils.mkdir_p(tombstone)
    stub_available_bytes(before: 1_000, after: 9_999)

    freed = OrphanCloneFilesystemCleanupJob.reclaim_space(target_free_bytes: 5_000)

    assert_equal 8_999, freed
    assert_not File.exist?(tombstone)
    assert File.directory?(@orphan_dir),
      "the cheapest bytes on the volume are the doomed ones; no orphan clone should have been touched"
  end

  test "reclaim_space falls through to orphan clones when reaping tombstones is not enough" do
    tombstone = File.join(@clones_base, "pulsemcp-main-1770000013-eeeeffff.deleting-0123abcd")
    FileUtils.mkdir_p(tombstone)
    stub_available_bytes(before: 1_000, after: 1_000)

    OrphanCloneFilesystemCleanupJob.reclaim_space(target_free_bytes: 1_000_000)

    assert_not File.exist?(tombstone)
    assert_not File.directory?(@orphan_dir), "the orphan sweep still runs when the volume is still short"
  end

  private

  # The reclamation loop probes free space through CloneDiskGuard; stub the
  # volume so these tests do not depend on the host's actual disk.
  def stub_available_bytes(before:, after:)
    CloneDiskGuard.stubs(:available_bytes).returns(before).then.returns(after)
  end
end
