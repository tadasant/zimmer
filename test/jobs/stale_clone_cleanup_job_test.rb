# frozen_string_literal: true

require "test_helper"

class StaleCloneCleanupJobTest < ActiveJob::TestCase
  setup do
    @session = sessions(:running)
    @session.logs.destroy_all
    # Create a temp clones directory for the orphan sweep
    @clones_base = Dir.mktmpdir("stale-clone-test-clones")

    @clone_path = File.join(@clones_base, "test-stale-clone-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(@clone_path)

    # Archive the session with a timestamp older than the stale threshold
    @stale_archived_at = (StaleCloneCleanupJob::STALE_THRESHOLD + 1.minute).ago
    @session.update!(
      status: :archived,
      archived_at: @stale_archived_at,
      trash_after: nil,
      metadata: { "clone_path" => @clone_path }
    )

    # Override the clones_directory so orphan sweep uses our temp dir
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

  # --- Orphan sweep tests ---

  test "sweep removes orphaned directories not referenced by any session" do
    orphan_dir = Dir.mktmpdir("orphan-clone-", @clones_base)
    # Backdate mtime so it passes the age threshold
    FileUtils.touch(orphan_dir, mtime: 2.hours.ago.to_time)

    StaleCloneCleanupJob.new.perform

    assert_not File.directory?(orphan_dir), "Orphaned directory should be swept"
  end

  test "sweep does not remove directories referenced by active sessions" do
    active_clone = Dir.mktmpdir("active-clone-", @clones_base)
    FileUtils.touch(active_clone, mtime: 2.hours.ago.to_time)

    # Use a session that isn't @session, and set it to an active status
    active_session = sessions(:active_session)
    active_session.update!(status: :needs_input, metadata: { "clone_path" => active_clone })

    StaleCloneCleanupJob.new.perform

    assert File.directory?(active_clone), "Directory referenced by active session should NOT be swept"
  ensure
    FileUtils.rm_rf(active_clone) if active_clone && File.directory?(active_clone)
  end

  test "sweep does not remove directories younger than orphan age threshold" do
    young_orphan = Dir.mktmpdir("young-orphan-", @clones_base)
    # mtime is now — well within the threshold

    StaleCloneCleanupJob.new.perform

    assert File.directory?(young_orphan), "Young directory should NOT be swept even if unreferenced"
  ensure
    FileUtils.rm_rf(young_orphan) if young_orphan && File.directory?(young_orphan)
  end

  test "sweep skips non-directory entries in clones directory" do
    file_path = File.join(@clones_base, "stray-file.txt")
    File.write(file_path, "not a directory")
    FileUtils.touch(file_path, mtime: 2.hours.ago.to_time)

    assert_nothing_raised { StaleCloneCleanupJob.new.perform }

    assert File.exist?(file_path), "Non-directory entries should be ignored"
  ensure
    FileUtils.rm_f(file_path) if file_path
  end

  test "sweep handles missing clones directory gracefully" do
    # Override to nil (simulates no clones dir found)
    StaleCloneCleanupJob.clones_directory_override = "/tmp/nonexistent-#{SecureRandom.hex(4)}"

    assert_nothing_raised { StaleCloneCleanupJob.new.perform }
  end

  test "sweep preserves running session clones" do
    running_clone = Dir.mktmpdir("running-clone-", @clones_base)
    FileUtils.touch(running_clone, mtime: 2.hours.ago.to_time)

    running_session = sessions(:active_session)
    running_session.update!(status: :running, metadata: { "clone_path" => running_clone })

    StaleCloneCleanupJob.new.perform

    assert File.directory?(running_clone), "Clone for running session must not be swept"
  ensure
    FileUtils.rm_rf(running_clone) if running_clone && File.directory?(running_clone)
  end

  test "sweep preserves waiting session clones" do
    waiting_clone = Dir.mktmpdir("waiting-clone-", @clones_base)
    FileUtils.touch(waiting_clone, mtime: 2.hours.ago.to_time)

    waiting_session = sessions(:needs_input)
    waiting_session.update!(status: :waiting, metadata: { "clone_path" => waiting_clone })

    StaleCloneCleanupJob.new.perform

    assert File.directory?(waiting_clone), "Clone for waiting session must not be swept"
  ensure
    FileUtils.rm_rf(waiting_clone) if waiting_clone && File.directory?(waiting_clone)
  end

  test "sweep preserves failed session clones within grace period" do
    failed_clone = Dir.mktmpdir("failed-clone-", @clones_base)
    FileUtils.touch(failed_clone, mtime: 2.hours.ago.to_time)

    failed_session = sessions(:failed)
    failed_session.update!(
      status: :failed,
      updated_at: 2.hours.ago,
      metadata: { "clone_path" => failed_clone }
    )

    StaleCloneCleanupJob.new.perform

    assert File.directory?(failed_clone), "Clone for failed session within 24hr grace period must not be swept"
  ensure
    FileUtils.rm_rf(failed_clone) if failed_clone && File.directory?(failed_clone)
  end

  test "sweep preserves archived session clones in trash pipeline" do
    trash_clone = Dir.mktmpdir("trash-clone-", @clones_base)
    FileUtils.touch(trash_clone, mtime: 2.hours.ago.to_time)

    archived_session = sessions(:archived)
    archived_session.update!(
      status: :archived,
      trash_after: 5.days.from_now,
      metadata: { "clone_path" => trash_clone }
    )

    StaleCloneCleanupJob.new.perform

    assert File.directory?(trash_clone), "Clone for archived session with trash_after must not be swept"
  ensure
    FileUtils.rm_rf(trash_clone) if trash_clone && File.directory?(trash_clone)
  end

  # --- Long-lived active session invariant (the core hardening) ---
  #
  # A session can sit idle in needs_input for up to ~3 weeks and must still find
  # its clone intact when resumed. The sweep must NEVER reap a live session's
  # clone, no matter how old the directory or the session row is.

  test "sweep never reaps a 3-week-old idle needs_input session's clone" do
    long_lived_clone = Dir.mktmpdir("long-lived-clone-", @clones_base)
    # Backdate both the directory mtime AND the session row far past every
    # threshold to prove age-independence.
    FileUtils.touch(long_lived_clone, mtime: 21.days.ago.to_time)

    long_lived = sessions(:active_session)
    long_lived.update!(
      status: :needs_input,
      updated_at: 21.days.ago,
      metadata: { "clone_path" => long_lived_clone }
    )

    StaleCloneCleanupJob.new.perform

    assert File.directory?(long_lived_clone),
      "A 3-week-old idle needs_input session's clone must NEVER be swept"
  ensure
    FileUtils.rm_rf(long_lived_clone) if long_lived_clone && File.directory?(long_lived_clone)
  end

  test "sweep matches live clones even when stored path is non-canonical" do
    live_clone = Dir.mktmpdir("noncanon-clone-", @clones_base)
    FileUtils.touch(live_clone, mtime: 21.days.ago.to_time)

    # Store a non-canonical form of the same path (trailing-slash + redundant
    # segment) to prove the normalized comparison protects it from reaping.
    noncanonical = File.join(live_clone, ".", "")
    live = sessions(:active_session)
    live.update!(status: :running, metadata: { "clone_path" => noncanonical })

    StaleCloneCleanupJob.new.perform

    assert File.directory?(live_clone),
      "Live clone must be protected even when its stored clone_path is non-canonical"
  ensure
    FileUtils.rm_rf(live_clone) if live_clone && File.directory?(live_clone)
  end

  # --- Normalization-immune basename catch-all (the symmetric gap closure) ---
  #
  # The path guards compare File.expand_path'd strings. expand_path normalizes
  # "./" and trailing slashes but does NOT resolve symlinks or reconcile a path
  # stored under a different/relocated base. If a referencing session's stored
  # clone_path can't be reconciled with the scan path, the directory must still
  # be protected by its globally-unique basename — and the near-miss must be
  # recorded durably on the owning session so a recurring canonicalization bug
  # is visible instead of silently destroying the clone.

  test "sweep keeps a live clone whose stored path is under a divergent base (basename match) and flags it durably" do
    # The real directory lives in the scan base...
    basename = "pulsemcp-main-1781471390-divergent1"
    real_dir = File.join(@clones_base, basename)
    FileUtils.mkdir_p(real_dir)
    FileUtils.touch(real_dir, mtime: 21.days.ago.to_time)

    # ...but the session stored its clone_path under a DIFFERENT base, so neither
    # path guard can reconcile it with real_dir. Only the basename guard can.
    divergent_path = File.join("/some/other/relocated/base", basename)
    live = sessions(:active_session)
    live.logs.destroy_all
    live.update!(status: :needs_input, metadata: { "clone_path" => divergent_path })

    StaleCloneCleanupJob.new.perform

    assert File.directory?(real_dir),
      "Clone referenced by a session via a divergent-base path must NOT be swept (basename guard)"

    flag = live.reload.logs.find_by("content LIKE ?", "%Orphan sweep skipped deleting%")
    assert_not_nil flag, "Expected a durable warning log on the owning session"
    assert_equal "warning", flag.level
    assert_includes flag.content, basename
  ensure
    FileUtils.rm_rf(real_dir) if real_dir && File.directory?(real_dir)
  end

  test "sweep keeps a terminal (archived, no trash) session's clone matched only by basename" do
    # An archived session NOT in the trash pipeline is a candidate for the
    # DB-driven scopes, which reap by stored path. If its stored path diverges
    # from the on-disk base, the DB scope's File.directory? check misses it and
    # the orphan sweep used to delete it by age. The basename catch-all must keep
    # it instead — terminal-clone reclamation belongs to the dedicated scopes,
    # not the blunt age-based sweep.
    basename = "pulsemcp-main-1781471390-divergent2"
    real_dir = File.join(@clones_base, basename)
    FileUtils.mkdir_p(real_dir)
    FileUtils.touch(real_dir, mtime: 2.hours.ago.to_time)

    divergent_path = File.join("/some/other/relocated/base", basename)
    terminal = sessions(:waiting)
    terminal.logs.destroy_all
    terminal.update!(
      status: :archived,
      archived_at: @stale_archived_at,
      trash_after: nil,
      metadata: { "clone_path" => divergent_path }
    )

    StaleCloneCleanupJob.new.perform

    assert File.directory?(real_dir),
      "A referenced clone must not be swept by the orphan sweep just because its stored path diverged"
  ensure
    FileUtils.rm_rf(real_dir) if real_dir && File.directory?(real_dir)
  end

  test "referenced_clone_owners_by_basename maps unique basenames to session ids" do
    @session.update!(status: :needs_input, metadata: { "clone_path" => "/a/base/zzz-clone-aaa" })

    map = StaleCloneCleanupJob.new.send(:referenced_clone_owners_by_basename)

    assert_equal @session.id, map["zzz-clone-aaa"]
  end
end
