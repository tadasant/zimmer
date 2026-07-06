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

    Open3.expects(:capture3).with(*expected_command).returns([ "", "", stub(success?: true, exitstatus: 0) ])

    result = DockerComposeCleanupService.cleanup(@clone_path)

    assert result, "Should return true when cleanup was performed"
  end

  test "returns false when clone_path is nil" do
    Open3.expects(:capture3).never

    result = DockerComposeCleanupService.cleanup(nil)

    assert_not result
  end

  test "returns false when compose file does not exist" do
    FileUtils.rm_rf(@compose_dir)

    Open3.expects(:capture3).never

    result = DockerComposeCleanupService.cleanup(@clone_path)

    assert_not result
  end

  test "returns true even when docker compose down exits non-zero" do
    Open3.expects(:capture3).returns([ "", "error: something went wrong", stub(success?: false, exitstatus: 1) ])

    result = DockerComposeCleanupService.cleanup(@clone_path)

    assert result, "Should return true because the command was attempted"
  end

  test "returns false and does not raise when docker command raises an error" do
    Open3.expects(:capture3).raises(Errno::ENOENT, "docker not found")

    result = DockerComposeCleanupService.cleanup(@clone_path)

    assert_not result, "Should return false when an error occurs"
  end

  test "returns false when clone_path does not exist on disk" do
    nonexistent_path = "/tmp/nonexistent-clone-#{SecureRandom.hex(4)}"

    Open3.expects(:capture3).never

    result = DockerComposeCleanupService.cleanup(nonexistent_path)

    assert_not result
  end
end
