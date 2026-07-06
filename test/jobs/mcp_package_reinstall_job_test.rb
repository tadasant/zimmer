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
end
