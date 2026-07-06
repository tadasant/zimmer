# frozen_string_literal: true

require "test_helper"
require "open3"

class CloneArtifactServiceTest < ActiveSupport::TestCase
  # Records every log call so a test can assert the level a message was logged at.
  class RecordingLogger
    attr_reader :calls

    def initialize
      @calls = []
    end

    def info(message, context = {})
      @calls << { level: :info, message: message, context: context }
    end

    def debug(message, context = {})
      @calls << { level: :debug, message: message, context: context }
    end

    def warn(message, context = {})
      @calls << { level: :warn, message: message, context: context }
    end

    def error(message, context = {})
      @calls << { level: :error, message: message, context: context }
    end

    def level_for(message_fragment)
      @calls.find { |c| c[:message].to_s.include?(message_fragment) }&.fetch(:level)
    end
  end

  setup do
    @service = CloneArtifactService.new
    @session_id = rand(900_000..999_999) # Unique per test run to avoid parallel contamination
    @bare_path = nil
    @repo_path = nil
  end

  teardown do
    FileUtils.rm_rf(@repo_path) if @repo_path && File.directory?(@repo_path)
    FileUtils.rm_rf(@bare_path) if @bare_path && File.directory?(@bare_path)
    artifacts_dir = @service.artifacts_path_for(@session_id)
    FileUtils.rm_rf(artifacts_dir) if File.directory?(artifacts_dir)
  end

  # === check_dirty_state tests ===

  test "check_dirty_state returns clean for a clean repo" do
    create_test_repo

    result = @service.check_dirty_state(@repo_path)

    assert_not result.dirty?
    assert_not result.has_uncommitted?
    assert_not result.has_unpushed_commits?
  end

  test "check_dirty_state detects uncommitted changes" do
    create_test_repo(dirty: true)

    result = @service.check_dirty_state(@repo_path)

    assert result.dirty?
    assert result.has_uncommitted?
    assert_includes result.details, "uncommitted changes"
  end

  test "check_dirty_state detects unpushed commits" do
    create_test_repo(unpushed_commits: true)

    result = @service.check_dirty_state(@repo_path)

    assert result.dirty?
    assert result.has_unpushed_commits?
    assert_includes result.details, "unpushed commit"
  end

  test "check_dirty_state detects both uncommitted and unpushed" do
    create_test_repo(dirty: true, unpushed_commits: true)

    result = @service.check_dirty_state(@repo_path)

    assert result.dirty?
    assert result.has_uncommitted?
    assert result.has_unpushed_commits?
  end

  test "check_dirty_state returns clean for non-existent path" do
    result = @service.check_dirty_state("/nonexistent/path")

    assert_not result.dirty?
    assert_includes result.details, "does not exist"
  end

  test "check_dirty_state returns clean for nil path" do
    result = @service.check_dirty_state(nil)

    assert_not result.dirty?
  end

  # Regression: a clone deleted between the early-return guard and the git
  # invocation raises Errno::ENOENT. This is a benign TOCTOU race with the
  # concurrent cleanup that is about to delete the clone anyway, so it must log
  # at .info (not .error, which pages on-call) and still return clean.
  # See GitHub issue #4410.
  test "check_dirty_state logs .info and returns clean when clone vanishes mid-check (ENOENT)" do
    create_test_repo
    logger = RecordingLogger.new
    service = CloneArtifactService.new(logger: logger)

    result = service.stub(:run_git, ->(*) { raise Errno::ENOENT.new(@repo_path) }) do
      service.check_dirty_state(@repo_path)
    end

    assert_not result.dirty?
    assert_equal :info, logger.level_for("disappeared during dirty-state check")
    assert_nil logger.level_for("Failed to check dirty state"),
      "a vanished clone must not log at .error (it pages on-call)"
  end

  # A genuinely unexpected failure while the clone is STILL present must keep
  # logging at .error so real, persistent inspection failures still page.
  test "check_dirty_state still logs .error for an unexpected failure on a present clone" do
    create_test_repo
    logger = RecordingLogger.new
    service = CloneArtifactService.new(logger: logger)

    result = service.stub(:run_git, ->(*) { raise "unexpected boom" }) do
      service.check_dirty_state(@repo_path)
    end

    assert_not result.dirty?
    assert_equal :error, logger.level_for("Failed to check dirty state")
    assert_nil logger.level_for("disappeared during dirty-state check")
  end

  # === create_artifacts tests ===

  test "create_artifacts saves bundle for unpushed commits" do
    create_test_repo(unpushed_commits: true)

    result = @service.create_artifacts(session_id: @session_id, clone_path: @repo_path)

    assert result.success?
    assert File.directory?(result.artifacts_path)

    metadata = read_artifact_metadata(result.artifacts_path)
    assert metadata["has_bundle"]
    assert File.exist?(File.join(result.artifacts_path, "bundle.pack"))
  end

  test "create_artifacts saves working tree patch for uncommitted changes" do
    create_test_repo(dirty: true)

    result = @service.create_artifacts(session_id: @session_id, clone_path: @repo_path)

    assert result.success?

    metadata = read_artifact_metadata(result.artifacts_path)
    assert metadata["has_working_tree_patch"]
    assert File.exist?(File.join(result.artifacts_path, "working_tree.patch"))

    # Verify patch content is non-empty
    patch = File.read(File.join(result.artifacts_path, "working_tree.patch"))
    assert patch.present?
  end

  test "create_artifacts saves both bundle and patch when both exist" do
    create_test_repo(dirty: true, unpushed_commits: true)

    result = @service.create_artifacts(session_id: @session_id, clone_path: @repo_path)

    assert result.success?

    metadata = read_artifact_metadata(result.artifacts_path)
    assert metadata["has_bundle"]
    assert metadata["has_working_tree_patch"]
    assert metadata["branch"].present?
    assert metadata["head_sha"].present?
    assert metadata["upstream_ref"].present?
  end

  test "create_artifacts records metadata correctly" do
    create_test_repo(unpushed_commits: true)

    result = @service.create_artifacts(session_id: @session_id, clone_path: @repo_path)

    metadata = read_artifact_metadata(result.artifacts_path)
    assert_equal @session_id.to_s, metadata["session_id"]
    assert_equal "main", metadata["branch"]
    assert metadata["head_sha"].present?
    assert metadata["created_at"].present?
  end

  # Regression: a staged TEXT file containing non-UTF-8 bytes (e.g. content in a
  # non-UTF-8 locale — high bytes but no NUL, so git treats it as text and emits
  # the raw bytes in the diff) used to make `git diff` output raise
  # Encoding::CompatibilityError "invalid byte sequence in UTF-8" when String
  # ops ran on it, which surfaced as a .error log and a failed artifact save.
  # The diff must now be captured as raw bytes and round-trip through the patch.
  test "create_artifacts saves patch for non-UTF-8 text content without raising" do
    create_test_repo
    logger = RecordingLogger.new
    service = CloneArtifactService.new(logger: logger)

    # 0xE9 (Latin-1 'é') / 0xFF are invalid UTF-8 lead bytes; no NUL byte keeps
    # git's text heuristic, so these bytes land directly in the diff output.
    non_utf8_text = "caf\xE9 r\xE9sum\xE9 \xFF\xFE\n".b
    Dir.chdir(@repo_path) do
      File.binwrite("latin1_notes.txt", non_utf8_text)
    end

    result = service.create_artifacts(session_id: @session_id, clone_path: @repo_path)

    assert result.success?, "expected success, got error: #{result.error}"
    assert_nil logger.level_for("Failed to create artifacts"),
      "non-UTF-8 diff output must not raise and log at .error"

    metadata = read_artifact_metadata(result.artifacts_path)
    assert metadata["has_working_tree_patch"]
    patch_path = File.join(result.artifacts_path, "working_tree.patch")
    assert File.exist?(patch_path)
    # The raw invalid bytes must survive byte-for-byte in the saved patch.
    assert_includes File.binread(patch_path), "caf\xE9 r\xE9sum\xE9 \xFF\xFE".b
  end

  # The non-UTF-8 text patch must apply cleanly to a fresh clone, restoring the
  # exact original bytes (full create -> apply round-trip).
  test "apply_artifacts restores non-UTF-8 text content via patch" do
    create_test_repo
    non_utf8_text = "caf\xE9 r\xE9sum\xE9 \xFF\xFE\n".b
    Dir.chdir(@repo_path) do
      File.binwrite("latin1_notes.txt", non_utf8_text)
    end

    @service.create_artifacts(session_id: @session_id, clone_path: @repo_path)

    fresh_clone = create_fresh_clone
    result = @service.apply_artifacts(session_id: @session_id, clone_path: fresh_clone)

    assert result.success?
    assert result.applied_working_tree?
    restored = File.join(fresh_clone, "latin1_notes.txt")
    assert File.exist?(restored)
    assert_equal non_utf8_text, File.binread(restored)
  ensure
    FileUtils.rm_rf(fresh_clone) if fresh_clone && File.directory?(fresh_clone)
  end

  # A genuinely binary file (contains NUL bytes) must also round-trip: the
  # --binary diff produces a full binary patch that `git apply` can restore,
  # rather than the contentless "Binary files differ" line.
  test "apply_artifacts restores binary working tree file via --binary patch" do
    create_test_repo
    binary_blob = "PNG\x00\x01\x02\xFF\xFE\x89header\x00\x00trailer".b
    Dir.chdir(@repo_path) do
      File.binwrite("image.bin", binary_blob)
    end

    create_result = @service.create_artifacts(session_id: @session_id, clone_path: @repo_path)
    assert create_result.success?
    assert read_artifact_metadata(create_result.artifacts_path)["has_working_tree_patch"]

    fresh_clone = create_fresh_clone
    result = @service.apply_artifacts(session_id: @session_id, clone_path: fresh_clone)

    assert result.success?
    assert result.applied_working_tree?
    restored = File.join(fresh_clone, "image.bin")
    assert File.exist?(restored)
    assert_equal binary_blob, File.binread(restored)
  ensure
    FileUtils.rm_rf(fresh_clone) if fresh_clone && File.directory?(fresh_clone)
  end

  test "create_artifacts for clean repo produces no bundle or patch" do
    create_test_repo

    result = @service.create_artifacts(session_id: @session_id, clone_path: @repo_path)

    assert result.success?

    metadata = read_artifact_metadata(result.artifacts_path)
    assert_not metadata["has_bundle"]
    assert_not metadata["has_working_tree_patch"]
  end

  # === apply_artifacts tests ===

  test "apply_artifacts restores unpushed commits via bundle" do
    create_test_repo(unpushed_commits: true)

    # Capture the unpushed commit message for verification
    unpushed_log, _ = Open3.capture2("git", "log", "--oneline", "-1", chdir: @repo_path)
    unpushed_log.strip!

    # Create artifacts
    @service.create_artifacts(session_id: @session_id, clone_path: @repo_path)

    # Create a fresh clone (simulating re-clone on unarchive)
    fresh_clone = create_fresh_clone

    # Apply artifacts
    result = @service.apply_artifacts(session_id: @session_id, clone_path: fresh_clone)

    assert result.success?
    assert result.applied_bundle?

    # Verify the unpushed commit is now in the fresh clone
    fresh_log, _ = Open3.capture2("git", "log", "--oneline", "-1", chdir: fresh_clone)
    fresh_log.strip!
    assert_equal unpushed_log, fresh_log
  ensure
    FileUtils.rm_rf(fresh_clone) if fresh_clone && File.directory?(fresh_clone)
  end

  test "apply_artifacts restores working tree changes via patch" do
    create_test_repo(dirty: true)

    # Create artifacts
    @service.create_artifacts(session_id: @session_id, clone_path: @repo_path)

    # Create a fresh clone
    fresh_clone = create_fresh_clone

    # Apply artifacts
    result = @service.apply_artifacts(session_id: @session_id, clone_path: fresh_clone)

    assert result.success?
    assert result.applied_working_tree?

    # Verify dirty file exists in fresh clone
    assert File.exist?(File.join(fresh_clone, "dirty_file.rb"))
    assert_equal "# dirty content\n", File.read(File.join(fresh_clone, "dirty_file.rb"))
  ensure
    FileUtils.rm_rf(fresh_clone) if fresh_clone && File.directory?(fresh_clone)
  end

  test "apply_artifacts returns success with no-ops when no artifacts exist" do
    result = @service.apply_artifacts(session_id: @session_id, clone_path: "/tmp/whatever")

    assert result.success?
    assert_not result.applied_bundle?
    assert_not result.applied_working_tree?
  end

  # === cleanup_artifacts tests ===

  test "cleanup_artifacts removes artifacts directory" do
    create_test_repo(dirty: true)
    @service.create_artifacts(session_id: @session_id, clone_path: @repo_path)

    assert @service.artifacts_exist?(@session_id)

    result = @service.cleanup_artifacts(@session_id)

    assert result
    assert_not @service.artifacts_exist?(@session_id)
  end

  test "cleanup_artifacts returns false when no artifacts exist" do
    result = @service.cleanup_artifacts(@session_id)

    assert_not result
  end

  # === artifacts_exist? tests ===

  test "artifacts_exist? returns true when artifacts directory exists" do
    create_test_repo(dirty: true)
    @service.create_artifacts(session_id: @session_id, clone_path: @repo_path)

    assert @service.artifacts_exist?(@session_id)
  end

  test "artifacts_exist? returns false when no artifacts" do
    assert_not @service.artifacts_exist?(@session_id)
  end

  # === artifacts_path_for tests ===

  test "artifacts_path_for returns path under home directory" do
    path = @service.artifacts_path_for(42)

    assert_includes path, ".agent-orchestrator/artifacts/42"
  end

  private

  def create_test_repo(dirty: false, unpushed_commits: false)
    @bare_path = "/tmp/test-artifact-bare-#{SecureRandom.hex(4)}"
    @repo_path = "/tmp/test-artifact-repo-#{SecureRandom.hex(4)}"

    # Create bare "remote" repo and set HEAD to main
    run_cmd("git", "init", "--bare", @bare_path)
    File.write(File.join(@bare_path, "HEAD"), "ref: refs/heads/main\n")

    # Clone it
    run_cmd("git", "clone", @bare_path, @repo_path)

    # Create initial commit and push
    Dir.chdir(@repo_path) do
      run_cmd("git", "config", "user.email", "test@example.com")
      run_cmd("git", "config", "user.name", "Test User")
      run_cmd("git", "checkout", "-b", "main")
      File.write("README.md", "initial content\n")
      run_cmd("git", "add", ".")
      run_cmd("git", "commit", "-m", "initial commit")
      run_cmd("git", "push", "-u", "origin", "main")
    end

    if unpushed_commits
      Dir.chdir(@repo_path) do
        File.write("new_file.rb", "# new content\n")
        run_cmd("git", "add", ".")
        run_cmd("git", "commit", "-m", "unpushed commit")
      end
    end

    if dirty
      Dir.chdir(@repo_path) do
        File.write("dirty_file.rb", "# dirty content\n")
      end
    end
  end

  def create_fresh_clone
    fresh_path = "/tmp/test-artifact-fresh-#{SecureRandom.hex(4)}"
    run_cmd("git", "clone", @bare_path, fresh_path)
    Dir.chdir(fresh_path) do
      run_cmd("git", "config", "user.email", "test@example.com")
      run_cmd("git", "config", "user.name", "Test User")
      run_cmd("git", "checkout", "main")
    end
    fresh_path
  end

  def run_cmd(*args)
    system(*args, out: File::NULL, err: File::NULL, exception: true)
  end

  def read_artifact_metadata(artifacts_path)
    JSON.parse(File.read(File.join(artifacts_path, "metadata.json")))
  end
end
