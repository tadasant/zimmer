# frozen_string_literal: true

require "path_sanitizer"

# Service for unarchiving a session and restoring its Claude Code state.
#
# Unarchiving creates an environment that allows Claude Code to resume where it left off:
# - Recreates the clone directory from the original git repository/branch
# - Restores the transcript to the Claude Code project directory using the existing session_id
# - Transitions the session to needs_input status, ready for follow-up prompts
#
# Unlike simple status restoration, this service ensures Claude Code can actually
# continue the conversation by:
# 1. Re-cloning the git repository (if clone was deleted during archive)
# 2. Writing the preserved transcript to the correct location for Claude Code to find
# 3. Regenerating MCP configuration files
#
# @example
#   result = UnarchiveSessionService.call(
#     session: archived_session,
#     file_system: RealFileSystemAdapter.new
#   )
#   if result.success?
#     redirect_to session
#   else
#     flash[:alert] = result.error
#   end
class UnarchiveSessionService
  include DatabaseRetry
  include McpServerBackfill

  # Result object returned by the service
  Result = Struct.new(:success?, :session, :error, :clone_restored, keyword_init: true)

  attr_reader :session, :file_system

  def initialize(session:, file_system: nil)
    @session = session
    @file_system = file_system || RealFileSystemAdapter.new
    @logger = StructuredLogger.new({ session_id: session.id, service: "UnarchiveSessionService" })
  end

  def self.call(...)
    new(...).call
  end

  def call
    # Read fresh state so validate_inputs and the slow-path branches don't act
    # on a stale in-memory archived? from before a concurrent caller won. The
    # cheap-path bail-out below avoids wasting a git clone on the loser; the
    # row-locked check in transition_to_needs_input remains the correctness
    # gate. See issues #3720 and #4600.
    session.reload

    # A concurrent unarchive caller (an overlapping recurring-trigger fire, or a
    # manual UI unarchive) may have already won the race and moved the row out of
    # trash: it cleared archived_at and advanced the status to needs_input, or
    # past it to running/waiting once its resumed job started. In every one of
    # those cases the unarchive we were asked to perform has already happened, so
    # return an idempotent success here rather than falling through to
    # validate_inputs — which returns "Session is not in trash" for a
    # running/waiting winner, making Trigger#resuscitate_session! raise the
    # spurious .error that trips the agent-orchestrator-logs alert (#4600). This
    # mirrors the row-locked short-circuit in transition_to_needs_input, and must
    # stay in sync with it: the loser can reload here BEFORE it passes
    # validate_inputs (this check) or AFTER, once it holds the lock (that check).
    #
    # We key on BOTH archived_at being cleared AND the status having left
    # :archived so we never mask the abnormal "status advanced but archived_at
    # still populated" row that #3720's guard ordering protects — that row falls
    # through to validate_inputs and returns a clean failure, unchanged.
    if !session.archived? && session.archived_at.nil?
      @logger.info(
        "Session already unarchived by a concurrent caller on entry — returning idempotent success without slow-path work",
        current_status: session.status
      )
      return Result.new(success?: true, session: session, clone_restored: false)
    end

    # Validate inputs
    validation_error = validate_inputs
    return Result.new(success?: false, error: validation_error) if validation_error

    # Check if clone and working directory both exist (quick unarchive within undo window)
    # Must check BOTH paths because for sessions with subdirectories, they differ:
    # - clone_path: /home/rails/.agent-orchestrator/clones/repo-main-12345-abcd
    # - working_directory: /home/rails/.agent-orchestrator/clones/repo-main-12345-abcd/subdir
    clone_path = session.metadata&.dig("clone_path")
    working_directory = session.metadata&.dig("working_directory")
    clone_fully_exists = clone_path.present? &&
                         file_system.directory?(clone_path) &&
                         working_directory.present? &&
                         file_system.directory?(working_directory)

    if clone_fully_exists
      # Clone still exists - just restore transcript file and transition state
      @logger.info("Clone still exists, performing quick unarchive",
        clone_path: clone_path,
        working_directory: working_directory
      )
      result = restore_transcript_only
      return result unless result.success?
    else
      # Clone was deleted or incomplete - need to recreate it
      @logger.info("Clone deleted or incomplete, recreating from git repository",
        clone_path: clone_path,
        clone_path_exists: clone_path.present? && file_system.directory?(clone_path),
        working_directory: working_directory,
        working_directory_exists: working_directory.present? && file_system.directory?(working_directory)
      )
      result = recreate_clone_and_restore
      return result unless result.success?
    end

    # Transition session state to needs_input
    transition_result = transition_to_needs_input
    return transition_result unless transition_result.success?

    # Log success
    @logger.info("Session unarchived successfully",
      session_id: session.id,
      clone_restored: !clone_fully_exists
    )

    Result.new(success?: true, session: session, clone_restored: !clone_fully_exists)
  rescue => e
    @logger.error("Failed to unarchive session", error: e.message, backtrace: e.backtrace&.first(5))
    Result.new(success?: false, error: "Failed to unarchive session: #{e.message}")
  end

  private

  def validate_inputs
    # Session must be archived
    return "Session is not in trash" unless session.archived?

    # Session must have git_root for clone recreation
    return "Session has no git_root" if session.git_root.blank?

    # Session must have a session_id (UUID) for Claude Code to resume
    return "Session has no session_id" if session.session_id.blank?

    nil # No error
  end

  # Fast path: clone still exists, just restore transcript file
  def restore_transcript_only
    working_directory = session.metadata&.dig("working_directory")

    unless working_directory.present?
      return Result.new(success?: false, error: "Session has no working_directory in metadata")
    end

    # Verify working_directory actually exists on disk (clone_path may exist but
    # subdirectory might have been removed)
    unless file_system.directory?(working_directory)
      return Result.new(success?: false, error: "Working directory does not exist: #{working_directory}")
    end

    # Write transcript file to Claude Code's project directory
    if session.transcript.present?
      write_success = write_transcript_file(
        working_directory: working_directory,
        session_id: session.session_id,
        transcript: session.transcript
      )
      return Result.new(success?: false, error: "Failed to write transcript file") unless write_success
    end

    # Regenerate MCP config (includes auto-injected self-session server)
    regenerate_mcp_config(working_directory)

    Result.new(success?: true)
  end

  # Slow path: clone was deleted, need to recreate it
  def recreate_clone_and_restore
    # Create new clone from git
    clone_result = create_clone
    return Result.new(success?: false, error: clone_result[:error]) if clone_result[:error]

    new_clone_path = clone_result[:clone_path]
    new_working_directory = clone_result[:working_directory]

    # Apply preserved artifacts if they exist (unpushed commits + uncommitted changes)
    apply_preserved_artifacts(new_clone_path)

    # Update session metadata with new clone paths
    update_result = update_session_metadata(
      clone_path: new_clone_path,
      working_directory: new_working_directory
    )
    return Result.new(success?: false, error: "Failed to update session metadata") unless update_result

    # Write transcript file if present
    if session.transcript.present?
      write_success = write_transcript_file(
        working_directory: new_working_directory,
        session_id: session.session_id,
        transcript: session.transcript
      )
      return Result.new(success?: false, error: "Failed to write transcript file") unless write_success
    end

    # Regenerate MCP config (includes auto-injected self-session server)
    regenerate_mcp_config(new_working_directory)

    Result.new(success?: true)
  end

  def apply_preserved_artifacts(clone_path)
    artifact_service = CloneArtifactService.new(file_system: file_system)
    return unless artifact_service.artifacts_exist?(session.id)

    @logger.info("Found preserved artifacts, applying to fresh clone")
    apply_result = artifact_service.apply_artifacts(session_id: session.id, clone_path: clone_path)

    if apply_result.success?
      @logger.info("Applied artifacts",
        bundle: apply_result.applied_bundle?,
        working_tree: apply_result.applied_working_tree?
      )

      # Clean up artifacts now that they've been successfully applied.
      # Without this, artifacts would be orphaned on disk since unarchive
      # clears trash_after, so EmptyTrashJob would never find this session.
      artifact_service.cleanup_artifacts(session.id)
      if session.metadata&.dig("artifacts_path").present?
        new_metadata = session.metadata.except("artifacts_path")
        session.update_column(:metadata, new_metadata)
      end
    else
      @logger.warn("Failed to apply some artifacts, keeping on disk for manual recovery",
        error: apply_result.error,
        artifacts_path: artifact_service.artifacts_path_for(session.id)
      )
      # Don't fail unarchive — a clean clone is better than failing entirely.
      # Keep artifacts on disk so they can be manually recovered if needed.
    end
  rescue => e
    @logger.warn("Error applying preserved artifacts", error: e.message)
    # Don't fail unarchive
  end

  def create_clone
    @logger.info("Creating clone from git repository",
      git_root: session.git_root,
      branch: session.branch,
      subdirectory: session.subdirectory
    )

    result = GitCloneService.create_clone(
      session.git_root,
      branch: session.branch || "main",
      subdirectory: session.subdirectory
    )

    @logger.info("Clone created successfully", clone_path: result[:clone_path])
    result
  rescue GitCloneService::GitError => e
    @logger.error("Failed to create clone", error: e.message)
    { error: e.message }
  end

  def update_session_metadata(clone_path:, working_directory:)
    with_db_retry do
      new_metadata = (session.metadata || {}).merge(
        "clone_path" => clone_path,
        "working_directory" => working_directory,
        "full_clone_path" => working_directory,
        "unarchived_at" => Time.current.iso8601,
        "clone_recreated" => true
      )

      # Clear old process state and stale retry metadata since we're starting fresh.
      # See Session::STALE_RETRY_METADATA_KEYS for the retry metadata keys.
      new_metadata = new_metadata.except(
        "process_pid",
        "exception_class",
        *Session::STALE_RETRY_METADATA_KEYS
      )

      session.update!(metadata: new_metadata)
    end
    true
  rescue => e
    @logger.error("Failed to update session metadata", error: e.message)
    false
  end

  def write_transcript_file(working_directory:, session_id:, transcript:)
    # Calculate transcript directory path using Claude's naming convention
    home_dir = File.expand_path("~")
    claude_projects_dir = File.join(home_dir, ".claude", "projects")
    sanitized_path = PathSanitizer.sanitize(working_directory)
    transcript_dir = File.join(claude_projects_dir, sanitized_path)

    # Ensure directory exists
    file_system.mkdir_p(transcript_dir)

    # Write the transcript file
    transcript_file = File.join(transcript_dir, "#{session_id}.jsonl")
    @logger.info("Writing transcript file",
      path: transcript_file,
      lines: transcript.lines.count
    )

    file_system.write(transcript_file, transcript)

    true
  rescue => e
    @logger.error("Failed to write transcript file", error: e.message)
    false
  end

  def regenerate_mcp_config(working_directory)
    return unless working_directory.present? && file_system.directory?(working_directory)

    # Heal sessions whose mcp_servers column landed empty at creation time before
    # re-running AIR, so `air prepare --without-defaults` regenerates .mcp.json
    # from the root's currently-resolved defaults rather than degrading to just
    # the auto-injected self-session server. See McpServerBackfill.
    backfill_default_mcp_servers_if_empty(session)

    air_service = AirPrepareService.new(
      session: session,
      working_directory: working_directory,
      file_system: file_system
    )
    if session.mcp_servers.present? || session.catalog_skills.present? || session.catalog_hooks.present? || session.catalog_plugins.present?
      air_service.prepare!
    else
      air_service.ensure_baseline_mcp_config!
    end

    # Persist auto-injected MCP server names so the UI shows the same set of
    # servers after unarchive as before. Without this, custom_metadata keeps
    # whatever injected_mcp_servers was set during the original run, which can
    # diverge from what AIR actually wrote into the regenerated .mcp.json.
    store_injected_mcp_servers(air_service.injected_mcp_servers)

    @logger.info("AIR prepare completed for unarchived session", working_directory: working_directory)
  rescue => e
    # Log but don't fail - config is not critical for unarchive
    @logger.warn("Failed to run AIR prepare for unarchived session", error: e.message)
  end

  # Mirror of AgentSessionJob#store_injected_mcp_servers so the unarchive flow
  # keeps custom_metadata["injected_mcp_servers"] in sync with what AIR wrote
  # into .mcp.json. Always overwrites the prior value (including replacing a
  # previously-injected list with an empty one) so stale entries from earlier
  # runs don't leak into the regenerated state.
  def store_injected_mcp_servers(injected_servers)
    with_db_retry do
      session.reload
      merged = (session.custom_metadata || {}).merge("injected_mcp_servers" => injected_servers)
      session.update!(custom_metadata: merged)
    end
  rescue => e
    @logger.warn("Failed to store injected_mcp_servers", error: e.message)
  end

  # Serialized with SELECT FOR UPDATE so concurrent unarchive callers (e.g.,
  # a recurring trigger fire racing a manual UI unarchive) can't both clear
  # archived_at and then race the AASM guard. The losing caller observes that
  # the winner already unarchived the session (needs_input, or advanced past it
  # to running/waiting) and returns success rather than raising in
  # Trigger#resuscitate_session!. See issues #3720 and #4600.
  def transition_to_needs_input
    with_db_retry do
      session.with_lock do
        # A concurrent unarchive caller (e.g. an overlapping recurring-trigger
        # fire racing this one, or a manual UI unarchive) may have already won
        # the race: it cleared archived_at and moved the row out of the archived
        # status. The winner may land on needs_input, or advance past it to
        # running/waiting as its resumed job starts before this loser acquires
        # the lock. In every one of those cases the unarchive we were asked to
        # perform has already happened, so treat "no longer in trash" as an
        # idempotent success rather than falling through to the
        # may_unarchive_to_needs_input? guard — which fails for running/waiting
        # and makes the loser raise a spurious .error in
        # Trigger#resuscitate_session!. We key on BOTH archived_at being cleared
        # AND the status having left :archived so we never short-circuit the
        # abnormal "status advanced but archived_at still populated" row that
        # #3720's guard-ordering protects. See issues #3720 and #4600.
        if !session.archived? && session.archived_at.nil?
          @logger.info(
            "Session already unarchived by a concurrent caller — treating as idempotent success",
            current_status: session.status
          )
          return Result.new(success?: true)
        end

        # Guard BEFORE the destructive write so a row in some other non-archived
        # state doesn't get archived_at cleared on its way to a guard failure.
        unless session.may_unarchive_to_needs_input?
          return Result.new(
            success?: false,
            error: "Cannot transition session to needs_input state (current status: #{session.status})"
          )
        end

        cleaned_metadata = (session.metadata || {}).except(
          "process_pid",
          "exception_class",
          *Session::STALE_RETRY_METADATA_KEYS
        )
        session.update!(archived_at: nil, metadata: cleaned_metadata)

        # Always transition to needs_input regardless of the session's
        # pre-archive status. This is intentional: the user wants to continue
        # the conversation, so we put the session in a state where they can
        # immediately send follow-up prompts. If the session originally failed,
        # the user can still see the failure in the transcript and choose how
        # to proceed.
        session.unarchive_to_needs_input!

        session.logs.create!(
          content: "Session unarchived with full state restoration - ready for follow-up prompts",
          level: "info"
        )
      end
    end

    Result.new(success?: true)
  rescue => e
    @logger.error("Failed to transition session state", error: e.message)
    Result.new(success?: false, error: "Failed to transition session state: #{e.message}")
  end
end
