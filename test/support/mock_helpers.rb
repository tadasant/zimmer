# frozen_string_literal: true

# Helpers for setting up and configuring mock dependencies in tests.
# This module provides utilities to create and inject mock ProcessManager and FileSystemAdapter
# instances, eliminating the need for repetitive mock setup in individual tests.
#
# Usage in tests:
#   setup do
#     setup_mock_dependencies
#   end
#
#   teardown do
#     teardown_mock_dependencies
#   end
#
#   test "something" do
#     # @mock_process_manager and @mock_fs are available
#     # They are already injected into ProcessManager and FileSystemAdapter
#   end
module MockHelpers
  # Setup mock dependencies for tests
  # Creates and injects mock ProcessManager and FileSystemAdapter instances
  # Sets up @mock_process_manager and @mock_fs instance variables
  #
  # Example:
  #   setup do
  #     setup_mock_dependencies
  #   end
  def setup_mock_dependencies
    @mock_process_manager = create_mock_process_manager
    @mock_fs = create_mock_file_system

    inject_mock_dependencies
  end

  # Create configured MockProcessManager with optional custom behavior
  # @param config [Hash] Configuration for mock behavior
  # @option config [Proc] :spawn_hook Custom spawn behavior
  # @option config [Proc] :wait_hook Custom wait behavior
  # @option config [Proc] :kill_hook Custom kill behavior
  # @return [MockProcessManager] Configured mock process manager
  #
  # Example:
  #   # Default behavior (successful process)
  #   mock_pm = create_mock_process_manager
  #
  #   # Custom spawn behavior
  #   mock_pm = create_mock_process_manager(
  #     spawn_hook: ->(cmd, opts) { raise "Spawn failed" }
  #   )
  def create_mock_process_manager(config = {})
    mock = MockProcessManager.new

    # Set custom hooks only if provided
    # Otherwise use MockProcessManager's default behavior
    mock.spawn_hook = config[:spawn_hook] if config[:spawn_hook]
    mock.wait_hook = config[:wait_hook] if config[:wait_hook]
    mock.kill_hook = config[:kill_hook] if config[:kill_hook]

    mock
  end

  # Create configured MockFileSystemAdapter with optional initial files
  # @param initial_files [Hash] Map of file paths to contents
  # @return [MockFileSystemAdapter] Configured mock file system
  #
  # Example:
  #   mock_fs = create_mock_file_system(
  #     "/tmp/test.txt" => "content",
  #     "/tmp/config.json" => '{"key": "value"}'
  #   )
  def create_mock_file_system(initial_files = {})
    mock = MockFileSystemAdapter.new

    # Setup standard directories
    mock.mkdir_p(File.join(File.expand_path("~"), ".zimmer", "clones"))
    mock.mkdir_p(File.expand_path("~/.claude/projects"))

    # Add initial files
    initial_files.each do |path, content|
      mock.write(path, content)
    end

    mock
  end

  # Inject mocks into global singleton state
  # Makes @mock_process_manager and @mock_fs available to code under test
  def inject_mock_dependencies
    ProcessManager.instance = @mock_process_manager
    FileSystemAdapter.instance = @mock_fs
  end

  # Reset to real implementations
  # Call this in teardown to clean up mock state
  #
  # Example:
  #   teardown do
  #     teardown_mock_dependencies
  #   end
  def teardown_mock_dependencies
    ProcessManager.instance = nil
    FileSystemAdapter.instance = nil
  end
end
