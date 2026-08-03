# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The archive -> deferred-cleanup -> unarchive round trip for a session's durable
# scratch directory.
#
# Zimmer's system prompt tells every session to keep cross-step recovery state in
# this directory rather than /tmp. Archive is reversible, so the directory has to
# be reversible with it: it must still be there, with its contents, when the
# session comes back. See issue #323, where an unarchived session resumed with an
# empty scratch directory and no way to tell it apart from one it had never
# written to.
class SessionScratchArchiveLifecycleTest < ActiveJob::TestCase
  setup do
    @clone_path = "/tmp/test-clone-scratch-roundtrip-#{SecureRandom.hex(4)}"
    FileUtils.mkdir_p(@clone_path)

    @session = Session.create!(
      prompt: "Test prompt",
      agent_runtime: "claude_code",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      transcript: "{}\n",
      metadata: { "clone_path" => @clone_path, "working_directory" => @clone_path }
    )

    @scratch_env = ENV["AGENT_SCRATCH_DIR"]
    @scratch_base = Dir.mktmpdir("scratch-roundtrip")
    ENV["AGENT_SCRATCH_DIR"] = @scratch_base

    @scratch_path = SessionScratchDirectory.ensure_for(@session.id)
    @handoff = File.join(@scratch_path, "handoff.md")
    File.write(@handoff, "state the session maintained all day")

    AirPrepareService.any_instance.stubs(:prepare!)
  end

  teardown do
    @scratch_env.nil? ? ENV.delete("AGENT_SCRATCH_DIR") : ENV["AGENT_SCRATCH_DIR"] = @scratch_env
    FileUtils.remove_entry(@scratch_base) if @scratch_base && Dir.exist?(@scratch_base)
    FileUtils.rm_rf(@clone_path) if @clone_path && File.directory?(@clone_path)
  end

  test "scratch contents survive archive, deferred cleanup and unarchive" do
    @session.archive!
    @session.reload

    # The undo window closes and the clone is reaped.
    DeferredCloneCleanupJob.perform_now(@session.id, @session.archived_at.iso8601)

    assert_not File.directory?(@clone_path), "the clone is still reaped at the end of the undo window"
    assert File.exist?(@handoff), "scratch must outlive the deferred clone cleanup"
    assert_not_nil @session.reload.trash_after,
      "the trash deadline must stay set so the retained scratch dir is reaped later"

    # Unarchive, exactly as session 958 did: the clone is gone, so it is recreated
    # from the remote and the session resumes.
    new_clone_path = "/tmp/test-clone-scratch-roundtrip-recreated-#{SecureRandom.hex(4)}"
    mock_fs = MockFileSystemAdapter.new
    mock_create_clone = lambda do |_git_root, **_kwargs|
      { clone_path: new_clone_path, working_directory: new_clone_path }
    end

    result = GitCloneService.stub :create_clone, mock_create_clone do
      mock_fs.mkdir_p(new_clone_path)
      UnarchiveSessionService.call(session: @session, file_system: mock_fs)
    end

    assert result.success?, "unarchive should succeed: #{result.error}"
    assert_equal true, @session.reload.metadata["clone_recreated"]

    assert File.exist?(@handoff), "scratch must survive the archive -> unarchive round trip"
    assert_equal "state the session maintained all day", File.read(@handoff)

    # Resume recreates the directory. mkdir_p is a no-op on an existing dir, so
    # the contents are still there for the resumed session to read.
    assert_equal @scratch_path, SessionScratchDirectory.ensure_for(@session.id)
    assert_equal "state the session maintained all day", File.read(@handoff)
  end

  test "scratch is reaped once the trash retention deadline passes" do
    @session.archive!
    @session.reload
    DeferredCloneCleanupJob.perform_now(@session.id, @session.archived_at.iso8601)
    assert File.exist?(@handoff), "scratch is retained, not deleted, at the end of the undo window"

    # Nobody restored the session; the retention window runs out.
    @session.update_column(:trash_after, 1.minute.ago)
    EmptyTrashJob.perform_now

    assert_not Dir.exist?(@scratch_path), "scratch dies with the trash, not with the undo window"
    assert_nil @session.reload.trash_after
  end
end
