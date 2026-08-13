# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"

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

  # A service whose clone is destroyed out from under it the moment the first
  # `git diff` returns — the #412 recursive delete landing in the middle of
  # create_artifacts. Records every git command attempted after that point, so a
  # test can assert the service never chdirs into the doomed directory again.
  class VanishingCloneService < CloneArtifactService
    attr_reader :git_commands_after_vanish

    def initialize(clone_path:, **kwargs)
      super(**kwargs)
      @clone_path = clone_path
      @vanished = false
      @git_commands_after_vanish = []
    end

    private

    def run_git(*args, **kwargs)
      @git_commands_after_vanish << args.join(" ") if @vanished
      result = super
      if !@vanished && args.first.to_s == "diff"
        FileUtils.rm_rf(@clone_path)
        @vanished = true
      end
      result
    end
  end

  # The sandbox owns the isolation, so the id carries none of it and is fixed:
  # nothing in this file depends on chance.
  SESSION_ID = 900_001

  # Every test runs under a private $HOME, so the artifacts root
  # CloneArtifactService derives from it (~/.zimmer/artifacts/<session_id>)
  # belongs to that test alone.
  #
  # Without the sandbox that root is a machine-global namespace: all 8 parallel
  # workers of a run share it, and so does every other test-unit job running
  # concurrently on the persistent self-hosted runner. Keying the directory off a
  # random session id only narrows the odds rather than closing them — two tests
  # holding the same id share a directory, and one test's teardown rm_rf can land
  # inside the other's create_artifacts, which then dies on Errno::ENOENT and
  # returns success? == false. A private $HOME deletes the shared namespace
  # instead of betting against it, and keeps the suite out of the runner's real
  # home, where a killed run leaves artifact directories behind for good.
  #
  # Weigh this before widening what runs under the sandbox: constants that bake
  # Dir.home at class-load time (ClaudeAuthProvider::CLAUDE_JSON_PATH,
  # QuotaCheckService::CREDENTIALS_PATH) would freeze a tmpdir path for the rest
  # of the worker process if they were first autoloaded here. Nothing this file
  # touches reaches them, and CI eager-loads the whole graph at boot.
  setup do
    @original_home = ENV["HOME"]
    @home_dir = Dir.mktmpdir("clone-artifact-home")
    ENV["HOME"] = @home_dir

    @service = CloneArtifactService.new
    @session_id = SESSION_ID
    @bare_path = nil
    @repo_path = nil
  end

  teardown do
    # Restore $HOME first. Minitest skips the rest of a teardown block that
    # raises, and a cleanup failure below must not leave the worker pointed at a
    # tmpdir for every test file it runs afterwards.
    @original_home.nil? ? ENV.delete("HOME") : ENV["HOME"] = @original_home
    FileUtils.rm_rf(@home_dir) if @home_dir
    FileUtils.rm_rf(@repo_path) if @repo_path && File.directory?(@repo_path)
    FileUtils.rm_rf(@bare_path) if @bare_path && File.directory?(@bare_path)
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
  # See GitHub issue pulsemcp/pulsemcp#4410.
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

    assert result.success?, result.error
    assert File.directory?(result.artifacts_path)

    metadata = read_artifact_metadata(result.artifacts_path)
    assert metadata["has_bundle"]
    assert File.exist?(File.join(result.artifacts_path, "bundle.pack"))
  end

  test "create_artifacts saves working tree patch for uncommitted changes" do
    create_test_repo(dirty: true)

    result = @service.create_artifacts(session_id: @session_id, clone_path: @repo_path)

    assert result.success?, result.error

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

    assert result.success?, result.error

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

    assert result.success?, result.error
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
    assert create_result.success?, create_result.error
    assert read_artifact_metadata(create_result.artifacts_path)["has_working_tree_patch"]

    fresh_clone = create_fresh_clone
    result = @service.apply_artifacts(session_id: @session_id, clone_path: fresh_clone)

    assert result.success?, result.error
    assert result.applied_working_tree?
    restored = File.join(fresh_clone, "image.bin")
    assert File.exist?(restored)
    assert_equal binary_blob, File.binread(restored)
  ensure
    FileUtils.rm_rf(fresh_clone) if fresh_clone && File.directory?(fresh_clone)
  end

  # === mass-deletion guard tests (issue #411) ===
  #
  # An interrupted `rm -rf` on a live clone leaves a tree that is nothing but
  # deletions of tracked files. Preserving that as "uncommitted work" makes a
  # transient filesystem accident permanent: unarchive replays it onto a
  # pristine clone, deletes the agent root's subdirectory, and `air prepare`
  # fails the session with ENOENT.

  test "create_artifacts does not preserve a working tree that is only deletions of tracked files" do
    create_test_repo(tracked_files: 60)
    logger = RecordingLogger.new
    service = CloneArtifactService.new(logger: logger)

    delete_tracked_files(@repo_path, 60)

    result = service.create_artifacts(session_id: @session_id, clone_path: @repo_path)

    assert result.success?, result.error
    metadata = read_artifact_metadata(result.artifacts_path)
    assert_not metadata["has_working_tree_patch"],
      "a tree of nothing but deletions is corruption, not work"
    assert_not File.exist?(File.join(result.artifacts_path, "working_tree.patch"))
    assert_equal 60, metadata["dropped_deletions"]
    assert_equal 60, result.dropped_deletions,
      "the caller needs the count to record it on the session (#415)"
    assert_equal :warn, logger.level_for("Refusing to preserve mass deletions"),
      "this path is self-healing, so it must not page per defused clone (#415)"
  end

  # The additions and modifications in a mangled tree are still the session's
  # work, so they are preserved; only the deletions are dropped.
  test "create_artifacts preserves additions and modifications from a mass-deletion tree" do
    create_test_repo(tracked_files: 60)
    delete_tracked_files(@repo_path, 60)
    Dir.chdir(@repo_path) do
      File.write("agent_work.rb", "# real work\n")
      File.write("README.md", "edited by the agent\n")
    end

    result = @service.create_artifacts(session_id: @session_id, clone_path: @repo_path)

    assert result.success?, result.error
    metadata = read_artifact_metadata(result.artifacts_path)
    assert metadata["has_working_tree_patch"]
    patch = File.binread(File.join(result.artifacts_path, "working_tree.patch"))
    assert_includes patch, "agent_work.rb"
    assert_includes patch, "edited by the agent"
    assert_not_includes patch, "deleted file mode",
      "the deletions must not survive into the preserved patch"

    # And it restores as work: the deleted files come back from HEAD, the
    # agent's additions and edits come back from the patch.
    fresh_clone = create_fresh_clone
    apply_result = @service.apply_artifacts(session_id: @session_id, clone_path: fresh_clone)

    assert apply_result.applied_working_tree?, apply_result.error
    assert File.exist?(File.join(fresh_clone, "tracked_00.rb")), "tracked files must survive the restore"
    assert File.exist?(File.join(fresh_clone, "agent_work.rb"))
    assert_equal "edited by the agent\n", File.read(File.join(fresh_clone, "README.md"))
  ensure
    FileUtils.rm_rf(fresh_clone) if fresh_clone && File.directory?(fresh_clone)
  end

  # Regression for #425: the guard fires precisely when a concurrent recursive
  # delete is gutting the clone, and it used to re-run `git diff` in that same
  # directory to strip the deletions. When the delete won the race the second
  # chdir raised Errno::ENOENT and took the whole preservation down with it —
  # 11 ms after the guard's warning, in production. The deletions are now
  # filtered out of the diff already in memory, so nothing re-enters the clone.
  test "create_artifacts preserves work when the clone is deleted right after the diff" do
    create_test_repo(tracked_files: 60)
    delete_tracked_files(@repo_path, 60)
    Dir.chdir(@repo_path) do
      File.write("agent_work.rb", "# real work\n")
    end
    logger = RecordingLogger.new
    service = VanishingCloneService.new(clone_path: @repo_path, logger: logger)

    result = service.create_artifacts(session_id: @session_id, clone_path: @repo_path)

    assert result.success?, "a clone vanishing mid-flight must not fail preservation: #{result.error}"
    assert_nil logger.level_for("Failed to create artifacts")
    assert_equal :warn, logger.level_for("Refusing to preserve mass deletions")
    assert_empty service.git_commands_after_vanish,
      "nothing may chdir back into a clone the guard just proved is being deleted"

    metadata = read_artifact_metadata(result.artifacts_path)
    assert_equal 60, metadata["dropped_deletions"]
    assert result.dropped_deletions, "the defusal must still be countable on the session (#415)"
    assert metadata["has_working_tree_patch"], "the session's real work must survive the race"
    patch = File.binread(File.join(result.artifacts_path, "working_tree.patch"))
    assert_includes patch, "agent_work.rb"
    assert_not_includes patch, "deleted file mode"
  end

  # The in-memory filter re-emits the entries it keeps byte-for-byte, so a
  # --binary payload belonging to a kept file survives the guard and still
  # applies to a fresh clone. (Filtering a --binary patch is why this could not
  # be a naive line-wise grep.)
  test "create_artifacts keeps binary content intact when filtering a mass-deletion tree" do
    create_test_repo(tracked_files: 60)
    delete_tracked_files(@repo_path, 60)
    binary_blob = "PNG\x00\x01\x02\xFF\xFE\x89header\x00\x00trailer".b
    Dir.chdir(@repo_path) do
      File.binwrite("image.bin", binary_blob)
    end

    result = @service.create_artifacts(session_id: @session_id, clone_path: @repo_path)

    assert result.success?, result.error
    assert_equal 60, result.dropped_deletions
    assert read_artifact_metadata(result.artifacts_path)["has_working_tree_patch"]

    fresh_clone = create_fresh_clone
    apply_result = @service.apply_artifacts(session_id: @session_id, clone_path: fresh_clone)

    assert apply_result.applied_working_tree?, apply_result.error
    assert_equal binary_blob, File.binread(File.join(fresh_clone, "image.bin"))
    assert File.exist?(File.join(fresh_clone, "tracked_00.rb")), "the dropped deletions must not replay"
  ensure
    FileUtils.rm_rf(fresh_clone) if fresh_clone && File.directory?(fresh_clone)
  end

  # The threshold is deliberately conservative: a refactor that deletes files
  # alongside real edits is ordinary work and must round-trip untouched.
  test "create_artifacts preserves a legitimate refactor that deletes files alongside edits" do
    create_test_repo(tracked_files: 60)
    Dir.chdir(@repo_path) do
      10.times { |i| FileUtils.rm_f(format("tracked_%02d.rb", i)) }
      10.times { |i| File.write(format("renamed_%02d.rb", i), "# moved\n") }
    end

    result = @service.create_artifacts(session_id: @session_id, clone_path: @repo_path)

    assert result.success?, result.error
    metadata = read_artifact_metadata(result.artifacts_path)
    assert metadata["has_working_tree_patch"], "an ordinary refactor must still be preserved"
    assert_nil metadata["dropped_deletions"]
    assert_nil result.dropped_deletions, "a clone the guard never touched must not be counted as mangled"
    assert_includes File.binread(File.join(result.artifacts_path, "working_tree.patch")), "deleted file mode"
  end

  # Patches captured before the archive-side guard existed are already on disk
  # (110 of them in production when #411 was filed). The apply path has to
  # refuse them too, or every unarchive of an affected session keeps failing.
  test "apply_artifacts refuses a pre-existing mass-deletion patch instead of gutting the fresh clone" do
    create_test_repo(tracked_files: 60)
    logger = RecordingLogger.new
    service = CloneArtifactService.new(logger: logger)

    artifacts_dir = write_legacy_mass_deletion_artifacts(deleted_count: 60)

    fresh_clone = create_fresh_clone
    result = service.apply_artifacts(session_id: @session_id, clone_path: fresh_clone)

    assert result.success?, result.error
    assert_not result.applied_working_tree?
    assert result.refused_working_tree?
    assert_equal :error, logger.level_for("Refusing to apply a mass-deletion working tree patch"),
      "unlike the archive side, a refused patch here can leave a session broken — it must stay pageable"
    assert File.exist?(File.join(fresh_clone, "tracked_00.rb")), "the fresh clone must be left intact"
    assert File.exist?(File.join(artifacts_dir, "working_tree.patch")),
      "the refused patch stays on disk for manual salvage"
  ensure
    FileUtils.rm_rf(fresh_clone) if fresh_clone && File.directory?(fresh_clone)
  end

  test "restore_working_tree_to returns the clone to exactly what the given ref describes" do
    create_test_repo(tracked_files: 5)
    pristine = @service.head_sha(@repo_path)
    assert pristine.present?

    Dir.chdir(@repo_path) do
      FileUtils.rm_f("tracked_00.rb")
      File.write("README.md", "clobbered\n")
      File.write("untracked.rb", "# left over\n")
    end

    assert @service.restore_working_tree_to(@repo_path, pristine)

    assert File.exist?(File.join(@repo_path, "tracked_00.rb"))
    assert_equal "initial content\n", File.read(File.join(@repo_path, "README.md"))
    assert_not File.exist?(File.join(@repo_path, "untracked.rb"))
    assert_equal({ deleted: 0, changed: 0 }, @service.working_tree_change_counts(@repo_path))
  end

  # The ref matters: a restore can move HEAD (an applied bundle fast-forwards
  # it), so reverting to "HEAD" would keep whatever damage those commits did.
  # Reverting to the commit the clone was checked out at before the restore
  # unwinds them.
  test "restore_working_tree_to unwinds commits the restore added" do
    create_test_repo(tracked_files: 5)
    pristine = @service.head_sha(@repo_path)
    Dir.chdir(@repo_path) do
      FileUtils.rm_f("tracked_00.rb")
      run_cmd("git", "add", "-A")
      run_cmd("git", "commit", "-m", "commit the wreckage")
    end
    assert_not File.exist?(File.join(@repo_path, "tracked_00.rb"))

    assert @service.restore_working_tree_to(@repo_path, pristine)

    assert File.exist?(File.join(@repo_path, "tracked_00.rb"))
    assert_equal pristine, @service.head_sha(@repo_path)
  end

  # `git apply --3way` leaves unmerged entries behind when a legitimate patch
  # conflicts. Those are changes, not deletions — counting DU/UD/DD as deletions
  # would let a failed 3-way look like a gutted tree and get reset away.
  test "working_tree_change_counts does not count unmerged entries as deletions" do
    create_test_repo(tracked_files: 5)
    status_lines = "DU tracked_00.rb\nUD tracked_01.rb\nUU tracked_02.rb\n D tracked_03.rb\n"
    _, _, ok_status = Open3.capture3("true")
    counts = @service.stub(:run_git, ->(*) { [ status_lines, "", ok_status ] }) do
      @service.working_tree_change_counts(@repo_path)
    end

    assert_equal 1, counts[:deleted], "only the plain ' D' row is a deletion"
    assert_equal 4, counts[:changed]
  end

  test "working_tree_change_counts counts deletions of tracked files" do
    create_test_repo(tracked_files: 5)
    delete_tracked_files(@repo_path, 3)
    Dir.chdir(@repo_path) { File.write("brand_new.rb", "# new\n") }

    counts = @service.working_tree_change_counts(@repo_path)

    assert_equal 3, counts[:deleted]
    assert_equal 4, counts[:changed]
  end

  test "mass_deletion? needs both a floor of deleted files and deletions dominating the patch" do
    assert CloneArtifactService.mass_deletion?(deleted: 551, changed: 551)
    assert CloneArtifactService.mass_deletion?(deleted: 50, changed: 50)
    assert_not CloneArtifactService.mass_deletion?(deleted: 49, changed: 49),
      "below the floor, too few files to call it corruption"
    assert_not CloneArtifactService.mass_deletion?(deleted: 60, changed: 100),
      "deletions mixed with substantial other work is a refactor"
    assert_not CloneArtifactService.mass_deletion?(deleted: 0, changed: 0)
  end

  test "create_artifacts for clean repo produces no bundle or patch" do
    create_test_repo

    result = @service.create_artifacts(session_id: @session_id, clone_path: @repo_path)

    assert result.success?, result.error

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

    assert result.success?, result.error
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

    assert result.success?, result.error
    assert result.applied_working_tree?

    # Verify dirty file exists in fresh clone
    assert File.exist?(File.join(fresh_clone, "dirty_file.rb"))
    assert_equal "# dirty content\n", File.read(File.join(fresh_clone, "dirty_file.rb"))
  ensure
    FileUtils.rm_rf(fresh_clone) if fresh_clone && File.directory?(fresh_clone)
  end

  test "apply_artifacts returns success with no-ops when no artifacts exist" do
    result = @service.apply_artifacts(session_id: @session_id, clone_path: "/tmp/whatever")

    assert result.success?, result.error
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

    assert_includes path, ".zimmer/artifacts/42"
  end

  # Guards the sandbox described in setup. Everything this file writes must land
  # under the per-test $HOME; the moment an artifact escapes into the real
  # ~/.zimmer/artifacts, parallel workers and co-running CI jobs share a
  # directory again and the rm_rf race is back.
  test "artifacts are written under the per-test HOME sandbox, not the real home" do
    create_test_repo(dirty: true)

    result = @service.create_artifacts(session_id: @session_id, clone_path: @repo_path)

    assert result.success?, result.error
    assert result.artifacts_path.start_with?(@home_dir),
      "expected artifacts under the sandboxed HOME #{@home_dir}, got #{result.artifacts_path}"
  end

  private

  # Delete tracked files the way an interrupted `rm -rf` does: straight off the
  # filesystem, leaving git to notice them missing.
  def delete_tracked_files(repo_path, count)
    Dir.chdir(repo_path) do
      count.times { |i| FileUtils.rm_f(format("tracked_%02d.rb", i)) }
    end
  end

  # Write the artifacts a pre-guard archive would have left on disk: a patch
  # that is nothing but deletions of tracked files, plus the metadata that makes
  # apply_artifacts pick it up.
  def write_legacy_mass_deletion_artifacts(deleted_count:)
    delete_tracked_files(@repo_path, deleted_count)
    run_cmd("git", "-C", @repo_path, "add", "-A")
    patch, _ = Open3.capture2("git", "diff", "--binary", "--cached", "HEAD", chdir: @repo_path)

    artifacts_dir = @service.artifacts_path_for(@session_id)
    FileUtils.mkdir_p(artifacts_dir)
    File.binwrite(File.join(artifacts_dir, "working_tree.patch"), patch)
    File.write(File.join(artifacts_dir, "metadata.json"),
      JSON.generate("has_bundle" => false, "has_working_tree_patch" => true))
    artifacts_dir
  end

  def create_test_repo(dirty: false, unpushed_commits: false, tracked_files: 0)
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
      tracked_files.times { |i| File.write(format("tracked_%02d.rb", i), "# tracked #{i}\n") }
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
