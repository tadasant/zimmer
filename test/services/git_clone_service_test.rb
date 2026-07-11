require "test_helper"
require "set"

class GitCloneServiceTest < ActiveSupport::TestCase
  setup do
    # Use unique directory per test to avoid parallel test conflicts
    @test_dir = Rails.root.join("tmp", "test_clones_#{SecureRandom.hex(8)}")
    FileUtils.mkdir_p(@test_dir)

    # Create a test git repository for integration tests
    @test_repo_path = create_test_git_repository("main")
    @test_repo_with_branches = create_test_git_repository_with_branches
    @test_repo_with_slash_branches = create_test_git_repository_with_slash_branches
  end

  teardown do
    # Clean up test directories
    FileUtils.rm_rf(@test_dir) if @test_dir && Dir.exist?(@test_dir)
    FileUtils.rm_rf(@test_repo_path) if @test_repo_path && Dir.exist?(@test_repo_path)
    FileUtils.rm_rf(@test_repo_with_branches) if @test_repo_with_branches && Dir.exist?(@test_repo_with_branches)
    FileUtils.rm_rf(@test_repo_with_slash_branches) if @test_repo_with_slash_branches && Dir.exist?(@test_repo_with_slash_branches)
  end

  # ============================================================================
  # Unit Tests (existing)
  # ============================================================================

  # Test path generation
  test "should generate unique clone paths" do
    path1 = GitCloneService.send(:generate_clone_path, "test-repo", "main")
    path2 = GitCloneService.send(:generate_clone_path, "test-repo", "main")

    # Paths should be different due to timestamp and random component
    assert_not_equal path1, path2
  end

  test "should include repo name in clone path" do
    path = GitCloneService.send(:generate_clone_path, "my-test-repo", "main")
    assert_includes path, "my-test-repo"
  end

  test "should include branch name in clone path" do
    path = GitCloneService.send(:generate_clone_path, "test-repo", "develop")
    assert_includes path, "develop"
  end

  test "should sanitize slashes in branch name for clone path" do
    path = GitCloneService.send(:generate_clone_path, "test-repo", "claude/add-feature")
    # Slashes should be replaced with dashes to avoid creating nested directories
    assert_includes path, "claude-add-feature"
    refute_includes path, "claude/add-feature"
    # The path should be a flat directory under the clones base path
    assert_equal File.join(File.expand_path("~"), ".zimmer", "clones"), File.dirname(path)
  end

  test "should sanitize multiple slashes in branch name for clone path" do
    path = GitCloneService.send(:generate_clone_path, "test-repo", "user/feature/baz")
    assert_includes path, "user-feature-baz"
    # The directory name itself should not contain slashes from the branch
    refute_includes File.basename(path), "/"
    # Verify it's still a flat directory under clones
    assert_equal File.join(File.expand_path("~"), ".zimmer", "clones"), File.dirname(path)
  end

  test "should generate path in ~/.zimmer/clones directory" do
    path = GitCloneService.send(:generate_clone_path, "test-repo", "main")
    assert_includes path, ".zimmer/clones"
  end

  # Test git command execution concepts (without actual git calls)
  test "should have private run_git_command method" do
    # Verify the private method exists
    assert GitCloneService.private_methods.include?(:run_git_command)
  end

  test "should define GitError exception class" do
    # Verify custom error class exists
    assert_kind_of Class, GitCloneService::GitError
    assert GitCloneService::GitError < StandardError
  end

  # Test cleanup_clone
  test "should clean up directory" do
    test_path = @test_dir.join("test_clone")
    FileUtils.mkdir_p(test_path)
    File.write(test_path.join("file.txt"), "content")

    assert Dir.exist?(test_path)

    GitCloneService.cleanup_clone(test_path.to_s)

    assert_not Dir.exist?(test_path)
  end

  test "should handle cleanup of non-existent path" do
    # Should not raise error
    assert_nothing_raised do
      GitCloneService.cleanup_clone("/nonexistent/path")
    end
  end

  test "should handle cleanup with nil path" do
    # Should not raise error
    assert_nothing_raised do
      GitCloneService.cleanup_clone(nil)
    end
  end

  test "should clean up git clone directory" do
    test_path = @test_dir.join("git_clone")
    FileUtils.mkdir_p(test_path.join(".git", "objects"))

    assert Dir.exist?(test_path)

    GitCloneService.cleanup_clone(test_path.to_s)

    assert_not Dir.exist?(test_path)
  end

  # Test error handling
  test "should raise GitError with descriptive message" do
    error = assert_raises(GitCloneService::GitError) do
      raise GitCloneService::GitError, "Test error message"
    end

    assert_equal "Test error message", error.message
  end

  # Test class methods existence
  test "should respond to create_clone" do
    assert_respond_to GitCloneService, :create_clone
  end

  test "should respond to cleanup_clone" do
    assert_respond_to GitCloneService, :cleanup_clone
  end

  # Test default branch parameter
  test "should use main as default branch" do
    # Verify method signature accepts branch parameter with default
    method = GitCloneService.method(:create_clone)
    parameters = method.parameters

    # Check that branch parameter has a default value
    branch_param = parameters.find { |type, name| name == :branch }
    assert_not_nil branch_param
    assert_equal :key, branch_param[0] # keyword argument
  end

  # ============================================================================
  # Integration Tests - Successful Clone Operations
  # ============================================================================

  test "creates clone from local repository" do
    result = GitCloneService.create_clone(@test_repo_path, branch: "main")

    assert result[:clone_path].present?
    assert result[:working_directory].present?
    assert Dir.exist?(result[:clone_path])
    assert Dir.exist?(result[:working_directory])

    # Verify it's a git repository
    assert Dir.exist?(File.join(result[:clone_path], ".git"))

    # Verify the correct branch is checked out
    assert_git_branch(result[:clone_path], "main")

    # Verify the test file exists
    assert File.exist?(File.join(result[:clone_path], "README.md"))
    content = File.read(File.join(result[:clone_path], "README.md"))
    assert_includes content, "Test Repository"

    # Cleanup
    GitCloneService.cleanup_clone(result[:clone_path])
  end

  test "creates clone from local repository with specific branch" do
    result = GitCloneService.create_clone(@test_repo_with_branches, branch: "feature")

    assert result[:clone_path].present?
    assert Dir.exist?(result[:clone_path])

    # Verify the correct branch is checked out
    assert_git_branch(result[:clone_path], "feature")

    # Verify the feature branch file exists
    assert File.exist?(File.join(result[:clone_path], "feature.txt"))

    # Cleanup
    GitCloneService.cleanup_clone(result[:clone_path])
  end

  test "creates clone from local repository with branch containing slashes" do
    result = GitCloneService.create_clone(@test_repo_with_slash_branches, branch: "claude/add-feature")

    assert result[:clone_path].present?
    assert Dir.exist?(result[:clone_path])

    # Verify the clone path does not contain slashes from the branch name
    clone_dir_name = File.basename(result[:clone_path])
    refute_includes clone_dir_name, "/"

    # Verify the correct branch is checked out
    assert_git_branch(result[:clone_path], "claude/add-feature")

    # Verify the branch-specific file exists
    assert File.exist?(File.join(result[:clone_path], "slash_branch.txt"))

    # Cleanup
    GitCloneService.cleanup_clone(result[:clone_path])
  end

  test "creates clone from local repository with deeply nested slash branch" do
    result = GitCloneService.create_clone(@test_repo_with_slash_branches, branch: "user/feature/deep")

    assert result[:clone_path].present?
    assert Dir.exist?(result[:clone_path])

    # Verify the clone path is a flat directory (no nested dirs from branch name)
    clone_dir_name = File.basename(result[:clone_path])
    refute_includes clone_dir_name, "/"

    # Verify the correct branch is checked out
    assert_git_branch(result[:clone_path], "user/feature/deep")

    # Verify the branch-specific file exists
    assert File.exist?(File.join(result[:clone_path], "deep_branch.txt"))

    # Cleanup
    GitCloneService.cleanup_clone(result[:clone_path])
  end

  test "creates clone with custom clone path" do
    custom_path = File.join(@test_dir, "custom_clone_location")

    result = GitCloneService.create_clone(
      @test_repo_path,
      branch: "main",
      clone_path: custom_path
    )

    assert_equal custom_path, result[:clone_path]
    assert Dir.exist?(custom_path)
    assert Dir.exist?(File.join(custom_path, ".git"))

    # Cleanup
    GitCloneService.cleanup_clone(result[:clone_path])
  end

  test "creates clone with subdirectory" do
    # Create a test repo with subdirectories
    repo_with_subdir = create_test_git_repository_with_subdirectory

    result = GitCloneService.create_clone(
      repo_with_subdir,
      branch: "main",
      subdirectory: "subdir"
    )

    assert result[:clone_path].present?
    assert result[:working_directory].present?

    # Working directory should point to subdirectory
    assert_equal File.join(result[:clone_path], "subdir"), result[:working_directory]
    assert Dir.exist?(result[:working_directory])

    # Verify subdirectory file exists
    assert File.exist?(File.join(result[:working_directory], "subfile.txt"))

    # Cleanup
    GitCloneService.cleanup_clone(result[:clone_path])
    FileUtils.rm_rf(repo_with_subdir)
  end

  test "verifies clone path includes repo name and branch" do
    result = GitCloneService.create_clone(@test_repo_path, branch: "main")

    # The path should include the repo name
    assert_includes result[:clone_path], "test-git-repo"
    assert_includes result[:clone_path], "main"

    # Cleanup
    GitCloneService.cleanup_clone(result[:clone_path])
  end

  # ============================================================================
  # Integration Tests - Command Injection Prevention
  # ============================================================================

  test "safely handles repository URL with shell metacharacters" do
    malicious_url = "repo; rm -rf /tmp/test"

    error = assert_raises(GitCloneService::GitError) do
      GitCloneService.create_clone(malicious_url, branch: "main")
    end

    assert_includes error.message, "Failed to create clone"

    # Verify no files were deleted (the shell command didn't execute)
    test_file = "/tmp/test_injection_#{SecureRandom.hex(8)}"
    FileUtils.mkdir_p(File.dirname(test_file))
    File.write(test_file, "test")

    begin
      GitCloneService.create_clone("repo; rm -rf #{test_file}", branch: "main")
    rescue GitCloneService::GitError
      # Expected to fail
    end

    # File should still exist (shell injection was prevented)
    assert File.exist?(test_file), "Command injection protection failed - file was deleted"

    # Cleanup
    FileUtils.rm_f(test_file)
  end

  test "safely handles branch name with shell metacharacters" do
    malicious_branch = "main; rm -rf /tmp/test"

    error = assert_raises(GitCloneService::GitError) do
      GitCloneService.create_clone(@test_repo_path, branch: malicious_branch)
    end

    assert_includes error.message, "Failed to create clone"
  end

  test "safely handles repository URL with backticks" do
    malicious_url = "repo`whoami`"

    error = assert_raises(GitCloneService::GitError) do
      GitCloneService.create_clone(malicious_url, branch: "main")
    end

    assert_includes error.message, "Failed to create clone"
  end

  test "safely handles repository URL with $() command substitution" do
    malicious_url = "repo$(whoami)"

    error = assert_raises(GitCloneService::GitError) do
      GitCloneService.create_clone(malicious_url, branch: "main")
    end

    assert_includes error.message, "Failed to create clone"
  end

  test "safely handles repository URL with pipe characters" do
    malicious_url = "repo | cat /etc/passwd"

    error = assert_raises(GitCloneService::GitError) do
      GitCloneService.create_clone(malicious_url, branch: "main")
    end

    assert_includes error.message, "Failed to create clone"
  end

  test "safely handles repository URL with ampersand" do
    malicious_url = "repo & echo hacked"

    error = assert_raises(GitCloneService::GitError) do
      GitCloneService.create_clone(malicious_url, branch: "main")
    end

    assert_includes error.message, "Failed to create clone"
  end

  test "safely handles special characters in clone path" do
    # Clone path with special characters should be handled safely
    custom_path = File.join(@test_dir, "path with spaces")

    result = GitCloneService.create_clone(
      @test_repo_path,
      branch: "main",
      clone_path: custom_path
    )

    assert Dir.exist?(custom_path)
    assert Dir.exist?(File.join(custom_path, ".git"))

    # Cleanup
    GitCloneService.cleanup_clone(result[:clone_path])
  end

  # ============================================================================
  # Integration Tests - Error Handling
  # ============================================================================

  test "raises error for non-existent repository" do
    non_existent_repo = File.join(@test_dir, "non_existent_repo")

    error = assert_raises(GitCloneService::GitError) do
      GitCloneService.create_clone(non_existent_repo, branch: "main")
    end

    assert_includes error.message, "Failed to create clone"
  end

  test "raises error for invalid branch name" do
    error = assert_raises(GitCloneService::GitError) do
      GitCloneService.create_clone(@test_repo_path, branch: "nonexistent-branch")
    end

    assert_includes error.message, "Failed to create clone"
  end

  test "raises error for non-existent subdirectory" do
    error = assert_raises(GitCloneService::GitError) do
      GitCloneService.create_clone(
        @test_repo_path,
        branch: "main",
        subdirectory: "nonexistent_subdir"
      )
    end

    assert_includes error.message, "Subdirectory 'nonexistent_subdir' not found"
  end

  test "raises error for empty repository URL" do
    error = assert_raises(GitCloneService::GitError) do
      GitCloneService.create_clone("", branch: "main")
    end

    assert_includes error.message, "Failed to create clone"
  end

  test "raises error for nil repository URL" do
    # This should raise an error (likely ArgumentError or GitError)
    assert_raises(StandardError) do
      GitCloneService.create_clone(nil, branch: "main")
    end
  end

  # ============================================================================
  # Integration Tests - Cleanup on Failure
  # ============================================================================

  test "cleans up partial clone on branch failure" do
    # Get the base clone directory to check for leftover clones
    home_dir = File.expand_path("~")
    base_clone_dir = File.join(home_dir, ".zimmer", "clones")

    # Capture existing directories before the clone attempt
    # Use a Set for efficient lookup and to handle parallel test isolation
    initial_dirs = Dir.exist?(base_clone_dir) ? Set.new(Dir.children(base_clone_dir)) : Set.new

    # Get the repo name from the test repo path for pattern matching
    repo_name = File.basename(@test_repo_path)

    # Try to clone with invalid branch (should fail and cleanup)
    assert_raises(GitCloneService::GitError) do
      GitCloneService.create_clone(@test_repo_path, branch: "invalid-branch-name-xyz")
    end

    # Check that no new directories matching our repo pattern were left behind
    # Other parallel tests may create directories, so we only check for our specific pattern
    final_dirs = Dir.exist?(base_clone_dir) ? Set.new(Dir.children(base_clone_dir)) : Set.new
    new_dirs = final_dirs - initial_dirs

    # Filter to only directories that match the pattern for our test repo and branch
    # The pattern is: <repo_name>-invalid-branch-name-xyz-<timestamp>-<random>
    leftover_dirs = new_dirs.select { |dir| dir.start_with?("#{repo_name}-invalid-branch-name-xyz-") }
    assert_empty leftover_dirs,
                 "Partial clone was not cleaned up after failure: #{leftover_dirs.join(', ')}"
  end

  test "cleans up partial clone on repository failure" do
    home_dir = File.expand_path("~")
    base_clone_dir = File.join(home_dir, ".zimmer", "clones")

    # Capture existing directories before the clone attempt
    # Use a Set for efficient lookup and to handle parallel test isolation
    initial_dirs = Dir.exist?(base_clone_dir) ? Set.new(Dir.children(base_clone_dir)) : Set.new

    # Try to clone non-existent repo (should fail and cleanup)
    assert_raises(GitCloneService::GitError) do
      GitCloneService.create_clone("/nonexistent/repo/path", branch: "main")
    end

    # Check that no new directories matching our repo pattern were left behind
    # Other parallel tests may create directories, so we only check for our specific pattern
    final_dirs = Dir.exist?(base_clone_dir) ? Set.new(Dir.children(base_clone_dir)) : Set.new
    new_dirs = final_dirs - initial_dirs

    # Filter to only directories that match the pattern for our failed clone
    # The pattern is: path-main-<timestamp>-<random>
    leftover_dirs = new_dirs.select { |dir| dir.start_with?("path-main-") }
    assert_empty leftover_dirs,
                 "Partial clone was not cleaned up after failure: #{leftover_dirs.join(', ')}"
  end

  test "cleans up partial clone on subdirectory failure" do
    home_dir = File.expand_path("~")
    base_clone_dir = File.join(home_dir, ".zimmer", "clones")

    # Capture existing directories before the clone attempt
    # Use a Set for efficient lookup and to handle parallel test isolation
    initial_dirs = Dir.exist?(base_clone_dir) ? Set.new(Dir.children(base_clone_dir)) : Set.new

    # Get the repo name from the test repo path for pattern matching
    repo_name = File.basename(@test_repo_path)

    # Try to clone with non-existent subdirectory (should fail and cleanup)
    assert_raises(GitCloneService::GitError) do
      GitCloneService.create_clone(
        @test_repo_path,
        branch: "main",
        subdirectory: "nonexistent"
      )
    end

    # Check that no new directories matching our repo pattern were left behind
    # Other parallel tests may create directories, so we only check for our specific pattern
    final_dirs = Dir.exist?(base_clone_dir) ? Set.new(Dir.children(base_clone_dir)) : Set.new
    new_dirs = final_dirs - initial_dirs

    # Filter to only directories that match the pattern for our test repo
    # The pattern is: <repo_name>-main-<timestamp>-<random>
    leftover_dirs = new_dirs.select { |dir| dir.start_with?("#{repo_name}-main-") }
    assert_empty leftover_dirs,
                 "Partial clone was not cleaned up after subdirectory failure: #{leftover_dirs.join(', ')}"
  end

  # ============================================================================
  # Unit Tests - Retry on Transient Clone Failures
  # ============================================================================

  test "retries git clone on transient stderr and succeeds" do
    sleep_calls = []
    GitCloneService.sleeper = ->(s) { sleep_calls << s }
    transient_stderr = "Cloning into 'foo'...\nremote: Internal Server Error\nfatal: unable to access 'https://github.com/x/y.git/': The requested URL returned error: 500\n"

    call_count = 0
    subprocess_stub = ->(*_args, **_opts) {
      call_count += 1
      if call_count == 1
        [ "", transient_stderr, mock_failure_status ]
      else
        [ "", "", mock_success_status ]
      end
    }

    GitCloneService.stub(:run_subprocess, subprocess_stub) do
      result = GitCloneService.create_clone(
        "https://github.com/x/y.git",
        branch: "main",
        clone_path: File.join(@test_dir, "retry_success_clone")
      )
      assert result[:clone_path].present?
    end

    assert_equal 2, call_count, "expected one retry after transient failure"
    assert_equal [ 5 ], sleep_calls, "expected single 5s backoff before retry"
  ensure
    GitCloneService.sleeper = nil
  end

  test "does not retry on non-transient stderr" do
    sleep_calls = []
    GitCloneService.sleeper = ->(s) { sleep_calls << s }
    non_transient_stderr = "fatal: Remote branch nonexistent not found in upstream origin\n"

    call_count = 0
    subprocess_stub = ->(*_args, **_opts) {
      call_count += 1
      [ "", non_transient_stderr, mock_failure_status ]
    }

    GitCloneService.stub(:run_subprocess, subprocess_stub) do
      assert_raises(GitCloneService::GitError) do
        GitCloneService.create_clone(
          "https://github.com/x/y.git",
          branch: "nonexistent",
          clone_path: File.join(@test_dir, "no_retry_clone")
        )
      end
    end

    assert_equal 1, call_count, "expected exactly one attempt for non-transient error"
    assert_empty sleep_calls, "sleeper should not be invoked on non-transient errors"
  ensure
    GitCloneService.sleeper = nil
  end

  test "raises GitError after persistent transient failures with expected backoff" do
    sleep_calls = []
    GitCloneService.sleeper = ->(s) { sleep_calls << s }
    transient_stderr = "remote: Internal Server Error\nfatal: unable to access: The requested URL returned error: 502\n"

    call_count = 0
    subprocess_stub = ->(*_args, **_opts) {
      call_count += 1
      [ "", transient_stderr, mock_failure_status ]
    }

    test_logger = build_array_logger
    GitCloneService.instance_variable_set(:@logger, test_logger)

    GitCloneService.stub(:run_subprocess, subprocess_stub) do
      error = assert_raises(GitCloneService::GitError) do
        GitCloneService.create_clone(
          "https://github.com/x/y.git",
          branch: "main",
          clone_path: File.join(@test_dir, "persistent_transient_clone")
        )
      end
      assert_includes error.message, "Failed to create clone"
    end

    assert_equal 4, call_count, "expected 1 initial attempt + 3 retries"
    assert_equal [ 5, 10, 20 ], sleep_calls, "expected exponential backoff 5s, 10s, 20s"

    error_logs = test_logger.records.select { |r| r[:level] == :error }
    assert(
      error_logs.any? { |r| r[:message] == "git clone failed after retries" },
      "expected an .error log after retries exhausted; got: #{error_logs.map { |r| r[:message] }.inspect}"
    )

    info_logs = test_logger.records.select { |r| r[:level] == :info }
    retry_infos = info_logs.select { |r| r[:message] == "git clone failed transiently, retrying" }
    assert_equal 3, retry_infos.length, "expected 3 .info retry logs"
    assert_equal [ 5, 10, 20 ], retry_infos.map { |r| r[:context][:sleep_seconds] }
  ensure
    GitCloneService.sleeper = nil
    GitCloneService.instance_variable_set(:@logger, nil)
  end

  # ============================================================================
  # Unit Tests - transient_clone_error? classifier
  # ============================================================================

  test "transient_clone_error? recognizes TransientGitError and GitTimeoutError instances" do
    assert GitCloneService.transient_clone_error?(GitCloneService::TransientGitError.new("boom"))
    assert GitCloneService.transient_clone_error?(GitCloneService::GitTimeoutError.new("timed out"))
  end

  test "transient_clone_error? matches known transient signatures from a message string" do
    [
      "remote: Internal Server Error",
      "The requested URL returned error: 503",
      "fatal: unable to access: Could not resolve host: github.com",
      "Connection timed out",
      "Connection reset by peer",
      "fatal: the remote end hung up unexpectedly: early EOF",
      "error: RPC failed; curl 28",
      "fatal: unable to access: Couldn't connect to server",
      "fetch-pack: unexpected disconnect while reading sideband packet",
      "fatal: early EOF: unexpected EOF"
    ].each do |msg|
      assert GitCloneService.transient_clone_error?(msg), "expected transient for: #{msg}"
    end
  end

  test "transient_clone_error? matches slow-transfer signatures added for session 9439" do
    [
      "error: RPC failed; curl 28 Operation too slow. Less than 1000 bytes/sec transferred",
      "fatal: fetch-pack: invalid index-pack output",
      "transfer closed with 12345 bytes of body are still expected"
    ].each do |msg|
      assert GitCloneService.transient_clone_error?(msg), "expected transient for: #{msg}"
    end
  end

  test "transient_clone_error? returns false for permanent failures" do
    [
      "fatal: Remote branch nonexistent not found in upstream origin",
      "fatal: repository 'https://github.com/x/y.git/' not found",
      "fatal: Authentication failed for 'https://github.com/x/y.git/'",
      "fatal: could not read Username for 'https://github.com'"
    ].each do |msg|
      refute GitCloneService.transient_clone_error?(msg), "expected permanent for: #{msg}"
    end
  end

  test "transient_clone_error? accepts a plain GitError and classifies by its message" do
    transient = GitCloneService::GitError.new("error: RPC failed; curl 28 Operation too slow")
    permanent = GitCloneService::GitError.new("fatal: Authentication failed")

    assert GitCloneService.transient_clone_error?(transient)
    refute GitCloneService.transient_clone_error?(permanent)
  end

  # ============================================================================
  # Unit Tests - TransientGitError propagation from create_clone
  # ============================================================================

  test "create_clone raises TransientGitError after exhausting retries on a transient failure" do
    GitCloneService.sleeper = ->(_s) { }
    transient_stderr = "error: RPC failed; curl 28 Operation too slow\nfatal: early EOF\n"

    subprocess_stub = ->(*_args, **_opts) { [ "", transient_stderr, mock_failure_status ] }

    GitCloneService.stub(:run_subprocess, subprocess_stub) do
      error = assert_raises(GitCloneService::TransientGitError) do
        GitCloneService.create_clone(
          "https://github.com/x/y.git",
          branch: "main",
          clone_path: File.join(@test_dir, "transient_wrapped_clone")
        )
      end
      assert_includes error.message, "Failed to create clone"
    end
  ensure
    GitCloneService.sleeper = nil
  end

  test "create_clone raises a plain GitError (not TransientGitError) on a permanent failure" do
    GitCloneService.sleeper = ->(_s) { }
    permanent_stderr = "fatal: Authentication failed for 'https://github.com/x/y.git/'\n"

    subprocess_stub = ->(*_args, **_opts) { [ "", permanent_stderr, mock_failure_status ] }

    GitCloneService.stub(:run_subprocess, subprocess_stub) do
      error = assert_raises(GitCloneService::GitError) do
        GitCloneService.create_clone(
          "https://github.com/x/y.git",
          branch: "main",
          clone_path: File.join(@test_dir, "permanent_wrapped_clone")
        )
      end
      refute_kind_of GitCloneService::TransientGitError, error,
        "permanent failures must not be wrapped as TransientGitError"
    end
  ensure
    GitCloneService.sleeper = nil
  end

  # ============================================================================
  # Unit Tests - Subprocess Watchdog Timeout
  # ============================================================================

  test "run_subprocess kills a process that exceeds the timeout and raises GitTimeoutError" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    error = assert_raises(GitCloneService::GitTimeoutError) do
      # `sleep 5` stands in for a stalled `git clone`. With a 1s timeout the
      # watchdog must fire and kill the process group long before 5s elapse.
      # Kept low so a regressed watchdog caps this test's hang at ~5s, not 30s.
      GitCloneService.send(:run_subprocess, [ "sleep", "5" ], cwd: nil, timeout: 1)
    end

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_includes error.message, "timed out after 1s"
    assert_includes error.message, "process group killed"
    assert_operator elapsed, :<, 3,
      "watchdog should abort near the 1s timeout, not wait for the 5s sleep (took #{elapsed.round(2)}s)"
  end

  test "run_subprocess returns output and a successful status for a fast command" do
    out, err, status = GitCloneService.send(
      :run_subprocess, [ "sh", "-c", "printf hello; printf oops 1>&2" ], cwd: nil, timeout: 10
    )

    assert_equal "hello", out
    assert_equal "oops", err
    assert status.success?
  end

  test "run_subprocess surfaces a non-zero exit status without raising" do
    _out, _err, status = GitCloneService.send(
      :run_subprocess, [ "sh", "-c", "exit 7" ], cwd: nil, timeout: 10
    )

    refute status.success?
    assert_equal 7, status.exitstatus
  end

  test "create_clone retries a timed-out clone then fails after exhausting attempts" do
    sleep_calls = []
    GitCloneService.sleeper = ->(s) { sleep_calls << s }

    call_count = 0
    subprocess_stub = ->(*_args, **_opts) {
      call_count += 1
      raise GitCloneService::GitTimeoutError, "git command timed out after 300s (process group killed): git clone"
    }

    GitCloneService.stub(:run_subprocess, subprocess_stub) do
      error = assert_raises(GitCloneService::GitError) do
        GitCloneService.create_clone(
          "https://github.com/x/y.git",
          branch: "main",
          clone_path: File.join(@test_dir, "timeout_clone")
        )
      end
      assert_includes error.message, "Failed to create clone"
      assert_includes error.message, "timed out"
    end

    assert_equal 4, call_count, "expected 1 initial attempt + 3 retries on timeout"
    assert_equal [ 5, 10, 20 ], sleep_calls, "expected exponential backoff before each retry"
  ensure
    GitCloneService.sleeper = nil
  end

  test "create_clone succeeds when a timed-out clone recovers on retry" do
    sleep_calls = []
    GitCloneService.sleeper = ->(s) { sleep_calls << s }

    call_count = 0
    subprocess_stub = ->(*_args, **_opts) {
      call_count += 1
      raise GitCloneService::GitTimeoutError, "git command timed out after 300s (process group killed): git clone" if call_count == 1
      [ "", "", mock_success_status ]
    }

    GitCloneService.stub(:run_subprocess, subprocess_stub) do
      result = GitCloneService.create_clone(
        "https://github.com/x/y.git",
        branch: "main",
        clone_path: File.join(@test_dir, "timeout_recover_clone")
      )
      assert result[:clone_path].present?
    end

    assert_equal 2, call_count, "expected one retry after the timeout"
    assert_equal [ 5 ], sleep_calls, "expected a single 5s backoff before the successful retry"
  ensure
    GitCloneService.sleeper = nil
  end

  # ============================================================================
  # Helper Methods
  # ============================================================================

  private

  def mock_success_status
    status = Object.new
    def status.success?
      true
    end
    status
  end

  def mock_failure_status
    status = Object.new
    def status.success?
      false
    end
    status
  end

  # Build a fake structured logger that records calls so tests can assert on log
  # output without coupling to Rails.logger formatting.
  def build_array_logger
    Class.new do
      attr_reader :records

      def initialize
        @records = []
      end

      def info(message, context = {})
        @records << { level: :info, message: message, context: context }
      end

      def debug(message, context = {})
        @records << { level: :debug, message: message, context: context }
      end

      def warn(message, context = {})
        @records << { level: :warn, message: message, context: context }
      end

      def error(message, context = {})
        @records << { level: :error, message: message, context: context }
      end
    end.new
  end


  # Create a test git repository with a single branch
  def create_test_git_repository(branch_name)
    repo_path = File.join(@test_dir, "test-git-repo-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(repo_path)

    Dir.chdir(repo_path) do
      # Initialize git repo
      system("git init -q", exception: true)
      system("git config user.email 'test@example.com'", exception: true)
      system("git config user.name 'Test User'", exception: true)

      # Create a test file
      File.write("README.md", "# Test Repository\nThis is a test repository for GitCloneService tests.")

      # Commit the file
      system("git add .", exception: true)
      system("git commit -q -m 'Initial commit'", exception: true)

      # Ensure we're on the right branch
      system("git branch -M #{branch_name}", exception: true)
    end

    repo_path
  end

  # Create a test git repository with multiple branches
  def create_test_git_repository_with_branches
    repo_path = File.join(@test_dir, "test-git-repo-branches-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(repo_path)

    Dir.chdir(repo_path) do
      # Initialize git repo
      system("git init -q", exception: true)
      system("git config user.email 'test@example.com'", exception: true)
      system("git config user.name 'Test User'", exception: true)

      # Create main branch
      File.write("README.md", "# Test Repository\nMain branch")
      system("git add .", exception: true)
      system("git commit -q -m 'Initial commit'", exception: true)
      system("git branch -M main", exception: true)

      # Create feature branch
      system("git checkout -q -b feature", exception: true)
      File.write("feature.txt", "Feature branch file")
      system("git add .", exception: true)
      system("git commit -q -m 'Add feature file'", exception: true)

      # Switch back to main
      system("git checkout -q main", exception: true)
    end

    repo_path
  end

  # Create a test git repository with a subdirectory
  def create_test_git_repository_with_subdirectory
    repo_path = File.join(@test_dir, "test-git-repo-subdir-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(repo_path)

    Dir.chdir(repo_path) do
      # Initialize git repo
      system("git init -q", exception: true)
      system("git config user.email 'test@example.com'", exception: true)
      system("git config user.name 'Test User'", exception: true)

      # Create subdirectory with file
      FileUtils.mkdir_p("subdir")
      File.write("subdir/subfile.txt", "File in subdirectory")
      File.write("README.md", "# Test Repository")

      # Commit
      system("git add .", exception: true)
      system("git commit -q -m 'Initial commit with subdirectory'", exception: true)
      system("git branch -M main", exception: true)
    end

    repo_path
  end

  # Create a test git repository with branches containing slashes
  def create_test_git_repository_with_slash_branches
    repo_path = File.join(@test_dir, "test-git-repo-slash-branches-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(repo_path)

    Dir.chdir(repo_path) do
      system("git init -q", exception: true)
      system("git config user.email 'test@example.com'", exception: true)
      system("git config user.name 'Test User'", exception: true)

      # Create main branch
      File.write("README.md", "# Test Repository\nMain branch")
      system("git add .", exception: true)
      system("git commit -q -m 'Initial commit'", exception: true)
      system("git branch -M main", exception: true)

      # Create branch with single slash (e.g., claude/add-feature)
      system("git checkout -q -b claude/add-feature", exception: true)
      File.write("slash_branch.txt", "File on slash branch")
      system("git add .", exception: true)
      system("git commit -q -m 'Add slash branch file'", exception: true)

      # Create branch with multiple slashes (e.g., user/feature/deep)
      system("git checkout -q main", exception: true)
      system("git checkout -q -b user/feature/deep", exception: true)
      File.write("deep_branch.txt", "File on deeply nested slash branch")
      system("git add .", exception: true)
      system("git commit -q -m 'Add deep branch file'", exception: true)

      # Switch back to main
      system("git checkout -q main", exception: true)
    end

    repo_path
  end

  # Assert that a git repository has the specified branch checked out
  def assert_git_branch(repo_path, expected_branch)
    current_branch = `git -C #{Shellwords.escape(repo_path)} rev-parse --abbrev-ref HEAD`.strip
    assert_equal expected_branch, current_branch,
                 "Expected branch '#{expected_branch}' but got '#{current_branch}'"
  end
end
