# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class DeferredCloneCleanupJobTest < ActiveJob::TestCase
  setup do
    @session = sessions(:running)
    @session.logs.destroy_all
    @clone_path = "/tmp/test-clone-deferred-#{SecureRandom.hex(4)}"
    FileUtils.mkdir_p(@clone_path)
    @archived_at = Time.current
    @session.update!(
      status: :archived,
      archived_at: @archived_at,
      trash_after: 4.days.from_now,
      metadata: { "clone_path" => @clone_path }
    )
  end

  teardown do
    FileUtils.rm_rf(@clone_path) if @clone_path && File.directory?(@clone_path)
  end

  test "cleans up clone and clears trash_after when clone is clean" do
    assert File.directory?(@clone_path), "Clone should exist before cleanup"

    DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)

    assert_not File.directory?(@clone_path), "Clone should be deleted after cleanup"

    # trash_after should be cleared for clean clones (no artifacts to retain)
    @session.reload
    assert_nil @session.trash_after, "trash_after should be cleared for clean clones"

    # Verify log was created
    log = @session.logs.find_by("content LIKE ?", "%Clone deleted%")
    assert_not_nil log
    assert_equal "info", log.level
    assert_includes log.content, "no unpushed state"
  end

  test "reclaims the durable per-session scratch dir when reaping the clone" do
    original = ENV["AGENT_SCRATCH_DIR"]
    Dir.mktmpdir("deferred-scratch") do |scratch_base|
      ENV["AGENT_SCRATCH_DIR"] = scratch_base
      scratch_path = SessionScratchDirectory.ensure_for(@session.id)
      File.write(File.join(scratch_path, "state.txt"), "reconstructable")
      assert Dir.exist?(scratch_path), "scratch dir should exist before cleanup"

      DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)

      assert_not Dir.exist?(scratch_path), "scratch dir should be deleted after cleanup"
    ensure
      original.nil? ? ENV.delete("AGENT_SCRATCH_DIR") : ENV["AGENT_SCRATCH_DIR"] = original
    end
  end

  test "reclaims scratch even when there is no clone on disk" do
    original = ENV["AGENT_SCRATCH_DIR"]
    Dir.mktmpdir("deferred-scratch-noclone") do |scratch_base|
      ENV["AGENT_SCRATCH_DIR"] = scratch_base
      scratch_path = SessionScratchDirectory.ensure_for(@session.id)
      FileUtils.rm_rf(@clone_path) # no clone to reap

      DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)

      assert_not Dir.exist?(scratch_path), "scratch dir should be deleted even with no clone"
    ensure
      original.nil? ? ENV.delete("AGENT_SCRATCH_DIR") : ENV["AGENT_SCRATCH_DIR"] = original
    end
  end

  test "skips cleanup when session is no longer archived" do
    # Unarchive the session
    @session.unarchive_to_failed!
    assert_not @session.archived?, "Session should not be archived"

    assert File.directory?(@clone_path), "Clone should exist before job runs"

    DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)

    # Clone should still exist because session was unarchived
    assert File.directory?(@clone_path), "Clone should NOT be deleted when session is unarchived"
  end

  test "skips cleanup when session was re-archived with different timestamp" do
    original_archived_at = @archived_at

    # Update archived_at to be more than 1 second in the future (outside tolerance)
    new_archived_at = original_archived_at + 2.seconds
    @session.update!(archived_at: new_archived_at)

    assert File.directory?(@clone_path), "Clone should exist before job runs"

    # Run job with the original archived_at timestamp
    DeferredCloneCleanupJob.perform_now(@session.id, original_archived_at.iso8601)

    # Clone should still exist because the timestamps don't match
    assert File.directory?(@clone_path), "Clone should NOT be deleted when session was re-archived"
  end

  test "skips cleanup when session does not exist" do
    non_existent_id = 999999

    assert_nothing_raised do
      DeferredCloneCleanupJob.perform_now(non_existent_id, @archived_at.iso8601)
    end

    assert File.directory?(@clone_path), "Clone should not be affected"
  end

  test "handles session deleted after job was scheduled" do
    session_id = @session.id
    archived_at = @archived_at.iso8601

    @session.destroy!

    assert_nothing_raised do
      DeferredCloneCleanupJob.perform_now(session_id, archived_at)
    end

    assert File.directory?(@clone_path), "Clone should not be affected when session is deleted"
  end

  test "skips cleanup when clone path does not exist" do
    FileUtils.rm_rf(@clone_path)

    assert_nothing_raised do
      DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)
    end

    # trash_after should be cleared since there's nothing to preserve
    @session.reload
    assert_nil @session.trash_after
  end

  test "skips cleanup when clone path is nil" do
    @session.update!(metadata: {})

    assert_nothing_raised do
      DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)
    end

    @session.reload
    assert_nil @session.trash_after
  end

  test "handles invalid archived_at timestamp gracefully" do
    assert File.directory?(@clone_path), "Clone should exist before job runs"

    assert_nothing_raised do
      DeferredCloneCleanupJob.perform_now(@session.id, "invalid-timestamp")
    end

    assert File.directory?(@clone_path), "Clone should NOT be deleted with invalid timestamp"
  end

  test "undo within window prevents cleanup" do
    assert File.directory?(@clone_path), "Clone should exist"

    @session.update!(archived_at: nil)
    @session.unarchive_to_failed!

    DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)

    assert File.directory?(@clone_path), "Clone should still exist after undo"
    assert_not @session.archived?, "Session should not be archived after undo"
  end

  test "cleanup delay constant is longer than undo window" do
    undo_window = 5.seconds
    assert DeferredCloneCleanupJob::CLEANUP_DELAY > undo_window,
      "Cleanup delay (#{DeferredCloneCleanupJob::CLEANUP_DELAY}) should be longer than undo window (#{undo_window})"
  end

  test "archive enqueues deferred cleanup job and sets trash_after" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      agent_runtime: "claude_code",
      branch: "main",
      session_id: SecureRandom.uuid,
      status: :needs_input,
      archived_at: Time.current
    )
    clone_path = "/tmp/test-clone-schedule-#{SecureRandom.hex(4)}"
    FileUtils.mkdir_p(clone_path)
    session.update!(metadata: { "clone_path" => clone_path })

    # Archive SHOULD enqueue DeferredCloneCleanupJob
    assert_enqueued_with(job: DeferredCloneCleanupJob) do
      session.archive!
    end

    # Clone should still exist (preserved until deferred job runs)
    assert File.directory?(clone_path), "Clone should exist after archive"

    # trash_after should be set as safety net
    session.reload
    assert_not_nil session.trash_after, "trash_after should be set when session is archived"
    assert session.trash_after > Time.current, "trash_after should be in the future"
  ensure
    FileUtils.rm_rf(clone_path) if clone_path && File.directory?(clone_path)
  end

  # === Artifact preservation failure tests ===

  test "keeps clone intact when dirty state detected but artifact creation fails" do
    assert File.directory?(@clone_path), "Clone should exist before cleanup"

    # Stub dirty state detection to report dirty
    dirty_result = CloneArtifactService::DirtyCheckResult.new(
      dirty?: true,
      has_uncommitted?: true,
      has_unpushed_commits?: false,
      details: "uncommitted changes"
    )
    create_result = CloneArtifactService::CreateResult.new(
      success?: false,
      error: "Disk full"
    )

    artifact_service = mock("artifact_service")
    artifact_service.expects(:check_dirty_state).with(@clone_path).returns(dirty_result)
    artifact_service.expects(:create_artifacts).with(session_id: @session.id, clone_path: @clone_path).returns(create_result)
    CloneArtifactService.expects(:new).returns(artifact_service)

    DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)

    # Clone should NOT be deleted because artifact creation failed
    assert File.directory?(@clone_path), "Clone should be preserved when artifact creation fails"

    # trash_after should remain set (safety net for EmptyTrashJob)
    @session.reload
    assert_not_nil @session.trash_after, "trash_after should remain set for retry"
  end

  # === Docker Compose cleanup tests ===

  test "calls DockerComposeCleanupService and still removes clone directory" do
    DockerComposeCleanupService.expects(:cleanup).with(@clone_path).returns(false)

    DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)

    assert_not File.directory?(@clone_path), "Clone should be deleted after cleanup"
  end

  test "logs Docker cleanup in session log when Docker resources were removed" do
    DockerComposeCleanupService.expects(:cleanup).with(@clone_path).returns(true)

    DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)

    log = @session.logs.find_by("content LIKE ?", "%Docker resources also removed%")
    assert_not_nil log, "Should log that Docker resources were removed"
  end

  test "does not mention Docker in log when no Docker resources existed" do
    DockerComposeCleanupService.expects(:cleanup).with(@clone_path).returns(false)

    DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)

    log = @session.logs.reload.last
    assert_not_nil log, "A cleanup log should have been created"
    assert_not_includes log.content, "Docker", "Should not mention Docker when no Docker resources existed"
  end

  test "proceeds with clone cleanup even if Docker cleanup raises an error" do
    DockerComposeCleanupService.expects(:cleanup).with(@clone_path).raises(StandardError, "unexpected docker error")

    DeferredCloneCleanupJob.perform_now(@session.id, @archived_at.iso8601)

    assert_not File.directory?(@clone_path), "Clone should be deleted even if Docker cleanup raises"
  end
end
