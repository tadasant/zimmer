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
  end

  teardown do
    FileUtils.rm_rf(@clone_path) if @clone_path && File.directory?(@clone_path)
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
    GitCloneService.expects(:cleanup_clone).with(@clone_path).raises(StandardError, "disk error")
    GitCloneService.expects(:cleanup_clone).with(second_clone_path).once

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
