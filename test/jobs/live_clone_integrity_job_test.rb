# frozen_string_literal: true

require "test_helper"

class LiveCloneIntegrityJobTest < ActiveJob::TestCase
  setup do
    @clones_base = Dir.mktmpdir("live-clone-integrity-test")
    @clone_path = File.join(@clones_base, "zimmer-main-1788364605-45c2382a")
    FileUtils.mkdir_p(File.join(@clone_path, ".git"))

    # Every other live fixture would otherwise be reported for a clone_path that
    # points nowhere on this machine.
    Session.where(status: Session::NON_REAPABLE_STATUSES)
      .find_each { |s| s.update_columns(metadata: (s.metadata || {}).except("clone_path")) }

    @session = sessions(:running)
    @session.update!(metadata: { "clone_path" => @clone_path })
  end

  teardown do
    FileUtils.rm_rf(@clones_base)
  end

  # Only this job's own `.error` lines are the subject; anything else logging an
  # error during the run is not what these tests are about. Mocha matches the
  # most recently declared expectation first, so the permissive stub goes first.
  def expect_integrity_error(&matcher)
    Rails.logger.stubs(:error)
    Rails.logger.expects(:error).with { |message| own_line?(message) && matcher.call(message.to_s) }.once
  end

  def expect_no_integrity_error
    Rails.logger.stubs(:error)
    Rails.logger.expects(:error).with { |message| own_line?(message) }.never
  end

  def own_line?(message)
    message.to_s.include?("[LiveCloneIntegrityJob]")
  end

  test "says nothing when every live clone is intact" do
    expect_no_integrity_error

    LiveCloneIntegrityJob.perform_now
  end

  test "reports at error when a live session's clone has lost its git tree" do
    # The zimmer#808 signature: the tree is gone, Zimmer's own scaffolding is not.
    FileUtils.rm_rf(File.join(@clone_path, ".git"))
    FileUtils.mkdir_p(File.join(@clone_path, ".claude"))
    File.write(File.join(@clone_path, ".mcp.json"), "{}")

    expect_integrity_error { |message| message.include?("session #{@session.id}") && message.include?(".mcp.json") }

    LiveCloneIntegrityJob.perform_now
  end

  test "reports a running session whose clone root is gone entirely" do
    FileUtils.rm_rf(@clone_path)

    expect_integrity_error { |message| message.include?("clone root") && message.include?("is gone") }

    LiveCloneIntegrityJob.perform_now
  end

  test "does not report a needs_input session whose clone was reaped and will be re-cloned on resume" do
    @session.update_columns(status: Session.statuses[:needs_input])
    FileUtils.rm_rf(@clone_path)

    expect_no_integrity_error

    LiveCloneIntegrityJob.perform_now
  end

  test "does not report a terminal session's missing clone" do
    @session.update_columns(status: Session.statuses[:archived])
    FileUtils.rm_rf(@clone_path)

    expect_no_integrity_error

    LiveCloneIntegrityJob.perform_now
  end

  test "does not report a fork whose clone was scaffolded empty on purpose" do
    FileUtils.rm_rf(File.join(@clone_path, ".git"))
    @session.update!(metadata: @session.metadata.merge("clone_scaffolded" => true))

    expect_no_integrity_error

    LiveCloneIntegrityJob.perform_now
  end

  test "reports a clone that has lost the session's agent root subdirectory" do
    @session.update!(subdirectory: "zimmer")

    expect_integrity_error { |message| message.include?("agent root zimmer") }

    LiveCloneIntegrityJob.perform_now
  end
end
