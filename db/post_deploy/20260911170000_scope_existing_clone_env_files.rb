# frozen_string_literal: true

# Narrows every clone `.env` already on disk to the secrets its session's own
# artifacts declare (tadasant/zimmer#372).
#
# WHY A TASK. Scoping is applied by SessionEnvFile whenever a session is
# prepared — its next turn, a fork, an unarchive — so a clone whose session is
# idle, parked in needs_input, or archived inside its trash window would keep the
# whole ~90-secret bundle on disk until something ran it again, which for most of
# them is never. That is a one-time step implied by the deploy, and no migration
# can reach a file.
#
# WHAT IT TOUCHES. Only a `.env` that already exists in a session's recorded
# working directory. A clone without one is counted and left alone: writing a
# file the session never had is not this task's business, and the prepare path
# will write it if the session runs. The rewrite goes through SessionEnvFile, so
# lines Zimmer does not manage survive exactly as they do on a prepare.
#
# IDEMPOTENT. The rewrite is a pure function of the session's current selection
# and the bundle, so a second pass writes the same bytes. A clone deleted between
# batches is simply absent and counted as such.
#
# Runs in the worker (PostDeployTaskJob is on the worker's queues), which is the
# container that holds the clones volume.
class ScopeExistingCloneEnvFiles < PostDeployTask
  BATCH_SIZE = 200

  # Failing ids carried on the ledger row; the count is exact either way.
  MAX_REPORTED_IDS = 50

  def up
    @rewritten = stats.fetch("rewritten", 0)
    @no_env_file = stats.fetch("no_env_file", 0)
    @failed = stats.fetch("failed", 0)
    @failed_ids = stats.fetch("failed_session_ids", [])
    @file_system = RealFileSystemAdapter.new

    sweep(Session.where("metadata ->> 'clone_path' IS NOT NULL"), batch_size: BATCH_SIZE) do |batch|
      batch.each { |session| rescope(session) }
      checkpoint!(
        rewritten: @rewritten,
        no_env_file: @no_env_file,
        failed: @failed,
        failed_session_ids: @failed_ids
      )
    end
  end

  private

  def rescope(session)
    directory = session.working_directory
    unless directory.is_a?(String) && @file_system.exists?(File.join(directory, EnvFile::FILENAME))
      @no_env_file += 1
      return
    end

    if SessionEnvFile.write!(session: session, working_directory: directory, file_system: @file_system)
      @rewritten += 1
    else
      @no_env_file += 1
    end
  rescue StandardError => e
    # One clone that cannot be rewritten must not stop the rest. The id is what
    # lets someone find it from /health without a shell; the message is logged
    # rather than stored, because it can name a path.
    logger.warn "[ScopeExistingCloneEnvFiles] session #{session.id}: #{e.class}: #{e.message}"
    @failed += 1
    @failed_ids << session.id if @failed_ids.size < MAX_REPORTED_IDS
  end
end
