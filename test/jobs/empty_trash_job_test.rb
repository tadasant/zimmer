# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class EmptyTrashJobTest < ActiveJob::TestCase
  setup do
    @session = sessions(:running)
    @session.logs.destroy_all
    @clone_path = "/tmp/test-clone-trash-#{SecureRandom.hex(4)}"
    FileUtils.mkdir_p(@clone_path)
    @session.update!(
      status: :archived,
      archived_at: 15.days.ago,
      trash_after: 1.day.ago,
      metadata: { "clone_path" => @clone_path }
    )

    # The job now reaps the scratch base, so pin it to a tmpdir for every test
    # in this file — otherwise the suite deletes out of the host's real
    # ~/.zimmer/session-scratch.
    @scratch_env = ENV["AGENT_SCRATCH_DIR"]
    @scratch_base = Dir.mktmpdir("trash-scratch")
    ENV["AGENT_SCRATCH_DIR"] = @scratch_base
  end

  teardown do
    @scratch_env.nil? ? ENV.delete("AGENT_SCRATCH_DIR") : ENV["AGENT_SCRATCH_DIR"] = @scratch_env
    FileUtils.remove_entry(@scratch_base) if @scratch_base && Dir.exist?(@scratch_base)
    FileUtils.rm_rf(@clone_path) if @clone_path && File.directory?(@clone_path)
  end

  # This sweep walks every expired trashed session with `find_each` and no cap,
  # and each one costs a Docker Compose teardown plus five recursive deletes — so
  # a day's worth of expired trash is an unbounded hold on one of `maintenance`'s
  # two threads, with the per-archive DeferredCloneCleanupJob stream queued behind
  # it.
  test "stops when the wall-clock budget runs out and leaves the rest for the next run" do
    second = sessions(:waiting)
    second_clone = "/tmp/test-clone-trash-second-#{SecureRandom.hex(4)}"
    FileUtils.mkdir_p(second_clone)
    second.update!(
      status: :archived,
      archived_at: 15.days.ago,
      trash_after: 1.day.ago,
      metadata: { "clone_path" => second_clone }
    )

    begin
      job = EmptyTrashJob.new
      # A monotonically advancing fake clock: each reading is 200s later, so the
      # 5-minute budget is spent after the second one however many times the job
      # reads it.
      ticks = -1
      job.define_singleton_method(:monotonic_now) do
        ticks += 1
        ticks * 200.0
      end

      job.perform

      survived = [ @clone_path, second_clone ].count { |path| File.directory?(path) }
      assert_equal 1, survived, "exactly one expired session is deferred to the next hourly run"
    ensure
      FileUtils.rm_rf(second_clone)
    end
  end

  test "clears the whole expired set when the budget allows" do
    second = sessions(:waiting)
    second_clone = "/tmp/test-clone-trash-second-#{SecureRandom.hex(4)}"
    FileUtils.mkdir_p(second_clone)
    second.update!(
      status: :archived,
      archived_at: 15.days.ago,
      trash_after: 1.day.ago,
      metadata: { "clone_path" => second_clone }
    )

    begin
      EmptyTrashJob.perform_now

      assert_not File.directory?(@clone_path)
      assert_not File.directory?(second_clone)
    ensure
      FileUtils.rm_rf(second_clone)
    end
  end

  test "cleans up clone for expired trashed session" do
    assert File.directory?(@clone_path), "Clone should exist before cleanup"

    EmptyTrashJob.perform_now

    assert_not File.directory?(@clone_path), "Clone should be deleted after cleanup"

    # Verify log was created
    log = @session.logs.find_by("content LIKE ?", "%Permanent cleanup%")
    assert_not_nil log
    assert_equal "info", log.level
    assert_includes log.content, "clone deleted"

    # Verify trash_after was cleared
    @session.reload
    assert_nil @session.trash_after
  end

  # zimmer#808. `find_each` loads a batch and then works through it one Docker
  # teardown and one recursive delete at a time; an unarchive inside that gap
  # puts the session back to work on this very clone.
  test "does not reap a session unarchived after this run's batch was loaded" do
    scratch_path = SessionScratchDirectory.ensure_for(@session.id)
    batched = Session.find(@session.id) # what find_each is holding: archived, expired

    @session.update_columns(status: Session.statuses[:running], trash_after: nil)

    assert_not EmptyTrashJob.new.send(:cleanup_session, batched)
    assert File.directory?(@clone_path), "a live session's clone must survive the trash sweep"
    assert Dir.exist?(scratch_path), "scratch has no remote to come back from; it must survive"
  end

  test "leaves durable state alone when a session wakes up after its clone is deleted" do
    scratch_path = SessionScratchDirectory.ensure_for(@session.id)
    batched = Session.find(@session.id)

    # Trash when the clone delete starts, live by the time the unrecoverable half
    # of the cleanup would run. The clone goes; nothing that lacks a remote does.
    job = EmptyTrashJob.new
    job.stubs(:still_trash?).returns(true).then.returns(false)

    job.send(:cleanup_session, batched)

    assert Dir.exist?(scratch_path), "scratch has no remote to come back from; it must survive"
  end

  # zimmer#808's other half: an unarchive is `archived` for its whole duration, so
  # a session having a NEW clone built for it still matches this job's scope.
  test "does not reap a session that is being unarchived right now" do
    scratch_path = SessionScratchDirectory.ensure_for(@session.id)
    @session.update_columns(
      metadata: @session.metadata.merge(Session::UNARCHIVE_IN_FLIGHT_KEY => Time.current.utc.iso8601)
    )

    EmptyTrashJob.perform_now

    assert File.directory?(@clone_path), "the clone an unarchive just built must survive"
    assert Dir.exist?(scratch_path)
  end

  test "a session re-archived into a fresh trash window is no longer expired trash" do
    # An unarchive followed by a re-archive restarts the four-day deadline. The
    # row is `archived`, not `reap_protected`, and squarely mid-undo-window — so a
    # status-only re-read waves it through and everything below the clone
    # (scratch, config, attachments, artifacts) goes with it, none of which has a
    # remote to come back from. Driven through #still_trash? directly, because
    # the outer scope would exclude the row before the re-read ever ran — the
    # window this closes is the row changing *after* the scope selected it.
    @session.update_columns(trash_after: 4.days.from_now)

    assert_not EmptyTrashJob.new.send(:still_trash?, @session)
  end

  test "a session whose trash deadline was cleared entirely is no longer expired trash" do
    @session.update_columns(trash_after: nil)

    assert_not EmptyTrashJob.new.send(:still_trash?, @session)
  end

  test "a session whose deadline really has passed is still expired trash" do
    assert EmptyTrashJob.new.send(:still_trash?, @session)
  end

  test "a deadline restarted mid-cleanup is not cleared, so the undo window survives" do
    # The row is expired trash when the run starts and re-archived by the time the
    # clone delete is done. Clearing the fresh deadline anyway would drop it into
    # StaleCloneCleanupJob's archived-and-untrashed scope, to be reaped
    # unpreserved an hour later.
    scratch_path = SessionScratchDirectory.ensure_for(@session.id)
    @session.update_columns(trash_after: 4.days.from_now)
    # Expired trash when the run starts; re-archived by the time the clone delete
    # is done. `still_trash?` is asked once at each end of #cleanup_session.
    job = EmptyTrashJob.new
    job.stubs(:still_trash?).returns(true).then.returns(false)

    job.send(:cleanup_session, @session)

    assert_not_nil @session.reload.trash_after, "the restarted deadline must survive"
    assert Dir.exist?(scratch_path)
  end

  test "cleans up artifacts for expired trashed session" do
    # Remove clone to isolate artifact cleanup behavior
    FileUtils.rm_rf(@clone_path)

    # Stub CloneArtifactService to report artifacts exist and can be cleaned
    CloneArtifactService.any_instance.expects(:cleanup_artifacts).with(@session.id).returns(true)

    EmptyTrashJob.perform_now

    @session.reload
    assert_nil @session.trash_after

    log = @session.logs.find_by("content LIKE ?", "%artifacts deleted%")
    assert_not_nil log, "Cleanup log should mention artifacts deleted"
  end

  test "clears artifacts_path from metadata on cleanup" do
    @session.update!(metadata: { "clone_path" => @clone_path, "artifacts_path" => "/some/path" })

    EmptyTrashJob.perform_now

    @session.reload
    assert_nil @session.metadata&.dig("artifacts_path"), "artifacts_path should be cleared from metadata"
  end

  test "reaps the durable scratch dir when retention expires" do
    scratch_path = SessionScratchDirectory.ensure_for(@session.id)
    File.write(File.join(scratch_path, "state.txt"), "cross-step state")

    EmptyTrashJob.perform_now

    assert_not Dir.exist?(scratch_path), "scratch dir should be deleted once retention expires"

    log = @session.logs.find_by("content LIKE ?", "%scratch directory deleted%")
    assert_not_nil log, "cleanup log should mention the scratch directory"
  end

  test "reaps durable prompt attachments when retention expires" do
    file_service = FileStorageService.new(session_id: @session.id)
    image_service = ImageStorageService.new(session_id: @session.id)
    begin
      file_service.store(data: "notes", filename: "notes.md")
      png = [ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A ].pack("C*") + ("x" * 32)
      image_service.store(data: Base64.strict_encode64(png), filename: "shot.png")

      EmptyTrashJob.perform_now

      assert_not Dir.exist?(file_service.session_dir), "file attachments should be reaped at the trash deadline"
      assert_not Dir.exist?(image_service.session_dir), "image attachments should be reaped at the trash deadline"

      log = @session.logs.find_by("content LIKE ?", "%prompt attachments deleted%")
      assert_not_nil log, "cleanup log should mention prompt attachments"
    ensure
      file_service.cleanup!
      image_service.cleanup!
    end
  end

  test "leaves the scratch dir alone while retention has not expired" do
    @session.update!(trash_after: 1.day.from_now)
    scratch_path = SessionScratchDirectory.ensure_for(@session.id)

    EmptyTrashJob.perform_now

    assert Dir.exist?(scratch_path), "scratch dir must survive until the trash deadline passes"
  end

  test "skips sessions where trash_after has not expired" do
    @session.update!(trash_after: 1.day.from_now)
    assert File.directory?(@clone_path), "Clone should exist before job runs"

    EmptyTrashJob.perform_now

    assert File.directory?(@clone_path), "Clone should NOT be deleted when trash_after is in the future"
  end

  test "skips sessions that are not archived" do
    @session.update!(status: :failed, trash_after: 1.day.ago)
    assert File.directory?(@clone_path), "Clone should exist before job runs"

    EmptyTrashJob.perform_now

    assert File.directory?(@clone_path), "Clone should NOT be deleted when session is not archived"
  end

  test "skips sessions without trash_after" do
    @session.update!(trash_after: nil)
    assert File.directory?(@clone_path), "Clone should exist before job runs"

    EmptyTrashJob.perform_now

    assert File.directory?(@clone_path), "Clone should NOT be deleted when trash_after is nil"
  end

  test "handles missing clone path gracefully" do
    FileUtils.rm_rf(@clone_path)

    assert_nothing_raised do
      EmptyTrashJob.perform_now
    end

    # trash_after should be cleared even if clone doesn't exist
    @session.reload
    assert_nil @session.trash_after
  end

  test "handles nil clone path gracefully" do
    @session.update!(metadata: {})

    assert_nothing_raised do
      EmptyTrashJob.perform_now
    end

    @session.reload
    assert_nil @session.trash_after
  end

  test "cleans up multiple expired sessions" do
    second_clone_path = "/tmp/test-clone-trash-2-#{SecureRandom.hex(4)}"
    FileUtils.mkdir_p(second_clone_path)

    second_session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      agent_runtime: "claude_code",
      branch: "main",
      status: :archived,
      archived_at: 15.days.ago,
      trash_after: 1.day.ago,
      metadata: { "clone_path" => second_clone_path }
    )

    EmptyTrashJob.perform_now

    assert_not File.directory?(@clone_path), "First clone should be deleted"
    assert_not File.directory?(second_clone_path), "Second clone should be deleted"
  ensure
    FileUtils.rm_rf(second_clone_path) if second_clone_path && File.directory?(second_clone_path)
  end

  test "continues processing when one session fails" do
    second_clone_path = "/tmp/test-clone-trash-3-#{SecureRandom.hex(4)}"
    FileUtils.mkdir_p(second_clone_path)

    second_session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      agent_runtime: "claude_code",
      branch: "main",
      status: :archived,
      archived_at: 15.days.ago,
      trash_after: 2.days.ago,
      metadata: { "clone_path" => second_clone_path }
    )

    # Make the first session's cleanup fail by raising from GitCloneService
    GitCloneService.expects(:cleanup_clone).with(@clone_path, reason: "EmptyTrashJob").raises(StandardError, "disk error")
    GitCloneService.expects(:cleanup_clone).with(second_clone_path, reason: "EmptyTrashJob").once

    assert_nothing_raised do
      EmptyTrashJob.perform_now
    end

    # Second session should have trash_after cleared (cleanup completed)
    second_session.reload
    assert_nil second_session.trash_after, "Second session trash_after should be cleared despite first failure"
  ensure
    FileUtils.rm_rf(second_clone_path) if second_clone_path && File.directory?(second_clone_path)
  end

  test "calls DockerComposeCleanupService before removing clone" do
    DockerComposeCleanupService.expects(:cleanup).with(@clone_path).returns(true)

    EmptyTrashJob.perform_now

    log = @session.logs.find_by("content LIKE ?", "%Docker resources removed%")
    assert_not_nil log, "Should log that Docker resources were removed"
  end

  test "proceeds with clone cleanup even if Docker cleanup fails" do
    DockerComposeCleanupService.expects(:cleanup).with(@clone_path).raises(StandardError, "docker error")

    EmptyTrashJob.perform_now

    assert_not File.directory?(@clone_path), "Clone should be deleted even if Docker cleanup fails"
  end
end
