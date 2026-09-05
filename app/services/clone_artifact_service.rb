# frozen_string_literal: true

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
#   ~/.zimmer/artifacts/{session_id}/
#     bundle.pack         — git bundle of unpushed commits (if any)
#     working_tree.patch  — diff of all uncommitted changes vs HEAD (if any)
#     metadata.json       — artifact metadata (branch, commit SHA, upstream ref, created_at)
#
class CloneArtifactService
  ARTIFACTS_BASE_DIR = ".zimmer/artifacts"

  # Raised when a git subprocess exceeds GIT_TIMEOUT_SECONDS and BoundedSubprocess
  # kills its process group.
  class GitTimeoutError < StandardError; end

  # Wall-clock bound on every git subprocess this service runs.
  #
  # Every git command here is local — status, rev-parse, bundle create, add,
  # diff, apply — so none of them waits on a network the way GitCloneService's
  # clone does, and the measured cost on a real 21k-file session clone is
  # milliseconds. The bound is not for the happy path.
  #
  # It is for the lane. DeferredCloneCleanupJob runs this service on
  # `maintenance`, which has two threads, and an unbounded `Open3.capture3`
  # there is an unbounded hold on half of them: a git wedged on stuck volume
  # I/O or on its own lock never returns, the thread is never given back, and
  # two such runs stop clone reclamation entirely while archived clones keep
  # arriving. That is the same class of failure #998 bounded for the periodic
  # sweeps, on the one path in this job it did not reach.
  #
  # 120s is the number DockerComposeCleanupService::COMPOSE_DOWN_TIMEOUT uses for
  # the other subprocess on this job's path, and leaves a wide margin over the
  # slowest command measured on a large clone. Only the number is shared: that
  # one is `Timeout.timeout` around `Open3.capture3`, which unwinds through
  # `popen_run`'s ensure and waits for the child regardless, so it bounds
  # nothing (#908). This one bounds, because BoundedSubprocess kills the
  # process group rather than raising in the caller.
  GIT_TIMEOUT_SECONDS = Integer(ENV.fetch("CLONE_ARTIFACT_GIT_TIMEOUT_SECONDS", "120"))

  # A working tree that is almost entirely deletions of tracked files is not
  # uncommitted work — it is a clone whose tree was mangled by an interrupted
  # recursive delete, and preserving it turns a transient filesystem accident
  # into a permanent, replayable one (see issue #411).
  #
  # The two thresholds are deliberately conservative, because a legitimate
  # refactor really can delete a lot of files and we would rather preserve a
  # doubtful patch than drop a real one:
  #
  #   MASS_DELETION_MIN_FILES — the observed corruption removes 50-1041 tracked
  #     files at a time. Below 50 the signal is not strong enough to act on, and
  #     the post-apply validation in UnarchiveSessionService is the backstop for
  #     a smaller mangling that still removes something load-bearing.
  #   MASS_DELETION_RATIO — every observed corrupt patch is 100% deletions and
  #     0 additions, while a mass delete a session actually performed usually
  #     ships with the edits that go with it (imports, config, tests). The
  #     tolerance is narrow, though: at 0.95, a patch of 60 deletions needs 4
  #     or more non-deletion entries to stay out of the net, so a *pure* delete
  #     of 50+ tracked files and nothing else is treated as corruption. That
  #     costs the session its deletions — the files come back from HEAD, which
  #     git can always reproduce — and it is never silent: the drop is logged
  #     and counted on the session. See the limitation in docs/.
  MASS_DELETION_MIN_FILES = 50
  MASS_DELETION_RATIO = 0.95

  # `git status --porcelain` XY codes for an unmerged path. A conflicted file
  # is a change, but it is not a deletion — `git apply --3way` leaves these
  # behind when it cannot merge a legitimate patch, and reading DU/UD/DD as
  # deletions would let a failed 3-way look like a gutted tree.
  UNMERGED_STATUS_CODES = %w[DD AU UD UA DU AA UU].freeze

  class ArtifactError < StandardError; end

  # Does a set of changed-file counts have the shape of a recursive delete that ran
  # on the live tree and was interrupted, rather than of human (or agent) work? Shared by the archive path, which
  # refuses to preserve such a patch, and the unarchive path, which refuses to
  # apply one and validates the tree it produced.
  def self.mass_deletion?(deleted:, changed:)
    return false if deleted < MASS_DELETION_MIN_FILES
    return false unless changed.positive?

    deleted >= changed * MASS_DELETION_RATIO
  end

  DirtyCheckResult = Struct.new(:dirty?, :has_uncommitted?, :has_unpushed_commits?, :details, keyword_init: true)
  # `dropped_deletions` is how many tracked-file deletions the archive-side
  # mass-deletion guard threw away, or nil when the guard did not fire. The
  # caller records it on the session, which is what keeps the rate of mangled
  # clones countable without a page per refusal — see #415.
  #
  # `clone_missing?` separates the two ways preservation can fail. A clone that
  # is gone has nothing to preserve and nothing to hold on to; a clone that is
  # still on disk and could not be read is a real failure, and the caller has to
  # keep the clone because it is then the only copy. See #653.
  CreateResult = Struct.new(:success?, :artifacts_path, :dropped_deletions, :clone_missing?, :error,
    keyword_init: true)
  ApplyResult = Struct.new(:success?, :applied_bundle?, :applied_working_tree?, :refused_working_tree?, :error,
    keyword_init: true)

  attr_reader :file_system, :logger

  # @param git_timeout [Numeric] wall-clock bound for each git subprocess.
  #   Injectable so a test can prove the watchdog actually kills a wedged git
  #   without sitting through GIT_TIMEOUT_SECONDS.
  def initialize(file_system: nil, logger: nil, git_timeout: GIT_TIMEOUT_SECONDS)
    @file_system = file_system || RealFileSystemAdapter.new
    @logger = logger || StructuredLogger.new({ service: "CloneArtifactService" })
    @git_timeout = git_timeout
  end

  # Check if a clone has any unpushed state (uncommitted changes or unpushed commits).
  #
  # On error, returns clean so a broken inspection never blocks cleanup — with one
  # exception. A git we had to *kill* returns dirty instead, because "clean" here
  # authorizes the caller to delete the clone, and a timeout is precisely the case
  # where we do not know what the clone holds. See the GitTimeoutError rescue.
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
    if SubprocessStatus.success?(status) && stdout.strip.present?
      has_uncommitted = true
      details << "uncommitted changes (#{stdout.lines.count} files)"
    end

    # Check for unpushed commits
    upstream_ref = detect_upstream_ref(clone_path)
    if upstream_ref
      commit_stdout, _stderr, commit_status = run_git(
        "log", "#{upstream_ref}..HEAD", "--format=%H %s", cwd: clone_path
      )
      if SubprocessStatus.success?(commit_status) && commit_stdout.strip.present?
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
  rescue GitTimeoutError => e
    # A git command we had to kill tells us nothing about whether this clone
    # holds unpushed work — and the caller *deletes* whatever we call clean. So
    # the safe answer is "dirty": preservation is attempted, and if that times
    # out too the clone is held for the reversible window instead of being
    # deleted on the strength of a question we could not ask. Holding a clone
    # costs disk for four days; the other error destroys the only copy of
    # someone's unpushed work, and is not undoable.
    #
    # .warn, not .error: the outcome here is a clone preserved, which is the
    # conservative branch working as designed. The timeout itself is still
    # loud — create_artifacts logs .error when it gives up on the same clone.
    @logger.warn("Dirty-state check timed out; treating the clone as dirty so it is not deleted",
      clone_path: clone_path, error: e.message)
    DirtyCheckResult.new(dirty?: true, has_uncommitted?: false,
      has_unpushed_commits?: false, details: "dirty-state check timed out (#{e.message})")
  rescue => e
    # A clone that vanishes between the early-return guard above and the git
    # invocation below is a benign, expected race: the caller is about to delete
    # the clone anyway, and the correct answer for a missing clone is "clean"
    # (there is nothing to check and nothing to retry). Log that at .info so it
    # does not page on-call. Anything else — a genuine, unexpected failure to
    # inspect a clone that is still present — keeps .error so it stays
    # alert-worthy.
    if vanished_clone?(clone_path)
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
    # The clone can be gone before this even starts: check_dirty_state reads a
    # tree that a concurrent recursive delete is still walking, calls it dirty,
    # and by the time preservation begins there is nothing left to preserve
    # (#653). Say so and return, rather than mkdir_p-ing an artifacts directory
    # that will only ever be empty.
    unless clone_path && file_system.directory?(clone_path)
      @logger.info("Clone path is gone before artifact creation, nothing to preserve",
        clone_path: clone_path, session_id: session_id)
      return CreateResult.new(success?: false, clone_missing?: true, error: "Clone path does not exist")
    end

    # git has already had to be killed on this clone during the dirty check, and
    # nothing since then can have unwedged it. Re-asking costs another
    # GIT_TIMEOUT_SECONDS of a two-thread lane to arrive at the same answer, so
    # decline now and let the caller hold the clone for the reversible window.
    if @git_timed_out_on == clone_path
      @logger.warn("Declining artifact creation: git already timed out on this clone",
        clone_path: clone_path, session_id: session_id)
      return CreateResult.new(success?: false, clone_missing?: false,
        error: "git timed out on this clone during the dirty-state check")
    end

    artifacts_dir = artifacts_path_for(session_id)
    file_system.mkdir_p(artifacts_dir)

    metadata = {
      "created_at" => Time.current.iso8601,
      "clone_path" => clone_path,
      "session_id" => session_id.to_s
    }

    # Capture current branch name
    branch_stdout, _, branch_status = run_git("rev-parse", "--abbrev-ref", "HEAD", cwd: clone_path)
    metadata["branch"] = branch_stdout.strip if SubprocessStatus.success?(branch_status)

    # Capture current commit SHA
    sha_stdout, _, sha_status = run_git("rev-parse", "HEAD", cwd: clone_path)
    metadata["head_sha"] = sha_stdout.strip if SubprocessStatus.success?(sha_status)

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
      metadata["has_bundle"] = SubprocessStatus.success?(bundle_status) && file_system.exists?(bundle_path)
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
    if SubprocessStatus.success?(diff_status) && !diff_stdout.strip.empty?
      counts = count_patch_entries(diff_stdout.each_line)

      if self.class.mass_deletion?(deleted: counts[:deleted], changed: counts[:changed])
        # This clone's tree was gutted by something that is not the session —
        # an interrupted recursive delete leaves exactly this signature. Keep
        # whatever real work is in the patch (additions and modifications) and
        # throw the deletions away, so unarchive restores a working clone
        # instead of replaying the corruption onto a pristine one.
        #
        # .warn, not .error: this path is self-healing. The corruption is
        # dropped, the session's real work still travels in the bundle and the
        # filtered patch, and the deleted files come back from HEAD — so a
        # refusal here is a landmine successfully defused, not an incident.
        # StructuredLogger#error reports to GlitchTip and trips the "Zimmer
        # backend logging errors" Grafana rule, which at .error meant a page per
        # defused clone (#415). The unarchive-side refusals do stay at .error:
        # those are the paths that can leave a session broken. The frequency —
        # which, with clone deletion atomic (#412), is the measurement of whether
        # anything still mangles these trees — stays countable through the marker
        # DeferredCloneCleanupJob writes and MangledCloneReportJob aggregates.
        @logger.warn(
          "Refusing to preserve mass deletions from a mangled clone",
          session_id: session_id,
          clone_path: clone_path,
          deleted_files: counts[:deleted],
          changed_files: counts[:changed]
        )
        metadata["dropped_deletions"] = counts[:deleted]

        diff_stdout = reject_deletion_entries(diff_stdout)
      end

      if diff_stdout.strip.empty?
        metadata["has_working_tree_patch"] = false
      else
        patch_path = File.join(artifacts_dir, "working_tree.patch")
        file_system.binwrite(patch_path, diff_stdout)
        metadata["has_working_tree_patch"] = true
        @logger.info("Saved working tree patch", path: patch_path, size: diff_stdout.bytesize)
      end
    else
      metadata["has_working_tree_patch"] = false
    end

    # Write metadata
    metadata_path = File.join(artifacts_dir, "metadata.json")
    file_system.write(metadata_path, JSON.pretty_generate(metadata))

    CreateResult.new(success?: true, artifacts_path: artifacts_dir,
      dropped_deletions: metadata["dropped_deletions"])
  rescue => e
    # Every run_git above chdirs into the clone, so the benign race
    # check_dirty_state guards lands here too: the clone is deleted mid-flight
    # and the next chdir raises. There is then nothing to preserve and nothing
    # to retry, which is .info — at .error it pages on-call for a race nobody
    # can act on (#653). A failure to read a clone that is still on disk stays
    # .error: that one is real, and it costs the session its unpushed work.
    #
    # Log before cleaning up, so a partial-artifact rm_rf that raises on its way
    # out cannot take the diagnostic for the original failure with it.
    missing = vanished_clone?(clone_path)
    if missing
      @logger.info("Clone path disappeared during artifact creation, nothing left to preserve",
        clone_path: clone_path, session_id: session_id, error: e.message)
    else
      @logger.error("Failed to create artifacts", error: e.message, session_id: session_id)
    end

    file_system.rm_rf(artifacts_dir) if artifacts_dir && file_system.directory?(artifacts_dir)
    CreateResult.new(success?: false, clone_missing?: missing, error: e.message)
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
    refused_working_tree = false

    # Apply git bundle (unpushed commits)
    bundle_path = File.join(artifacts_dir, "bundle.pack")
    if metadata["has_bundle"] && file_system.exists?(bundle_path)
      applied_bundle = apply_bundle(bundle_path, clone_path)
    end

    # Apply working tree patch (uncommitted changes)
    patch_path = File.join(artifacts_dir, "working_tree.patch")
    if metadata["has_working_tree_patch"] && file_system.exists?(patch_path)
      # Patches written before the archive-side guard existed can still be mass
      # deletions of tracked files. Applying one guts the fresh clone — up to
      # and including the agent root's subdirectory, which fails `air prepare`
      # and the session with it. Refuse the patch whole (unlike the archive
      # path, there is no cheap way to keep its additions), and leave the
      # artifacts on disk so a human can salvage anything real out of them.
      counts = count_patch_entries(file_system.each_line(patch_path))
      if self.class.mass_deletion?(deleted: counts[:deleted], changed: counts[:changed])
        @logger.error(
          "Refusing to apply a mass-deletion working tree patch to a fresh clone",
          session_id: session_id,
          clone_path: clone_path,
          patch_path: patch_path,
          deleted_files: counts[:deleted],
          changed_files: counts[:changed]
        )
        refused_working_tree = true
      else
        applied_working_tree = apply_patch(patch_path, clone_path)
      end
    end

    ApplyResult.new(success?: true, applied_bundle?: applied_bundle, applied_working_tree?: applied_working_tree,
      refused_working_tree?: refused_working_tree)
  rescue => e
    @logger.error("Failed to apply artifacts", error: e.message, session_id: session_id)
    ApplyResult.new(success?: false, error: e.message)
  end

  # How much of a clone's tracked tree the working tree currently deletes,
  # relative to how much it changes at all. The unarchive path uses this to
  # decide whether what it just restored is work or wreckage.
  def working_tree_change_counts(clone_path)
    stdout, _, status = run_git("status", "--porcelain", cwd: clone_path)
    return { deleted: 0, changed: 0 } unless SubprocessStatus.success?(status)

    lines = stdout.lines.reject { |line| line.strip.empty? }
    deleted = lines.count do |line|
      code = line[0, 2].to_s
      code.include?("D") && !UNMERGED_STATUS_CODES.include?(code)
    end
    { deleted: deleted, changed: lines.size }
  end

  # The commit a clone is checked out at, or nil if it cannot be read.
  def head_sha(clone_path)
    stdout, _, status = run_git("rev-parse", "HEAD", cwd: clone_path)
    SubprocessStatus.success?(status) ? stdout.strip.presence : nil
  end

  # Undo everything a restore did: move back to `ref` and delete the files the
  # restore added. Passing the commit the clone was checked out at before the
  # restore unwinds a fast-forwarded bundle too — without that, a bundle whose
  # commits are themselves the damage would survive a reset to HEAD. Ignored
  # files (vendor/bundle, node_modules) are left alone: `clean -fd` is not
  # `-fdx`, and they are not part of what a restore writes.
  def restore_working_tree_to(clone_path, ref)
    _, _, reset_status = run_git("reset", "--hard", ref, cwd: clone_path)
    _, _, clean_status = run_git("clean", "-fd", cwd: clone_path)
    SubprocessStatus.success?(reset_status) && SubprocessStatus.success?(clean_status)
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

  # Was the clone deleted out from under us? The disk is the only honest answer,
  # so this asks the disk rather than reading the exception.
  #
  # Errno::ENOENT is tempting as a proxy and is the wrong test. `run_git` is
  # Open3.capture3(..., chdir: clone_path), which raises it both when the chdir
  # target is gone — the race — and when the `git` executable is not on PATH,
  # which is a real failure on a clone that is still there. A recursive delete
  # unlinks the directory itself last, so whenever a chdir does raise for the
  # race, the path is already gone and this returns true anyway.
  #
  # Shared by the two methods DeferredCloneCleanupJob calls, so the archive path
  # cannot come to disagree with itself about which failures are benign — the
  # divergence #653 is about, where one vanished clone was .info in
  # check_dirty_state and .error in create_artifacts.
  def vanished_clone?(clone_path)
    !file_system.directory?(clone_path)
  end

  # Detect the upstream reference for comparing commits.
  # Falls back through: @{upstream} -> origin/HEAD -> origin/main -> origin/master
  def detect_upstream_ref(clone_path)
    # Try @{upstream}
    stdout, _, status = run_git("rev-parse", "--abbrev-ref", "@{upstream}", cwd: clone_path)
    return stdout.strip if SubprocessStatus.success?(status) && stdout.strip.present?

    # Fallback to origin/HEAD
    _, _, status = run_git("rev-parse", "--verify", "origin/HEAD", cwd: clone_path)
    return "origin/HEAD" if SubprocessStatus.success?(status)

    # Fallback to origin/main
    _, _, status = run_git("rev-parse", "--verify", "origin/main", cwd: clone_path)
    return "origin/main" if SubprocessStatus.success?(status)

    # Fallback to origin/master
    _, _, status = run_git("rev-parse", "--verify", "origin/master", cwd: clone_path)
    return "origin/master" if SubprocessStatus.success?(status)

    nil
  end

  # Count the file entries in a `git diff` patch: how many files it touches at
  # all, and how many of those it deletes.
  #
  # One `diff --git` line starts each entry, and a "deleted file mode" line
  # follows for a removal (an addition gets "new file mode" and a rename gets
  # neither — a rename is not a deletion either way). Neither prefix can appear
  # inside patch content: diff body lines are prefixed with "+", "-" or a
  # space, and a --binary payload is base85, whose lines cannot contain a space.
  #
  # Takes an enumerator of raw byte lines rather than the whole patch, because a
  # --binary patch inlines every binary blob it touches and has no useful size
  # bound. The prefixes are ASCII-only so they compare safely against ASCII-8BIT
  # lines.
  def count_patch_entries(lines)
    deleted = 0
    changed = 0

    lines.each do |line|
      changed += 1 if patch_entry_start?(line)
      deleted += 1 if patch_deletion_marker?(line)
    end

    { deleted: deleted, changed: changed }
  end

  # The line that opens a file entry in a `git diff` patch, and the header line
  # that marks that entry as a whole-file removal. See count_patch_entries for
  # why neither prefix can appear inside patch content.
  def patch_entry_start?(line)
    line.start_with?("diff --git ")
  end

  def patch_deletion_marker?(line)
    line.start_with?("deleted file mode ")
  end

  # Drop every whole-file-deletion entry from a patch, keeping the additions and
  # modifications byte-for-byte.
  #
  # Splits on the same markers count_patch_entries counts and re-emits the
  # surviving entries unchanged, so a --binary payload of a file that is *kept*
  # round-trips intact. Works on ASCII-8BIT bytes throughout (each_line splits
  # on "\n" without validating encoding), because the diff this filters is raw
  # git output.
  #
  # This filters the diff already in memory rather than re-running git with
  # --diff-filter=d. The mass-deletion guard fires precisely when a concurrent
  # recursive delete is gutting the clone, so a second chdir into that directory
  # raced the delete and raised Errno::ENOENT, failing the whole preservation
  # (#425). No second git invocation, no race.
  #
  # Byte-identical to what --diff-filter=d produced for every shape a diff of a
  # staged tree can take — text and binary deletions, symlink deletions, renames,
  # mode changes, and content that merely looks like a header. The one input it
  # would treat differently is a bare `* Unmerged path <p>` line, which it folds
  # into the entry above it; the `add -A` on the way in resolves unmerged entries,
  # so the diff this filters cannot contain one.
  def reject_deletion_entries(diff)
    kept = "".b
    entry = "".b
    deletion = false

    diff.each_line do |line|
      if patch_entry_start?(line)
        kept << entry unless deletion
        entry = "".b
        deletion = false
      end
      deletion ||= patch_deletion_marker?(line)
      entry << line
    end
    kept << entry unless deletion

    kept
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
    unless SubprocessStatus.success?(verify_status)
      @logger.warn("Bundle verification failed, skipping")
      return false
    end

    # Fetch commits from bundle
    _, _, fetch_status = run_git("fetch", bundle_path, cwd: clone_path)
    unless SubprocessStatus.success?(fetch_status)
      @logger.warn("Bundle fetch failed")
      return false
    end

    # Fast-forward merge to apply the commits
    _, _, merge_status = run_git("merge", "--ff-only", "FETCH_HEAD", cwd: clone_path)
    if SubprocessStatus.success?(merge_status)
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
    if SubprocessStatus.success?(apply_status)
      @logger.info("Applied working tree patch")
      return true
    end

    # Fall back to 3-way merge
    _, _, apply3_status = run_git("apply", "--3way", "--whitespace=nowarn", patch_path, cwd: clone_path)
    if SubprocessStatus.success?(apply3_status)
      @logger.info("Applied working tree patch with 3-way merge")
      return true
    end

    @logger.warn("Working tree patch apply failed")
    false
  end

  # Run a git command safely using array syntax (prevents shell injection), under
  # the GIT_TIMEOUT_SECONDS watchdog.
  #
  # BoundedSubprocess rather than a bare Open3.capture3: it starts the child as
  # its own process-group leader and SIGKILLs the whole group on deadline, which
  # matters because git spawns helpers (pack-objects, index-pack) that have to
  # die with it. It returns ASCII-8BIT stdout/stderr byte-for-byte identical to
  # the `Open3.capture3(..., binmode: true)` it replaces, so the encoding
  # contract below is unchanged.
  #
  # Git output is raw bytes: branch names, diffs, and status can contain
  # non-UTF-8 sequences (e.g. a staged binary file or a file name in a
  # non-UTF-8 locale). Calling String methods that validate encoding (strip,
  # =~, present?) on bytes tagged UTF-8 raises
  # Encoding::CompatibilityError "invalid byte sequence in UTF-8".
  #
  # binmode: false (default) — scrub stdout/stderr to valid UTF-8 (invalid
  #   bytes become U+FFFD). Safe for text output that flows into String ops,
  #   metadata, and JSON.pretty_generate.
  # binmode: true — keep the raw bytes (ASCII-8BIT) untouched. Use when the
  #   output must round-trip byte-for-byte, e.g. a diff written as a patch.
  def run_git(*args, cwd:, binmode: false)
    command = [ "git" ] + args.map(&:to_s)
    @logger.debug("Running git command", command: command.join(" "), cwd: cwd)
    stdout, stderr, status = BoundedSubprocess.run(command, cwd: cwd, timeout: @git_timeout)
    if binmode
      # BoundedSubprocess accumulates into a UTF-8 buffer that Ruby promotes to
      # ASCII-8BIT only once a chunk actually carries a high byte, so the
      # encoding it hands back is data-dependent: BINARY for a patch containing
      # a binary blob, UTF-8 for one that happens to be all ASCII. The bytes are
      # identical either way; `.b` just states the encoding the caller is
      # promised, so a patch written to disk from this cannot depend on its own
      # contents for its tag.
      stdout = stdout.b
      stderr = stderr.b
    else
      stdout = stdout.dup.force_encoding(Encoding::UTF_8).scrub
      stderr = stderr.dup.force_encoding(Encoding::UTF_8).scrub
    end
    [ stdout, stderr, status ]
  rescue BoundedSubprocess::TimeoutError => e
    # Remember which clone this was, so create_artifacts does not spend another
    # GIT_TIMEOUT_SECONDS of the same two-thread lane re-asking a question that
    # has just failed to arrive. DeferredCloneCleanupJob memoizes one service
    # per run, so this lives exactly as long as the clone it describes; keying
    # it by path rather than setting a bare boolean keeps it honest if an
    # instance is ever reused across clones.
    @git_timed_out_on = cwd
    raise GitTimeoutError, e.message.sub(/\Acommand /, "git command ")
  end
end
