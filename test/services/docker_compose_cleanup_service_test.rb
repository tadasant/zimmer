# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class DockerComposeCleanupServiceTest < ActiveSupport::TestCase
  setup do
    @clone_path = "/tmp/test-clone-docker-#{SecureRandom.hex(4)}"
    @compose_dir = File.join(@clone_path, ".agent-containers")
    FileUtils.mkdir_p(@compose_dir)
    File.write(File.join(@compose_dir, "docker-compose.dev.yml"), "version: '3'\nservices:\n  app:\n    image: test\n")
  end

  teardown do
    FileUtils.rm_rf(@clone_path) if @clone_path && File.directory?(@clone_path)
  end

  test "runs docker compose down -v when compose file exists" do
    expected_command = [
      "docker", "compose", "-f",
      File.join(@clone_path, ".agent-containers/docker-compose.dev.yml"),
      "down", "-v", "--remove-orphans",
      "--timeout", "30"
    ]

    BoundedSubprocess.expects(:run)
      .with(expected_command, timeout: DockerComposeCleanupService::COMPOSE_DOWN_TIMEOUT)
      .returns([ "", "", stub(success?: true, exitstatus: 0) ])

    result = DockerComposeCleanupService.cleanup(@clone_path)

    assert result, "Should return true when cleanup was performed"
  end

  test "returns false when clone_path is nil" do
    BoundedSubprocess.expects(:run).never

    result = DockerComposeCleanupService.cleanup(nil)

    assert_not result
  end

  test "returns false when compose file does not exist" do
    FileUtils.rm_rf(@compose_dir)

    BoundedSubprocess.expects(:run).never

    result = DockerComposeCleanupService.cleanup(@clone_path)

    assert_not result
  end

  test "returns true even when docker compose down exits non-zero" do
    BoundedSubprocess.expects(:run).returns([ "", "error: something went wrong", stub(success?: false, exitstatus: 1) ])

    result = DockerComposeCleanupService.cleanup(@clone_path)

    assert result, "Should return true because the command was attempted"
  end

  test "returns false and does not raise when docker command raises an error" do
    BoundedSubprocess.expects(:run).raises(Errno::ENOENT, "docker not found")

    result = DockerComposeCleanupService.cleanup(@clone_path)

    assert_not result, "Should return false when an error occurs"
  end

  # The bound is real now, so it can actually fire — a Docker daemon that has
  # stopped answering (the #502 cgroup-OOM shape) gets its process group SIGKILLed
  # at COMPOSE_DOWN_TIMEOUT instead of holding the caller forever. Cleanup stays
  # non-fatal, which is what OrphanCloneFilesystemCleanupJob's wall-clock budget
  # assumes; the change is that the budget now holds.
  test "returns false and does not raise when the compose down is killed on the deadline" do
    BoundedSubprocess.expects(:run).raises(
      BoundedSubprocess::TimeoutError,
      "command timed out after 120s (process group killed): docker compose down"
    )

    result = DockerComposeCleanupService.cleanup(@clone_path)

    assert_not result, "a watchdog kill is logged and swallowed, not raised at the caller"
  end

  test "returns false when clone_path does not exist on disk" do
    nonexistent_path = "/tmp/nonexistent-clone-#{SecureRandom.hex(4)}"

    BoundedSubprocess.expects(:run).never

    result = DockerComposeCleanupService.cleanup(nonexistent_path)

    assert_not result
  end
end
