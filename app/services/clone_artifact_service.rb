# frozen_string_literal: true

require "open3"

# Service for preserving and restoring unpushed git artifacts from session clones.
#
# When a session is archived, instead of keeping the full clone on disk, this service:
# 1. Checks if the clone has any unpushed state (uncommitted changes or unpushed commits)
# 2. If clean: returns immediately (caller should delete the clone)
# 3. If dirty: extracts lightweight artifacts (git bundle + diff patch), stores them on disk
#
# On unarchive, artifacts can be applied to a fresh clone to restore the unpushed state.
#
# Artifact storage layout:
#   ~/.agent-orchestrator/artifacts/{session_id}/
#     bundle.pack         — git bundle of unpushed commits (if any)
#     working_tree.patch  — diff of all uncommitted changes vs HEAD (if any)
#     metadata.json       — artifact metadata (branch, commit SHA, upstream ref, created_at)
#
class CloneArtifactService
  ARTIFACTS_BASE_DIR = ".agent-orchestrator/artifacts"

  class ArtifactError < StandardError; end

  DirtyCheckResult = Struct.new(:dirty?, :has_uncommitted?, :has_unpushed_commits?, :details, keyword_init: true)
  CreateResult = Struct.new(:success?, :artifacts_path, :error, keyword_init: true)
  ApplyResult = Struct.new(:success?, :applied_bundle?, :applied_working_tree?, :error, keyword_init: true)

  attr_reader :file_system, :logger

  def initialize(file_system: nil, logger: nil)
    @file_system = file_system || RealFileSystemAdapter.new
    @logger = logger || StructuredLogger.new({ service: "CloneArtifactService" })
  end

  # Check if a clone has any unpushed state (uncommitted changes or unpushed commits).
  # On error, returns clean to never block cleanup.
  def check_dirty_state(clone_path)
    unless clone_path && file_system.directory?(clone_path)
      return DirtyCheckResult.new(dirty?: false, has_uncommitted?: false,
        has_unpushed_commits?: false, details: "Clone path does not exist")
    end

    has_uncommitted = false
    has_unpushed = false
    details = []

    # Check for uncommitted changes (working tree + staged)
    stdout, _stderr, status = run_git("status", "--porcelain", cwd: clone_path)
    if status.success? && stdout.strip.present?
      has_uncommitted = true
      details << "uncommitted changes (#{stdout.lines.count} files)"
    end

    # Check for unpushed commits
    upstream_ref = detect_upstream_ref(clone_path)
    if upstream_ref
      commit_stdout, _stderr, commit_status = run_git(
        "log", "#{upstream_ref}..HEAD", "--format=%H %s", cwd: clone_path
      )
      if commit_status.success? && commit_stdout.strip.present?
        has_unpushed = true
        details << "#{commit_stdout.strip.lines.count} unpushed commit(s)"
      end
    else
      details << "no upstream reference found, treating as clean for commits"
    end

    DirtyCheckResult.new(
      dirty?: has_uncommitted || has_unpushed,
      has_uncommitted?: has_uncommitted,
      has_unpushed_commits?: has_unpushed,
      details: details.join("; ")
    )
  rescue => e
    # A clone that vanishes between the early-return guard above and the git
    # invocation below is a benign, expected race: the only caller
    # (DeferredCloneCleanupJob) is about to delete the clone anyway, and the
    # correct answer for a missing clone is "clean" (there is nothing to check
    # and nothing to retry). Log that at .info so it does not page on-call.
    # Anything else — a genuine, unexpected failure to inspect a clone that is
    # still present — keeps .error so it stays alert-worthy.
    if e.is_a?(Errno::ENOENT) || !file_system.directory?(clone_path)
      @logger.info("Clone path disappeared during dirty-state check, treating as clean",
        clone_path: clone_path, error: e.message)
    else
      @logger.error("Failed to check dirty state", error: e.message, clone_path: clone_path)
    end
    DirtyCheckResult.new(dirty?: false, has_uncommitted?: false,
      has_unpushed_commits?: false, details: "Error checking dirty state: #{e.message}")
  end

  # Extract artifacts from a dirty clone and save to disk.
  def create_artifacts(session_id:, clone_path:)
    artifacts_dir = artifacts_path_for(session_id)
    file_system.mkdir_p(artifacts_dir)

    metadata = {
      "created_at" => Time.current.iso8601,
      "clone_path" => clone_path,
      "session_id" => session_id.to_s
    }

    # Capture current branch name
    branch_stdout, _, branch_status = run_git("rev-parse", "--abbrev-ref", "HEAD", cwd: clone_path)
    metadata["branch"] = branch_stdout.strip if branch_status.success?

    # Capture current commit SHA
    sha_stdout, _, sha_status = run_git("rev-parse", "HEAD", cwd: clone_path)
    metadata["head_sha"] = sha_stdout.strip if sha_status.success?

    # Determine upstream reference
    upstream_ref = detect_upstream_ref(clone_path)
    metadata["upstream_ref"] = upstream_ref

    # Create git bundle for unpushed commits
    if upstream_ref
      bundle_path = File.join(artifacts_dir, "bundle.pack")
      _, _, bundle_status = run_git(
        "bundle", "create", bundle_path, "#{upstream_ref}..HEAD",
        cwd: clone_path
      )
      metadata["has_bundle"] = bundle_status.success? && file_system.exists?(bundle_path)
      @logger.info("Git bundle creation", success: metadata["has_bundle"], path: bundle_path) if metadata["has_bundle"]
    else
      metadata["has_bundle"] = false
    end

    # Capture all uncommitted changes (staged + unstaged + untracked) as a single patch.
    # Stage everything first so untracked files are included in the diff.
    # The clone is about to be deleted so modifying its index is fine.
    run_git("add", "-A", cwd: clone_path)
    # Capture the diff as raw bytes (binmode) so content with non-UTF-8 bytes
    # (e.g. a text file in a non-UTF-8 locale) does not raise
    # Encoding::CompatibilityError when String ops touch it. The ASCII-8BIT
    # result is safe for strip/empty? (no encoding validation on binary strings).
    # --binary emits a full binary patch for binary files so they round-trip
    # through `git apply`; without it git only writes "Binary files differ" and
    # the file's contents would be silently lost on restore.
    diff_stdout, _, diff_status = run_git("diff", "--binary", "--cached", "HEAD", cwd: clone_path, binmode: true)
    if diff_status.success? && !diff_stdout.strip.empty?
      patch_path = File.join(artifacts_dir, "working_tree.patch")
      file_system.binwrite(patch_path, diff_stdout)
      metadata["has_working_tree_patch"] = true
      @logger.info("Saved working tree patch", path: patch_path, size: diff_stdout.bytesize)
    else
      metadata["has_working_tree_patch"] = false
    end

    # Write metadata
    metadata_path = File.join(artifacts_dir, "metadata.json")
    file_system.write(metadata_path, JSON.pretty_generate(metadata))

    CreateResult.new(success?: true, artifacts_path: artifacts_dir)
  rescue => e
    @logger.error("Failed to create artifacts", error: e.message, session_id: session_id)
    file_system.rm_rf(artifacts_dir) if file_system.directory?(artifacts_dir)
    CreateResult.new(success?: false, error: e.message)
  end

  # Apply saved artifacts to a freshly cloned repository.
  def apply_artifacts(session_id:, clone_path:)
    artifacts_dir = artifacts_path_for(session_id)

    unless file_system.directory?(artifacts_dir)
      return ApplyResult.new(success?: true, applied_bundle?: false, applied_working_tree?: false)
    end

    metadata = read_metadata(artifacts_dir)
    applied_bundle = false
    applied_working_tree = false

    # Apply git bundle (unpushed commits)
    bundle_path = File.join(artifacts_dir, "bundle.pack")
    if metadata["has_bundle"] && file_system.exists?(bundle_path)
      applied_bundle = apply_bundle(bundle_path, clone_path)
    end

    # Apply working tree patch (uncommitted changes)
    patch_path = File.join(artifacts_dir, "working_tree.patch")
    if metadata["has_working_tree_patch"] && file_system.exists?(patch_path)
      applied_working_tree = apply_patch(patch_path, clone_path)
    end

    ApplyResult.new(success?: true, applied_bundle?: applied_bundle, applied_working_tree?: applied_working_tree)
  rescue => e
    @logger.error("Failed to apply artifacts", error: e.message, session_id: session_id)
    ApplyResult.new(success?: false, error: e.message)
  end

  # Check if artifacts exist for a given session.
  def artifacts_exist?(session_id)
    file_system.directory?(artifacts_path_for(session_id))
  end

  # Delete artifacts for a given session.
  def cleanup_artifacts(session_id)
    artifacts_dir = artifacts_path_for(session_id)
    if file_system.directory?(artifacts_dir)
      file_system.rm_rf(artifacts_dir)
      @logger.info("Cleaned up artifacts", session_id: session_id, path: artifacts_dir)
      true
    else
      false
    end
  end

  # Get the artifacts directory path for a session.
  def artifacts_path_for(session_id)
    home_dir = File.expand_path("~")
    File.join(home_dir, ARTIFACTS_BASE_DIR, session_id.to_s)
  end

  private

  # Detect the upstream reference for comparing commits.
  # Falls back through: @{upstream} -> origin/HEAD -> origin/main -> origin/master
  def detect_upstream_ref(clone_path)
    # Try @{upstream}
    stdout, _, status = run_git("rev-parse", "--abbrev-ref", "@{upstream}", cwd: clone_path)
    return stdout.strip if status.success? && stdout.strip.present?

    # Fallback to origin/HEAD
    _, _, status = run_git("rev-parse", "--verify", "origin/HEAD", cwd: clone_path)
    return "origin/HEAD" if status.success?

    # Fallback to origin/main
    _, _, status = run_git("rev-parse", "--verify", "origin/main", cwd: clone_path)
    return "origin/main" if status.success?

    # Fallback to origin/master
    _, _, status = run_git("rev-parse", "--verify", "origin/master", cwd: clone_path)
    return "origin/master" if status.success?

    nil
  end

  def read_metadata(artifacts_dir)
    metadata_path = File.join(artifacts_dir, "metadata.json")
    if file_system.exists?(metadata_path)
      JSON.parse(file_system.read(metadata_path))
    else
      {}
    end
  rescue JSON::ParserError => e
    @logger.warn("Failed to parse artifacts metadata", error: e.message)
    {}
  end

  def apply_bundle(bundle_path, clone_path)
    # Verify bundle is valid
    _, _, verify_status = run_git("bundle", "verify", bundle_path, cwd: clone_path)
    unless verify_status.success?
      @logger.warn("Bundle verification failed, skipping")
      return false
    end

    # Fetch commits from bundle
    _, _, fetch_status = run_git("fetch", bundle_path, cwd: clone_path)
    unless fetch_status.success?
      @logger.warn("Bundle fetch failed")
      return false
    end

    # Fast-forward merge to apply the commits
    _, _, merge_status = run_git("merge", "--ff-only", "FETCH_HEAD", cwd: clone_path)
    if merge_status.success?
      @logger.info("Applied git bundle via fast-forward merge")
      true
    else
      @logger.warn("Fast-forward merge failed, remote may have diverged")
      false
    end
  end

  def apply_patch(patch_path, clone_path)
    # Try normal apply first
    _, _, apply_status = run_git("apply", "--whitespace=nowarn", patch_path, cwd: clone_path)
    if apply_status.success?
      @logger.info("Applied working tree patch")
      return true
    end

    # Fall back to 3-way merge
    _, _, apply3_status = run_git("apply", "--3way", "--whitespace=nowarn", patch_path, cwd: clone_path)
    if apply3_status.success?
      @logger.info("Applied working tree patch with 3-way merge")
      return true
    end

    @logger.warn("Working tree patch apply failed")
    false
  end

  # Run a git command safely using Open3 array syntax (prevents shell injection).
  #
  # Git output is raw bytes: branch names, diffs, and status can contain
  # non-UTF-8 sequences (e.g. a staged binary file or a file name in a
  # non-UTF-8 locale). Open3.capture3 tags stdout/stderr with the default
  # external encoding (UTF-8), so calling String methods that validate
  # encoding (strip, =~, present?) on that output raises
  # Encoding::CompatibilityError "invalid byte sequence in UTF-8".
  #
  # binmode: false (default) — scrub stdout/stderr to valid UTF-8 (invalid
  #   bytes become U+FFFD). Safe for text output that flows into String ops,
  #   metadata, and JSON.pretty_generate.
  # binmode: true — capture raw bytes (ASCII-8BIT) untouched. Use when the
  #   output must round-trip byte-for-byte, e.g. a diff written as a patch.
  def run_git(*args, cwd:, binmode: false)
    command = [ "git" ] + args.map(&:to_s)
    @logger.debug("Running git command", command: command.join(" "), cwd: cwd)
    stdout, stderr, status = Open3.capture3(*command, chdir: cwd, binmode: true)
    unless binmode
      stdout = stdout.dup.force_encoding(Encoding::UTF_8).scrub
      stderr = stderr.dup.force_encoding(Encoding::UTF_8).scrub
    end
    [ stdout, stderr, status ]
  end
end
