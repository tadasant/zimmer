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
# A session that never ran has no conversation to continue, so none of that
# applies to it. It takes a separate, much shorter path — see
# #restore_never_started — that simply returns it to its pre-start state so it
# can be started fresh from its original configuration.
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
    # gate. See issues pulsemcp/pulsemcp#3720 and pulsemcp/pulsemcp#4600.
    session.reload

    # A concurrent unarchive caller (an overlapping recurring-trigger fire, or a
    # manual UI unarchive) may have already won the race and moved the row out of
    # trash: it cleared archived_at and advanced the status to needs_input, or
    # past it to running/waiting once its resumed job started. In every one of
    # those cases the unarchive we were asked to perform has already happened, so
    # return an idempotent success here rather than falling through to
    # validate_inputs — which returns "Session is not in trash" for a
    # running/waiting winner, making Trigger#resuscitate_session! raise the
    # spurious .error that trips the agent-orchestrator-logs alert (pulsemcp/pulsemcp#4600). This
    # mirrors the row-locked short-circuit in transition_to_needs_input, and must
    # stay in sync with it: the loser can reload here BEFORE it passes
    # validate_inputs (this check) or AFTER, once it holds the lock (that check).
    #
    # We key on BOTH archived_at being cleared AND the status having left
    # :archived so we never mask the abnormal "status advanced but archived_at
    # still populated" row that pulsemcp/pulsemcp#3720's guard ordering protects — that row falls
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

    # Everything below runs while the row still says `archived` — the status
    # transition is the last step, after the clone, the artifact replay and
    # `air prepare`. For that window an unarchiving session is indistinguishable
    # from an abandoned one with a stale clone, and the hourly reapers delete the
    # clone this method is in the middle of building (zimmer#808). The stamp is
    # what tells them apart; see Session::UNARCHIVE_IN_FLIGHT_KEY.
    mark_unarchive_in_flight!

    begin
      unarchive_with_clone
    ensure
      clear_unarchive_in_flight!
    end
  end

  private

  # Marks this session as being unarchived right now, so no reaper treats its
  # clone, scratch directory or preserved artifacts as abandoned. Best-effort:
  # failing to stamp must not fail the unarchive, and the grace period bounds a
  # stamp that is never cleared.
  def mark_unarchive_in_flight!
    session.update_column(
      :metadata,
      (session.metadata || {}).merge(Session::UNARCHIVE_IN_FLIGHT_KEY => Time.current.utc.iso8601)
    )
  rescue StandardError => e
    @logger.warn("Could not mark the unarchive in flight", error: e.message)
  end

  # Drops the stamp once the unarchive is over, however it ended. On success the
  # session is out of `archived` and protected by its status; on failure it is
  # archived with nothing in flight, which is the truth.
  def clear_unarchive_in_flight!
    session.reload
    return if session.metadata&.dig(Session::UNARCHIVE_IN_FLIGHT_KEY).blank?

    session.update_column(:metadata, session.metadata.except(Session::UNARCHIVE_IN_FLIGHT_KEY))
  rescue StandardError => e
    @logger.warn("Could not clear the unarchive-in-flight marker", error: e.message)
  end

  def unarchive_with_clone
    return restore_never_started if session.never_ran?

    # Check if clone and working directory both exist (quick unarchive within undo window)
    # Must check BOTH paths because for sessions with subdirectories, they differ:
    # - clone_path: /home/rails/.zimmer/clones/repo-main-12345-abcd
    # - working_directory: /home/rails/.zimmer/clones/repo-main-12345-abcd/subdir
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

  # Restore a session whose agent process never launched.
  #
  # There is no conversation to resume, no transcript to write and no clone
  # worth reviving — the session was created, held at the starting line, and
  # archived without ever taking a turn. So this path does none of that work. It
  # drops whatever half-written setup artifacts an aborted spawn left behind and
  # puts the row back in needs_input, which is the state it was archived out of.
  # Everything the session needs in order to run — its prompt, agent root,
  # skills, plugins, lineage — is on the row and untouched.
  #
  # Whatever starts it next runs the full setup pipeline rather than a resume: a
  # follow-up prompt from the UI, a restart, or a trigger following up all land
  # in AgentSessionJob, which reclassifies a prompt to a session with no
  # session_id as a fresh start — clone, mint a session_id, spawn.
  #
  # Skipping the git clone is the point, not an optimization: cloning here would
  # leave a clone_path the fresh start does not use and the reapers would have
  # to sweep.
  def restore_never_started
    @logger.info("Session never started — restoring it to its pre-start state instead of resuming a conversation")

    # The setup artifacts go in the transition's own write rather than a second
    # one of ours: that write is inside the row lock, so clearing them there is
    # atomic with leaving `archived` and cannot half-apply to a session whose
    # transition then fails, or race the concurrent caller the lock exists for.
    transition_result = transition_to_needs_input(
      log_message: "Session restored from trash. It never started, so there is no conversation to " \
                   "resume — it runs its original prompt from a fresh clone when it is next started.",
      also_clear: Session::SETUP_ARTIFACT_KEYS
    )
    return transition_result unless transition_result.success?

    Result.new(success?: true, session: session, clone_restored: false)
  end

  def validate_inputs
    # Session must be archived
    return "Session is not in trash" unless session.archived?

    # Session must have git_root for clone recreation
    return "Session has no git_root" if session.git_root.blank?

    # Session must have a session_id (UUID) for Claude Code to resume — but only
    # a session that has something to resume. A session that never ran has no
    # conversation to bring back, and refusing it here made archiving one
    # irreversible for exactly the class of session where starting over is
    # cheapest and most obviously right (zimmer#557). Those are restored fresh
    # instead; see #restore_never_started.
    #
    # A session holding a transcript with no id is NOT that: it has work, this
    # service genuinely cannot restore it, and that stays a loud failure.
    return "Session has no session_id" if session.session_id.blank? && !session.never_ran?

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

    # Re-materialize the transcript at the runtime's resume path. :skipped (a
    # runtime with no single-file resume path, e.g. Codex) is not a failure.
    if session.transcript.present?
      write_result = write_transcript_file(
        working_directory: working_directory,
        transcript: session.transcript
      )
      return Result.new(success?: false, error: "Failed to write transcript file") if write_result == :failed
    end

    # Regenerate MCP config (includes auto-injected self-session server, plus the
    # subagent-spawning zimmer server for roots with default_subagent_roots)
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

    # Re-materialize the transcript at the runtime's resume path. :skipped (a
    # runtime with no single-file resume path, e.g. Codex) is not a failure.
    if session.transcript.present?
      write_result = write_transcript_file(
        working_directory: new_working_directory,
        transcript: session.transcript
      )
      return Result.new(success?: false, error: "Failed to write transcript file") if write_result == :failed
    end

    # Regenerate MCP config (includes auto-injected self-session server, plus the
    # subagent-spawning zimmer server for roots with default_subagent_roots)
    regenerate_mcp_config(new_working_directory)

    Result.new(success?: true)
  end

  def apply_preserved_artifacts(clone_path)
    artifact_service = CloneArtifactService.new(file_system: file_system)
    return unless artifact_service.artifacts_exist?(session.id)

    @logger.info("Found preserved artifacts, applying to fresh clone")
    # The commit the fresh clone is checked out at, captured before anything is
    # applied: it is what "pristine" means for this clone, and a bundle can move
    # HEAD off it.
    pristine_ref = artifact_service.head_sha(clone_path) || "HEAD"
    apply_result = artifact_service.apply_artifacts(session_id: session.id, clone_path: clone_path)

    if apply_result.success?
      @logger.info("Applied artifacts",
        bundle: apply_result.applied_bundle?,
        working_tree: apply_result.applied_working_tree?,
        refused_working_tree: apply_result.refused_working_tree?
      )

      damage = restore_damage(clone_path, artifact_service)
      if damage
        # What we just restored is not the session's work, it is the wreckage of
        # an interrupted delete that the archive path captured (issue #411).
        # Handing it to `air prepare` fails the session outright, so put the
        # clone back the way git cloned it. A pristine clone loses uncommitted
        # work; a gutted one loses the session.
        @logger.error("Preserved artifacts gutted the fresh clone, reverting to the pristine checkout",
          session_id: session.id,
          clone_path: clone_path,
          reason: damage
        )
        reverted = artifact_service.restore_working_tree_to(clone_path, pristine_ref)
        remaining_damage = restore_damage(clone_path, artifact_service)

        if !reverted || remaining_damage
          # The revert is the whole guard. If it did not take, the session is
          # about to start against a clone that is still gutted, which is the
          # failure this exists to prevent — say so at .error rather than
          # letting the reassuring line above stand as the last word.
          @logger.error("Could not revert the clone to its pristine checkout",
            session_id: session.id,
            clone_path: clone_path,
            git_succeeded: reverted,
            remaining_damage: remaining_damage
          )
        end

        note_retained_artifacts(damage, artifact_service.artifacts_path_for(session.id))
        return
      end

      # A refused patch is corruption we declined to replay, not work we
      # applied. Keep it on disk rather than deleting the only copy.
      if apply_result.refused_working_tree?
        note_retained_artifacts("the preserved patch is a mass deletion of tracked files",
          artifact_service.artifacts_path_for(session.id))
        return
      end

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

  # Artifacts we declined to restore outlive every reaper: unarchive clears
  # trash_after, so EmptyTrashJob never revisits this session, and
  # StaleCloneCleanupJob only sweeps artifacts for sessions that are archived or
  # long-failed. Name the path in the session log, which is the one surface a
  # human actually sees, so the directory is findable rather than merely leaked.
  def note_retained_artifacts(reason, artifacts_path)
    session.logs.create!(
      level: "warning",
      content: "Preserved artifacts were not restored (#{reason}). The clone is the pristine checkout from " \
               "git; the artifacts are kept at #{artifacts_path} for manual recovery and nothing will reap them."
    )
  rescue => e
    @logger.warn("Failed to record retained artifacts in the session log", error: e.message)
  end

  # Did restoring the artifacts damage the clone rather than restore it?
  # Returns a human-readable reason, or nil when the tree is fine.
  #
  # Two signals, because they catch different sizes of the same accident:
  # the agent root's subdirectory disappearing is fatal on its own regardless
  # of how few files it took with it (`air prepare` writes
  # <clone>/<subdirectory>/.mcp.json and dies with ENOENT), while a tree that
  # is now almost entirely deletions of tracked files is the mass-deletion
  # signature whatever it happened to hit.
  def restore_damage(clone_path, artifact_service)
    if session.subdirectory.present?
      subdirectory_path = File.join(clone_path, session.subdirectory)
      unless file_system.directory?(subdirectory_path)
        return "subdirectory '#{session.subdirectory}' no longer exists in the clone"
      end
    end

    counts = artifact_service.working_tree_change_counts(clone_path)
    if CloneArtifactService.mass_deletion?(deleted: counts[:deleted], changed: counts[:changed])
      return "#{counts[:deleted]} of #{counts[:changed]} changed files are deletions of tracked files"
    end

    nil
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

  # Re-materialize the stored transcript at the path the session's runtime
  # resumes from. Mirrors AgentSessionJob#write_transcript_to_clone.
  #
  # The path comes from TranscriptSource#resume_transcript_path, which returns
  # nil for runtimes that cannot be restored by writing stored bytes to a single
  # deterministic path (Codex: date-partitioned, UUID-named, possibly
  # Zstandard-compressed rollouts). For those runtimes there is nothing to write,
  # and writing a Claude-shaped file the runtime will never read is worse than
  # writing nothing — so :skipped is a normal outcome, NOT a failure. An
  # unarchive of a Codex session must succeed.
  #
  # @return [Symbol] :written when the transcript landed on disk, :skipped when
  #   the runtime has no single-file resume path, :failed when the write was
  #   attempted and raised
  def write_transcript_file(working_directory:, transcript:)
    transcript_file = TranscriptRuntime.source_for(session, file_system: file_system)
      .resume_transcript_path(session: session, working_directory: working_directory)

    if transcript_file.nil?
      @logger.info("Runtime has no single-file resume transcript path; skipping transcript restore",
        agent_runtime: session.agent_runtime
      )
      return :skipped
    end

    file_system.mkdir_p(File.dirname(transcript_file))

    @logger.info("Writing transcript file",
      path: transcript_file,
      lines: transcript.lines.count
    )

    file_system.write(transcript_file, transcript)

    :written
  rescue => e
    @logger.error("Failed to write transcript file", error: e.message)
    :failed
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
    # Both branches auto-inject the subagent-spawning zimmer server
    # for a root with resolved default_subagent_roots: the prepare! path does it
    # in RuntimeConfigPostProcessor#post_process!, and the baseline path in
    # #ensure_baseline!. So a subagent-roots-only root (blank mcp_servers +
    # skills + hooks + plugins) that lands in the else branch keeps its only
    # start_session server across regeneration. The injection decision lives
    # entirely in the post-processor (keyed on the resolved
    # default_subagent_roots), so this branch needs no subagent check.
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

    # An unarchive regenerates .mcp.json from scratch, so it can narrow the
    # session's toolset just as a mid-run recreation can. Make that loud.
    detect_lost_mcp_servers(session, air_service.injected_mcp_servers, context: "unarchive")

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
  # Trigger#resuscitate_session!. See issues pulsemcp/pulsemcp#3720 and pulsemcp/pulsemcp#4600.
  #
  # @param log_message [String] what the session's own timeline says about the
  #   restore. The default describes a resume; #restore_never_started passes the
  #   never-started wording, because telling a human their session came back
  #   "with full state restoration" when there was no state is a lie.
  # @param also_clear [Array<String>] extra metadata keys to drop in the same
  #   locked write. #restore_never_started passes Session::SETUP_ARTIFACT_KEYS:
  #   a spawn that never completed leaves a clone_path that was never finished
  #   and has almost certainly been reaped since, and the fresh start must clone
  #   rather than trust it.
  def transition_to_needs_input(log_message: "Session unarchived with full state restoration - ready for follow-up prompts", also_clear: [])
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
        # pulsemcp/pulsemcp#3720's guard-ordering protects. See
        # pulsemcp/pulsemcp#3720 and pulsemcp/pulsemcp#4600.
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
          *Session::STALE_RETRY_METADATA_KEYS,
          *also_clear
        )
        session.update!(archived_at: nil, metadata: cleaned_metadata)

        # Always transition to needs_input regardless of the session's
        # pre-archive status. This is intentional: the user wants to continue
        # the conversation, so we put the session in a state where they can
        # immediately send follow-up prompts. If the session originally failed,
        # the user can still see the failure in the transcript and choose how
        # to proceed.
        session.unarchive_to_needs_input!

        session.logs.create!(content: log_message, level: "info")
      end
    end

    Result.new(success?: true)
  rescue => e
    @logger.error("Failed to transition session state", error: e.message)
    Result.new(success?: false, error: "Failed to transition session state: #{e.message}")
  end
end
