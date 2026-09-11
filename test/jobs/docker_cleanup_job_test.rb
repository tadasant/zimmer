# frozen_string_literal: true

require "test_helper"
require "ostruct"
require "minitest/mock"
require "mocha/minitest"

class DockerCleanupJobTest < ActiveJob::TestCase
  test "performs without raising" do
    assert_nothing_raised do
      DockerCleanupJob.perform_now
    end
  end

  test "extracts reclaimed space from docker output" do
    job = DockerCleanupJob.new
    output = "Deleted Containers:\nabc123\n\nTotal reclaimed space: 2.5GB"
    assert_equal "reclaimed 2.5GB", job.send(:extract_reclaimed, output)
  end

  test "extracts zero reclaimed space" do
    job = DockerCleanupJob.new
    output = "Total reclaimed space: 0B"
    assert_equal "reclaimed 0B", job.send(:extract_reclaimed, output)
  end

  test "find_stale_dev_server_projects identifies old dev-server containers" do
    job = DockerCleanupJob.new
    old_time = 8.hours.ago.strftime("%Y-%m-%d %H:%M:%S +0000 UTC")
    recent_time = 1.hour.ago.strftime("%Y-%m-%d %H:%M:%S +0000 UTC")

    docker_output = <<~OUTPUT
      ao-dev-abc12345\t#{old_time}
      ao-dev-def67890\t#{recent_time}
      pulsemcp-dev-aaa11111\t#{old_time}
      zimmer-dev-feature-x\t#{old_time}
      zimmer-dev-fresh\t#{recent_time}
      zimmer-dev-local\t#{old_time}
      zimmer-web-production-xyz\t#{old_time}
    OUTPUT

    success = OpenStruct.new(success?: true)
    Open3.stub(:capture3, [ docker_output, "", success ]) do
      stale = job.send(:find_stale_dev_server_projects)

      assert_includes stale, "ao-dev-abc12345", "Old ao-dev should be stale"
      assert_includes stale, "pulsemcp-dev-aaa11111", "Old pulsemcp-dev should be stale"
      assert_includes stale, "zimmer-dev-feature-x", "Old zimmer-dev (ac.sh) should be stale"
      assert_includes stale, "zimmer-dev-local", "Old zimmer-dev-local (manual) should be stale"
      assert_not_includes stale, "ao-dev-def67890", "Recent ao-dev should not be stale"
      assert_not_includes stale, "zimmer-dev-fresh", "Recent zimmer-dev should not be stale"
      assert_not_includes stale, "zimmer-web-production-xyz", "Non-dev containers should be excluded"
    end
  end

  # A `docker ps` that fails must leave a trace. Before #409 it returned `[]` silently, so a
  # daemon the worker could not reach read in the logs exactly like a clean run with nothing
  # to reap. The exit status and stderr are what tell those apart, so both go in the line.
  test "find_stale_dev_server_projects warns with exit status and stderr when docker ps fails" do
    job = DockerCleanupJob.new
    denied = "permission denied while trying to connect to the Docker API at unix:///var/run/docker.sock"
    failed = OpenStruct.new(success?: false, exitstatus: 1, termsig: nil)

    Rails.logger.expects(:warn).with(
      regexp_matches(/\[DockerCleanupJob\] Stale dev-server discovery failed; `docker ps` \(exit status 1: #{Regexp.escape(denied)}\)/)
    ).once

    Open3.stub(:capture3, [ "", denied, failed ]) do
      assert_equal [], job.send(:find_stale_dev_server_projects)
    end
  end

  # The other way `docker ps` fails: the binary is missing or cannot be executed, so Open3
  # raises and run_command hands back its FailedStatus stand-in. That stand-in has no exit
  # code to report, and describing it must not raise on the failure path.
  test "find_stale_dev_server_projects warns when docker cannot be executed at all" do
    job = DockerCleanupJob.new
    failed = DockerCleanupJob::FailedStatus.new(false)

    Rails.logger.expects(:warn).with(
      regexp_matches(/discovery failed; `docker ps` \(no exit code reported: No such file or directory - docker\)/)
    ).once

    Open3.stub(:capture3, [ "", "No such file or directory - docker", failed ]) do
      assert_equal [], job.send(:find_stale_dev_server_projects)
    end
  end

  # Nil is what Open3 returns when another waiter reaps the child first (see
  # SubprocessStatus). It is a failure whose exit code was never read, and the log line
  # has to say that rather than invent a phantom non-zero exit.
  test "find_stale_dev_server_projects warns when the status was never read" do
    job = DockerCleanupJob.new

    Rails.logger.expects(:warn).with(
      regexp_matches(/discovery failed; `docker ps` \(#{Regexp.escape(SubprocessStatus::REAPED_DESCRIPTION)}\)/)
    ).once

    Open3.stub(:capture3, [ "", "", nil ]) do
      assert_equal [], job.send(:find_stale_dev_server_projects)
    end
  end

  test "find_stale_dev_server_projects does not warn when docker ps succeeds with no containers" do
    job = DockerCleanupJob.new
    success = OpenStruct.new(success?: true)

    Rails.logger.expects(:warn).never

    Open3.stub(:capture3, [ "", "", success ]) do
      assert_equal [], job.send(:find_stale_dev_server_projects)
    end
  end

  test "emergency_cleanup warns when a prune fails instead of staying silent" do
    job = DockerCleanupJob.new
    failed = OpenStruct.new(success?: false, exitstatus: 1, termsig: nil)

    Rails.logger.expects(:warn).with(regexp_matches(/Emergency image prune failed: daemon down/)).once
    Rails.logger.expects(:warn).with(regexp_matches(/Emergency builder prune failed: daemon down/)).once

    Open3.stub(:capture3, [ "", "daemon down", failed ]) do
      job.send(:emergency_cleanup)
    end
  end

  test "disk_usage_percent parses df output" do
    job = DockerCleanupJob.new
    df_output = "Use%\n 84%\n"
    success = OpenStruct.new(success?: true)

    Open3.stub(:capture3, [ df_output, "", success ]) do
      assert_equal 84, job.send(:disk_usage_percent)
    end
  end

  test "run_command handles missing commands gracefully" do
    job = DockerCleanupJob.new
    _stdout, _stderr, status = job.send(:run_command, "nonexistent-command-that-does-not-exist-12345")
    assert_not status.success?
  end

  test "DEV_SERVER_PREFIXES covers known dev-server naming conventions" do
    prefixes = DockerCleanupJob::DEV_SERVER_PREFIXES
    assert prefixes.any? { |p| "zimmer-dev-abc12345".start_with?(p) }
    assert prefixes.any? { |p| "ao-dev-abc12345".start_with?(p) }
    assert prefixes.any? { |p| "pulsemcp-dev-abc12345".start_with?(p) }
    assert_not prefixes.any? { |p| "zimmer-web".start_with?(p) }
  end
end
