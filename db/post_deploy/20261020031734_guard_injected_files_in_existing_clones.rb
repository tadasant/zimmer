# frozen_string_literal: true

# Writes InjectedFilesGitGuard into every session clone already on disk
# (tadasant/zimmer#1382).
#
# WHY A TASK. The guard is applied by AirPrepareService on every prepare — a
# session's next turn, a fork, an unarchive — so a clone that is idle, parked in
# needs_input, or mid-turn when this deploys would hold an unguarded `.mcp.json`
# until something prepares it again. An agent already running in one can
# `git commit -a` it in the meantime, which is the incident itself. No migration
# can reach a file, so it is a one-time step implied by the deploy.
#
# WHAT IT TOUCHES. Only the clone's local `info/exclude` and the skip-worktree
# bit of a tracked secret-bearing file — the same two things a prepare writes.
# A recorded directory that is gone, or is not inside a git repository, is
# counted and left alone.
#
# IDEMPOTENT. The guard adds only the exclude lines it lacks and re-marking a
# skip-worktree entry is a no-op, so a second pass changes nothing.
#
# Runs in the worker (PostDeployTaskJob is on the worker's queues), which is the
# container that holds the clones volume.
class GuardInjectedFilesInExistingClones < PostDeployTask
  BATCH_SIZE = 200

  # Failing ids carried on the ledger row; the count is exact either way.
  MAX_REPORTED_IDS = 50

  def up
    @guarded = stats.fetch("guarded", 0)
    @unchanged = stats.fetch("unchanged", 0)
    @not_a_clone = stats.fetch("not_a_clone", 0)
    @failed = stats.fetch("failed", 0)
    @failed_ids = stats.fetch("failed_session_ids", [])

    sweep(Session.where("metadata ->> 'clone_path' IS NOT NULL"), batch_size: BATCH_SIZE) do |batch|
      batch.each { |session| guard(session) }
      checkpoint!(
        guarded: @guarded,
        unchanged: @unchanged,
        not_a_clone: @not_a_clone,
        failed: @failed,
        failed_session_ids: @failed_ids
      )
    end
  end

  private

  def guard(session)
    directory = session.working_directory
    unless directory.is_a?(String) && File.directory?(directory)
      @not_a_clone += 1
      return
    end

    if InjectedFilesGitGuard.apply!(session: session, working_directory: directory).any?
      @guarded += 1
    else
      @unchanged += 1
    end
  rescue StandardError => e
    # One clone that cannot be guarded must not stop the rest. The id is what
    # lets someone find it from /health without a shell; the message is logged
    # rather than stored, because it can name a path.
    logger.warn "[GuardInjectedFilesInExistingClones] session #{session.id}: #{e.class}: #{e.message}"
    @failed += 1
    @failed_ids << session.id if @failed_ids.size < MAX_REPORTED_IDS
  end
end
