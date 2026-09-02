# frozen_string_literal: true

require "test_helper"

class StaleCloneCleanupJobTest < ActiveJob::TestCase
  setup do
    @session = sessions(:running)
    @session.logs.destroy_all
    # Create a temp clones directory for the tombstone reap
    @clones_base = Dir.mktmpdir("stale-clone-test-clones")

    @clone_path = File.join(@clones_base, "test-stale-clone-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(@clone_path)
    File.write(File.join(@clone_path, "keep.txt"), "uncommitted work\n")

    # Archive the session with a timestamp older than the stale threshold
    @stale_archived_at = (StaleCloneCleanupJob::STALE_THRESHOLD + 1.minute).ago
    @session.update!(
      status: :archived,
      archived_at: @stale_archived_at,
      trash_after: nil,
      metadata: { "clone_path" => @clone_path }
    )

    # Override the clones_directory so the tombstone reap uses our temp dir
    StaleCloneCleanupJob.clones_directory_override = @clones_base
  end

  teardown do
    StaleCloneCleanupJob.clones_directory_override = nil
    FileUtils.rm_rf(@clones_base) if @clones_base
  end

  test "cleans up stale clones from archived sessions" do
    assert File.directory?(@clone_path), "Clone should exist before cleanup"

    StaleCloneCleanupJob.perform_now

    assert_not File.directory?(@clone_path), "Stale clone should be cleaned up"

    # Verify log was created
    log = @session.logs.find_by("content LIKE ?", "%Stale resources%")
    assert_not_nil log
    assert_equal "info", log.level
  end

  # zimmer#808. The candidate scopes are plucked at the top of a run and worked
  # through one clone at a time; a session unarchived — or a failed one resumed —
  # inside that gap is live by the time its turn comes up.
  test "does not reap a session that woke up after the candidate scope picked it" do
    job = StaleCloneCleanupJob.new
    candidate = Session.find(@session.id) # what the loop is holding: archived, stale

    @session.update_columns(status: Session.statuses[:running])

    assert_not job.send(:cleanup_session_clone, candidate)
    assert File.directory?(@clone_path), "a live session's clone must survive the sweep"
  end

  test "leaves durable state alone when a session wakes up after its clone is deleted" do
    original = ENV["AGENT_SCRATCH_DIR"]
    Dir.mktmpdir("stale-scratch-race") do |scratch_base|
      ENV["AGENT_SCRATCH_DIR"] = scratch_base
      scratch_path = SessionScratchDirectory.ensure_for(@session.id)
      candidate = Session.find(@session.id)

      # Archived when the clone delete starts, running by the time the
      # unrecoverable half of the cleanup would run.
      job = StaleCloneCleanupJob.new
      job.stubs(:reapable_now?).returns(true).then.returns(false)

      job.send(:cleanup_session_clone, candidate)

      assert Dir.exist?(scratch_path), "scratch has no remote to come back from; it must survive"
    ensure
      original.nil? ? ENV.delete("AGENT_SCRATCH_DIR") : ENV["AGENT_SCRATCH_DIR"] = original
    end
  end

  # zimmer#808's other half, and the one no status check catches: an unarchive is
  # `archived` for its whole duration — UnarchiveSessionService transitions the
  # status only after the clone, the artifact replay and `air prepare` — so a
  # session having a NEW clone built for it matches this job's archived scope
  # exactly.
  test "does not reap the clone of a session that is being unarchived right now" do
    @session.update_columns(
      metadata: @session.metadata.merge(Session::UNARCHIVE_IN_FLIGHT_KEY => Time.current.utc.iso8601)
    )

    StaleCloneCleanupJob.perform_now

    assert File.directory?(@clone_path), "the clone an unarchive just built must survive"
  end

  test "an unarchive marker older than the grace period stops protecting the clone" do
    @session.update_columns(
      metadata: @session.metadata.merge(
        Session::UNARCHIVE_IN_FLIGHT_KEY => (Session::UNARCHIVE_GRACE_PERIOD + 1.hour).ago.utc.iso8601
      )
    )

    StaleCloneCleanupJob.perform_now

    assert_not File.directory?(@clone_path), "a crashed unarchive must not pin a clone forever"
  end

  test "preserved artifacts are not deleted for a session that woke up mid-cleanup" do
    job = StaleCloneCleanupJob.new
    candidate = Session.find(@session.id)
    job.stubs(:reapable_now?).returns(true).then.returns(false)
    CloneArtifactService.any_instance.expects(:cleanup_artifacts).never

    job.send(:cleanup_session_clone, candidate)
  end

  # The headline regression: every snapshot guard the orphan sweep builds before
  # its loop is deliberately blinded here, so what is left is the one guard that
  # asks at the instant of deletion.
  test "reclaims the durable per-session scratch dir alongside the stale clone" do
    original = ENV["AGENT_SCRATCH_DIR"]
    Dir.mktmpdir("stale-scratch") do |scratch_base|
      ENV["AGENT_SCRATCH_DIR"] = scratch_base
      scratch_path = SessionScratchDirectory.ensure_for(@session.id)
      assert Dir.exist?(scratch_path), "scratch dir should exist before cleanup"

      StaleCloneCleanupJob.perform_now

      assert_not Dir.exist?(scratch_path), "scratch dir should be cleaned up with the clone"
    ensure
      original.nil? ? ENV.delete("AGENT_SCRATCH_DIR") : ENV["AGENT_SCRATCH_DIR"] = original
    end
  end

  test "reclaims durable prompt attachments alongside the stale clone" do
    file_service = FileStorageService.new(session_id: @session.id)
    image_service = ImageStorageService.new(session_id: @session.id)
    begin
      file_service.store(data: "notes", filename: "notes.md")
      png = [ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A ].pack("C*") + ("x" * 32)
      image_service.store(data: Base64.strict_encode64(png), filename: "shot.png")
      assert Dir.exist?(file_service.session_dir), "file attachments should exist before cleanup"
      assert Dir.exist?(image_service.session_dir), "image attachments should exist before cleanup"

      StaleCloneCleanupJob.perform_now

      assert_not Dir.exist?(file_service.session_dir), "file attachments should be reaped with the clone"
      assert_not Dir.exist?(image_service.session_dir), "image attachments should be reaped with the clone"
    ensure
      file_service.cleanup!
      image_service.cleanup!
    end
  end

  test "does not clean up clones within stale threshold" do
    # Update session to be recently archived (within threshold)
    recent_archived_at = (StaleCloneCleanupJob::STALE_THRESHOLD - 1.minute).ago
    @session.update!(archived_at: recent_archived_at)

    assert File.directory?(@clone_path), "Clone should exist before job runs"

    StaleCloneCleanupJob.perform_now

    # Clone should still exist because it's not stale yet
    assert File.directory?(@clone_path), "Recent clone should NOT be cleaned up"
  end

  test "does not clean up clones from running or needs_input sessions" do
    @session.update!(status: :running)

    assert File.directory?(@clone_path), "Clone should exist before job runs"

    StaleCloneCleanupJob.perform_now

    assert File.directory?(@clone_path), "Clone from running session should NOT be cleaned up"
  end

  test "handles session without clone_path in metadata" do
    @session.update!(metadata: {})

    # Should not raise an error
    assert_nothing_raised do
      StaleCloneCleanupJob.perform_now
    end
  end

  test "handles session where clone directory no longer exists" do
    # Remove the clone directory
    FileUtils.rm_rf(@clone_path)

    # Should not raise an error
    assert_nothing_raised do
      StaleCloneCleanupJob.perform_now
    end
  end

  test "handles multiple stale sessions" do
    # Create a second stale session with clone inside the clones base
    session2 = sessions(:waiting)
    session2.logs.destroy_all
    clone_path2 = File.join(@clones_base, "test-stale-clone-2-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(clone_path2)
    FileUtils.touch(clone_path2, mtime: 2.hours.ago.to_time)
    session2.update!(
      status: :archived,
      archived_at: @stale_archived_at,
      trash_after: nil,
      metadata: { "clone_path" => clone_path2 }
    )

    assert File.directory?(@clone_path), "First clone should exist"
    assert File.directory?(clone_path2), "Second clone should exist"

    StaleCloneCleanupJob.perform_now

    # Both clones should be cleaned up
    assert_not File.directory?(@clone_path), "First stale clone should be cleaned up"
    assert_not File.directory?(clone_path2), "Second stale clone should be cleaned up"
  ensure
    FileUtils.rm_rf(clone_path2) if clone_path2 && File.directory?(clone_path2)
  end

  test "continues cleaning other sessions if one fails" do
    # Create a second stale session with a valid clone inside the clones base
    session2 = sessions(:waiting)
    session2.logs.destroy_all
    clone_path2 = File.join(@clones_base, "test-stale-clone-2-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(clone_path2)
    FileUtils.touch(clone_path2, mtime: 2.hours.ago.to_time)
    session2.update!(
      status: :archived,
      archived_at: @stale_archived_at,
      trash_after: nil,
      metadata: { "clone_path" => clone_path2 }
    )

    # Make the first session's clone path point to a nonexistent location
    @session.update!(metadata: { "clone_path" => "/nonexistent/path/that/will/fail" })

    # The job should continue and clean up the second clone
    StaleCloneCleanupJob.perform_now

    # Second clone should still be cleaned up despite first failing
    assert_not File.directory?(clone_path2), "Second clone should be cleaned up despite first failure"
  ensure
    FileUtils.rm_rf(clone_path2) if clone_path2 && File.directory?(clone_path2)
  end

  test "skips sessions with trash_after set (handled by EmptyTrashJob)" do
    @session.update!(trash_after: 5.days.from_now)

    assert File.directory?(@clone_path), "Clone should exist before job runs"

    StaleCloneCleanupJob.perform_now

    assert File.directory?(@clone_path), "Clone should NOT be cleaned up when trash_after is set"
  end

  test "stale threshold constant is reasonable" do
    # The stale threshold should be much longer than the undo window + deferred cleanup delay
    undo_window = 5.seconds
    deferred_delay = DeferredCloneCleanupJob::CLEANUP_DELAY
    minimum_threshold = undo_window + deferred_delay + 5.minutes # Plus buffer

    assert StaleCloneCleanupJob::STALE_THRESHOLD > minimum_threshold,
      "Stale threshold (#{StaleCloneCleanupJob::STALE_THRESHOLD}) should be much longer than " \
      "undo window + deferred delay + buffer (#{minimum_threshold})"
  end

  test "cleans up archived sessions with nil archived_at (legacy data)" do
    @session.update!(
      status: :archived,
      archived_at: nil,
      trash_after: nil,
      updated_at: (StaleCloneCleanupJob::STALE_THRESHOLD + 1.minute).ago
    )

    assert File.directory?(@clone_path), "Clone should exist before cleanup"

    StaleCloneCleanupJob.perform_now

    assert_not File.directory?(@clone_path), "Clone from archived session with nil archived_at should be cleaned up"
  end

  test "uses separate indexed candidate scopes instead of one OR query" do
    scopes = StaleCloneCleanupJob.new.send(:stale_clone_candidate_scopes)

    assert_equal 3, scopes.size
    scopes.each do |scope|
      assert_no_match(/\sOR\s/i, scope.to_sql)
      assert_match(/metadata->>'clone_path' IS NOT NULL/, scope.to_sql)
    end
  end

  test "candidate scan does not impose ORDER BY id (which defeats the partial indexes)" do
    # Regression guard for the DatabaseChoke incident: find_each batches with an
    # implicit ORDER BY "sessions"."id" ASC, which makes the planner satisfy the
    # order via a free primary-key scan and FILTER the whole sessions table instead
    # of using the partial clone_path indexes. The job must materialize candidate
    # ids with an unordered query so the planner picks the index. Capture every SQL
    # statement perform emits and assert none order the sessions scan by id.
    candidate_sql = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql]
      candidate_sql << sql if sql.include?('FROM "sessions"')
    end

    begin
      StaleCloneCleanupJob.perform_now
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    # Guard against the test silently no-opping: confirm a candidate scope query
    # (identifiable by the clone_path predicate) actually ran, so the ORDER BY
    # assertion below is meaningful rather than vacuously true.
    candidate_scope_sql = candidate_sql.select { |sql| sql.include?("metadata->>'clone_path' IS NOT NULL") }
    assert candidate_scope_sql.any?,
      "Expected at least one candidate scope query to run; got none, so the ORDER BY assertion would be vacuous."

    offending = candidate_sql.select { |sql| sql.match?(/ORDER BY\s+"sessions"\."id"/i) }
    assert_empty offending,
      "Expected no sessions query to ORDER BY id (the find_each full-scan signature), but found:\n#{offending.join("\n")}"
  end

  # --- Failed session clone cleanup tests ---

  test "cleans up clones from failed sessions older than failed threshold" do
    @session.update!(
      status: :failed,
      archived_at: nil,
      updated_at: (StaleCloneCleanupJob::FAILED_SESSION_STALE_THRESHOLD + 1.minute).ago
    )

    assert File.directory?(@clone_path), "Clone should exist before cleanup"

    StaleCloneCleanupJob.perform_now

    assert_not File.directory?(@clone_path), "Clone from stale failed session should be cleaned up"

    log = @session.logs.find_by("content LIKE ?", "%Stale resources%")
    assert_not_nil log
  end

  test "does not clean up clones from recently failed sessions" do
    @session.update!(
      status: :failed,
      archived_at: nil,
      updated_at: (StaleCloneCleanupJob::FAILED_SESSION_STALE_THRESHOLD - 1.hour).ago
    )

    assert File.directory?(@clone_path), "Clone should exist before job runs"

    StaleCloneCleanupJob.perform_now

    assert File.directory?(@clone_path), "Clone from recent failed session should NOT be cleaned up"
  end

  test "failed session threshold is longer than archived threshold" do
    assert StaleCloneCleanupJob::FAILED_SESSION_STALE_THRESHOLD > StaleCloneCleanupJob::STALE_THRESHOLD,
      "Failed session threshold should be longer than archived threshold to give users time to resume"
  end

  test "only counts actual directory deletions not all sessions processed" do
    # Remove the directory so nothing gets deleted, but session is still processed
    FileUtils.rm_rf(@clone_path)

    # The job should complete without counting a cleanup for a missing directory
    job = StaleCloneCleanupJob.new
    assert_nothing_raised { job.perform }
  end

  # --- The clones base: tombstones only (#709) ---
  #
  # This job used to run its own orphan sweep over the clones base on a one-hour
  # age bar, in parallel with OrphanCloneFilesystemCleanupJob's 48-hour one. Two
  # owners of "which directory here is safe to delete" is #709, and the short bar
  # reached every candidate first, so the disk-pressure reclamation could never
  # find one. What is left here is the tombstone reap, which needs no owner.

  test "does not sweep an unreferenced clone directory — that is OrphanCloneFilesystemCleanupJob's" do
    orphan_dir = Dir.mktmpdir("orphan-clone-", @clones_base)
    FileUtils.touch(orphan_dir, mtime: 2.hours.ago.to_time)

    StaleCloneCleanupJob.new.perform

    assert File.directory?(orphan_dir),
      "the clones base has one orphan sweep, and it is not this job's (#709)"
  ensure
    FileUtils.rm_rf(orphan_dir) if orphan_dir && File.directory?(orphan_dir)
  end

  test "does not sweep a very old unreferenced clone directory either" do
    ancient = Dir.mktmpdir("ancient-clone-", @clones_base)
    FileUtils.touch(ancient, mtime: 21.days.ago.to_time)

    StaleCloneCleanupJob.new.perform

    assert File.directory?(ancient), "age is not this job's business in the clones base"
  ensure
    FileUtils.rm_rf(ancient) if ancient && File.directory?(ancient)
  end

  test "leaves a live session's clone alone" do
    live_clone = Dir.mktmpdir("running-clone-", @clones_base)
    FileUtils.touch(live_clone, mtime: 21.days.ago.to_time)

    live = sessions(:active_session)
    live.update!(status: :running, metadata: { "clone_path" => live_clone })

    StaleCloneCleanupJob.new.perform

    assert File.directory?(live_clone), "a live session's clone must never be reaped"
  ensure
    FileUtils.rm_rf(live_clone) if live_clone && File.directory?(live_clone)
  end

  test "handles a missing clones directory gracefully" do
    StaleCloneCleanupJob.clones_directory_override = "/tmp/nonexistent-#{SecureRandom.hex(4)}"

    assert_nothing_raised { StaleCloneCleanupJob.new.perform }
  end

  test "reaps leftover tombstones without touching live clones" do
    tombstone = File.join(@clones_base, "test-clone-1770000001-abcd1234.deleting-0123abcd")
    FileUtils.mkdir_p(File.join(tombstone, "app"))

    live = sessions(:needs_input)
    live_dir = File.join(@clones_base, "test-clone-1770000002-abcd1234")
    FileUtils.mkdir_p(live_dir)
    FileUtils.touch(live_dir, mtime: 2.hours.ago.to_time)
    live.update!(trash_after: nil, metadata: { "clone_path" => live_dir })

    StaleCloneCleanupJob.new.perform

    assert_not File.exist?(tombstone)
    assert File.directory?(live_dir), "a live session's clone must survive the reap"
  end

  # --- A restarted trash window is the third way the answer goes stale ---

  test "does not reap a session re-archived into a fresh trash window" do
    # `reap_protected?` says no (it is archived, not live, not mid-unarchive) and
    # the status re-read says "archived", so a status-only check waves this
    # through. It is mid-undo-window and belongs to EmptyTrashJob.
    Session.where(id: @session.id).update_all(trash_after: 4.days.from_now)

    assert_not StaleCloneCleanupJob.new.send(:cleanup_session_clone, @session)

    assert File.directory?(@clone_path)
    assert File.exist?(File.join(@clone_path, "keep.txt")), "and not partially deleted either"
  end

  test "still reaps a session that is genuinely still a stale candidate" do
    assert StaleCloneCleanupJob.new.send(:cleanup_session_clone, @session)

    assert_not File.directory?(@clone_path)
  end
end
