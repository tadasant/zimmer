# frozen_string_literal: true

require "test_helper"
require "ostruct"
require "minitest/mock"

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
      zimmer-web-production-xyz\t#{old_time}
    OUTPUT

    success = OpenStruct.new(success?: true)
    Open3.stub(:capture3, [ docker_output, "", success ]) do
      stale = job.send(:find_stale_dev_server_projects)

      assert_includes stale, "ao-dev-abc12345", "Old ao-dev should be stale"
      assert_includes stale, "pulsemcp-dev-aaa11111", "Old pulsemcp-dev should be stale"
      assert_not_includes stale, "ao-dev-def67890", "Recent ao-dev should not be stale"
      assert_not_includes stale, "zimmer-web-production-xyz", "Non-dev containers should be excluded"
    end
  end

  test "find_stale_dev_server_projects returns empty when docker fails" do
    job = DockerCleanupJob.new
    failed = DockerCleanupJob::FailedStatus.new(false)

    Open3.stub(:capture3, [ "", "error", failed ]) do
      assert_equal [], job.send(:find_stale_dev_server_projects)
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
    assert prefixes.any? { |p| "ao-dev-abc12345".start_with?(p) }
    assert prefixes.any? { |p| "pulsemcp-dev-abc12345".start_with?(p) }
    assert_not prefixes.any? { |p| "zimmer-web".start_with?(p) }
  end
end
