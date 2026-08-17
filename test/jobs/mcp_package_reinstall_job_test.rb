# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class McpPackageReinstallJobTest < ActiveJob::TestCase
  test "job can be enqueued" do
    assert_enqueued_with(job: McpPackageReinstallJob) do
      McpPackageReinstallJob.perform_later
    end
  end

  test "job logs warning when script not found" do
    # Create a mock that returns a non-existent path
    mock_root = mock("rails_root")
    mock_root.stubs(:join).with("bin", "preinstall-mcp-packages").returns(Pathname.new("/nonexistent/path"))

    # Stub Rails.root to return our mock
    Rails.stubs(:root).returns(mock_root)

    # The job should complete without raising an error
    assert_nothing_raised do
      McpPackageReinstallJob.new.perform
    end
  end

  test "job executes preinstall script successfully" do
    skip "Requires actual preinstall-mcp-packages script to be present"

    # This test would run the actual script
    # Only enable in environments where the script is available
    McpPackageReinstallJob.new.perform
  end

  test "runs the preinstall script under a wall-clock timeout" do
    script_path = Rails.root.join("bin", "preinstall-mcp-packages")
    assert File.exist?(script_path), "the preinstall script this job runs is missing from the repo"

    BoundedSubprocess.expects(:run)
      .with([ script_path.to_s ], timeout: McpPackageReinstallJob::PREINSTALL_TIMEOUT_SECONDS)
      .returns([ "ok", "", stub(success?: true, exitstatus: 0) ])

    McpPackageReinstallJob.new.perform
  end

  # A stalled npm must not hold a `default` scheduler thread forever: the queue has 4
  # of them, and CacheClearJob chains this job seconds after every worker boot.
  test "a timed-out preinstall is contained, warned about, and stops" do
    BoundedSubprocess.stubs(:run).raises(
      BoundedSubprocess::TimeoutError, "command timed out after 900s"
    )

    # General stubs first: mocha resolves the most recently defined expectation first,
    # so a catch-all defined last would swallow the specific ones below.
    Rails.logger.stubs(:info)
    Rails.logger.expects(:warn).with(regexp_matches(/reinstall timed out/)).once
    # The bound holding is not a script failure, so it must not page.
    Rails.logger.expects(:error).never
    # ...and it must return rather than fall through into the success branch.
    Rails.logger.expects(:info).with(regexp_matches(/completed successfully/)).never

    assert_nothing_raised do
      McpPackageReinstallJob.new.perform
    end
  end

  # BoundedSubprocess hands back a nil status when the child was reaped elsewhere
  # before its own waitpid ran (ECHILD). Reading it through SubprocessStatus is what
  # keeps that from being a NoMethodError.
  test "a nil exit status is reported as a failure rather than raising" do
    BoundedSubprocess.stubs(:run).returns([ "", "", nil ])

    Rails.logger.stubs(:error)
    Rails.logger.expects(:error).with(regexp_matches(/reinstall failed/)).at_least_once

    assert_nothing_raised do
      McpPackageReinstallJob.new.perform
    end
  end
end
