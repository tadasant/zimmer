# frozen_string_literal: true

# Custom assertion helpers for common test patterns.
# Provides high-level assertions for process spawning, file operations,
# and background job enqueueing.
#
# Usage:
#   test "spawns process" do
#     setup_mock_dependencies
#     # ... code that spawns process ...
#     assert_process_spawned(@mock_process_manager, command_pattern: /claude/)
#   end
module AssertionHelpers
  # Assert that a process was spawned with specific command pattern and/or options
  # @param process_manager [MockProcessManager] The mock process manager to check
  # @param command_pattern [Regexp, nil] Optional regex to match against command
  # @param options [Hash] Optional hash of expected spawn options
  #
  # Example:
  #   assert_process_spawned(@mock_process_manager, command_pattern: /claude/)
  #   assert_process_spawned(@mock_process_manager, options: { chdir: "/tmp" })
  def assert_process_spawned(process_manager, command_pattern: nil, options: {})
    spawned = process_manager.spawned_processes
    assert spawned.any?, "Expected at least one process to be spawned"

    if command_pattern
      matching = spawned.select { |p| p[:command].join(" ").match?(command_pattern) }
      assert matching.any?, "No process spawned matching pattern: #{command_pattern}"
    end

    if options.any?
      last_spawn = spawned.last
      options.each do |key, expected_value|
        actual_value = last_spawn[:options][key]
        assert_equal expected_value, actual_value, "Expected #{key}: #{expected_value}, got: #{actual_value}"
      end
    end
  end

  # Assert that no processes were spawned
  # @param process_manager [MockProcessManager] The mock process manager to check
  #
  # Example:
  #   assert_no_process_spawned(@mock_process_manager)
  def assert_no_process_spawned(process_manager)
    spawned = process_manager.spawned_processes
    assert_empty spawned, "Expected no processes to be spawned, but found #{spawned.size}"
  end

  # Assert that a process was killed
  # @param process_manager [MockProcessManager] The mock process manager to check
  # @param pid [Integer, nil] Optional specific PID to check
  # @param signal [String, nil] Optional specific signal to check
  #
  # Example:
  #   assert_process_killed(@mock_process_manager, signal: "TERM")
  #   assert_process_killed(@mock_process_manager, pid: 12345)
  def assert_process_killed(process_manager, pid: nil, signal: nil)
    killed = process_manager.killed_processes
    assert killed.any?, "Expected at least one process to be killed"

    if pid
      assert killed.any? { |k| k[:pid] == pid }, "Process #{pid} was not killed"
    end

    if signal
      assert killed.any? { |k| k[:signal] == signal }, "No process killed with signal #{signal}"
    end
  end

  # Assert that a file was written to the file system
  # @param file_system [MockFileSystemAdapter] The mock file system to check
  # @param path [String] The expected file path
  # @param content [String, Regexp, nil] Optional content to match against
  #
  # Example:
  #   assert_file_written(@mock_fs, path: "/tmp/test.txt")
  #   assert_file_written(@mock_fs, path: "/tmp/test.txt", content: /hello/)
  def assert_file_written(file_system, path:, content: nil)
    assert file_system.exists?(path), "Expected file to exist: #{path}"

    if content
      actual_content = file_system.read(path)
      if content.is_a?(Regexp)
        assert_match content, actual_content, "File content does not match pattern"
      else
        assert_equal content, actual_content, "File content does not match"
      end
    end
  end

  # Assert that a directory exists in the file system
  # @param file_system [MockFileSystemAdapter] The mock file system to check
  # @param path [String] The expected directory path
  #
  # Example:
  #   assert_directory_exists(@mock_fs, path: "~/.zimmer/clones")
  def assert_directory_exists(file_system, path:)
    assert file_system.directory?(path), "Expected directory to exist: #{path}"
  end

  # Assert job enqueued with specific arguments
  # @param job_class [Class] The job class to check for
  # @param args [Array, nil] Optional expected arguments
  # @param queue [String, nil] Optional expected queue name
  #
  # Example:
  #   assert_job_enqueued(AgentSessionJob, args: [123])
  #   assert_job_enqueued(AgentSessionJob, queue: "default")
  def assert_job_enqueued(job_class, args: nil, queue: nil)
    enqueued_jobs = ActiveJob::Base.queue_adapter.enqueued_jobs
    matching = enqueued_jobs.select { |j| j[:job] == job_class }

    assert matching.any?, "No #{job_class} jobs enqueued"

    if args
      assert matching.any? { |j| j[:args] == args }, "No #{job_class} enqueued with args: #{args.inspect}"
    end

    if queue
      assert matching.any? { |j| j[:queue] == queue }, "No #{job_class} enqueued to queue: #{queue}"
    end
  end
end
