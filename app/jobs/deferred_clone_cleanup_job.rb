# frozen_string_literal: true

# Job to clean up a session's git clone after the undo window expires.
#
# When a session is archived, this job runs after a delay (default: 10 seconds)
# to allow the user to click "Undo" within the 5-second window.
#
# Before deleting the clone, the job checks for unpushed state (uncommitted changes
# or unpushed commits). If found, lightweight artifacts are preserved for
# SessionStateMachine::TRASH_RETENTION_PERIOD (4 days) so they can be restored on
# unarchive. Clean clones are deleted immediately with no retention period.
#
# This job only reaps the clone. The session's scratch directory and prompt
# attachments are held for the full reversible window and reaped by EmptyTrashJob
# — see DurableSessionStorage for why.
#
# The job checks that:
# 1. The session is still archived (not undone)
# 2. The archived_at timestamp matches what was set when we scheduled the job
#    (to prevent deleting a clone from a re-archived session that shouldn't be cleaned yet)
#
class DeferredCloneCleanupJob < ApplicationJob
  include DatabaseRetry
  include DurableSessionStorage
  queue_as :default

  # Delay before cleanup runs (should be longer than the undo window)
  CLEANUP_DELAY = 10.seconds

  # @param session_id [Integer] the ID of the session to clean up
  # @param archived_at [String] ISO8601 timestamp of when the session was archived
  def perform(session_id, archived_at)
    session = Session.find_by(id: session_id)

    unless session
      Rails.logger.info "[DeferredCloneCleanupJob] Session #{session_id} not found, skipping cleanup"
      return
    end

    # Check if session is still archived
    unless session.archived?
      Rails.logger.info "[DeferredCloneCleanupJob] Session #{session_id} is no longer archived (status: #{session.status}), skipping cleanup"
      return
    end

    # Check if the archived_at timestamp matches (to handle re-archive scenarios)
    begin
      original_archived_at = Time.iso8601(archived_at)
    rescue ArgumentError => e
      Rails.logger.warn "[DeferredCloneCleanupJob] Failed to parse archived_at timestamp '#{archived_at}' for session #{session_id}: #{e.message}"
      original_archived_at = nil
    end
    current_archived_at = session.archived_at

    # If we can't parse the original timestamp or session has no archived_at, skip cleanup
    unless original_archived_at && current_archived_at
      Rails.logger.info "[DeferredCloneCleanupJob] Session #{session_id} has invalid timestamps, skipping cleanup (original: #{archived_at}, current: #{current_archived_at&.iso8601})"
      return
    end

    # Allow 1 second tolerance for time comparison
    unless (current_archived_at - original_archived_at).abs < 1.second
      Rails.logger.info "[DeferredCloneCleanupJob] Session #{session_id} was re-archived, skipping cleanup (original: #{archived_at}, current: #{current_archived_at.iso8601})"
      return
    end

    # The scratch directory and prompt attachments are deliberately NOT touched
    # here. Only the clone is reconstructable at the end of the undo window;
    # that state is not, and unarchive has nothing to restore it from. It is
    # held for the reversible window and reaped by EmptyTrashJob at the trash
    # deadline instead — see DurableSessionStorage.

    # Perform the actual cleanup
    clone_path = session.metadata&.dig("clone_path")

    unless clone_path && File.directory?(clone_path)
      Rails.logger.info "[DeferredCloneCleanupJob] Session #{session_id} has no clone to clean up"
      finalize_trash_expiry(session)
      return
    end

    # Check for unpushed artifacts and preserve them before deleting clone
    artifact_service = CloneArtifactService.new
    dirty_result = artifact_service.check_dirty_state(clone_path)
    artifacts_preserved = false

    if dirty_result.dirty?
      Rails.logger.info "[DeferredCloneCleanupJob] Session #{session_id} has unpushed state: #{dirty_result.details}"

      create_result = artifact_service.create_artifacts(session_id: session.id, clone_path: clone_path)

      if create_result.success?
        artifacts_preserved = true
        Rails.logger.info "[DeferredCloneCleanupJob] Preserved artifacts for session #{session_id}"

        # Set trash_after and store artifacts path in a single DB update to avoid race conditions
        with_db_retry do
          new_metadata = (session.reload.metadata || {})
            .merge("artifacts_path" => create_result.artifacts_path)
            .merge(mangled_clone_metadata(create_result))
          session.update_columns(
            trash_after: trash_deadline_for(session),
            metadata: new_metadata
          )
        end
      else
        Rails.logger.error "[DeferredCloneCleanupJob] Failed to preserve artifacts for session #{session_id}: #{create_result.error}"
        # Keep clone intact so EmptyTrashJob can retry after trash_after expires
        Rails.logger.info "[DeferredCloneCleanupJob] Keeping clone for session #{session_id} — artifact creation failed, EmptyTrashJob will handle cleanup"
        return
      end
    else
      Rails.logger.info "[DeferredCloneCleanupJob] Session #{session_id} is clean, no artifacts to preserve"
      finalize_trash_expiry(session)
    end

    # Tear down Docker Compose resources before removing the clone directory.
    # This must happen first because the compose file lives inside the clone.
    docker_cleaned = begin
      DockerComposeCleanupService.cleanup(clone_path)
    rescue => e
      Rails.logger.error "[DeferredCloneCleanupJob] Docker cleanup raised unexpectedly: #{e.class} - #{e.message}"
      false
    end

    GitCloneService.cleanup_clone(clone_path)
    Rails.logger.info "[DeferredCloneCleanupJob] Cleaned up clone for session #{session_id}: #{clone_path}"

    cleanup_message = if artifacts_preserved
      "Clone deleted after preserving unpushed artifacts (#{dirty_result.details})"
    else
      "Clone deleted (no unpushed state)"
    end
    cleanup_message += " — Docker resources also removed" if docker_cleaned

    with_db_retry do
      session.logs.create!(
        content: cleanup_message,
        level: "info"
      )
    end
  rescue => e
    Rails.logger.error "[DeferredCloneCleanupJob] Error cleaning up session #{session_id}: #{e.class} - #{e.message}"
    Rails.logger.error "Backtrace: #{e.backtrace.first(5).join("\n")}" if e.backtrace
    raise # Re-raise to trigger job retry
  end

  private

  # Durable record that this session's clone was mangled and the archive-side
  # guard defused it. The refusal itself only logs at .warn now (#415) — this is
  # what keeps the *rate* countable, in SQL, after the log line has aged out:
  # MangledCloneReportJob aggregates these daily, and it is the standing evidence
  # for #412, the non-atomic clone delete that mangles the trees in the first
  # place. Nothing is written when the guard did not fire, so the marker's
  # presence is itself the signal.
  def mangled_clone_metadata(create_result)
    dropped = create_result.dropped_deletions.to_i
    return {} unless dropped.positive?

    {
      "mangled_clone_dropped_deletions" => dropped,
      # .utc, so the stamp is comparable in SQL regardless of what
      # config.time_zone is set to when it is written.
      "mangled_clone_defused_at" => Time.current.utc.iso8601
    }
  end

  # Decide whether this session still needs a trash deadline once the clone is
  # gone. trash_after is what makes EmptyTrashJob find the session later and
  # what keeps StaleCloneCleanupJob's one-hour sweep off it, so it may only be
  # cleared when nothing restorable is left on disk. A scratch directory or
  # prompt attachments outlive the undo window, so they hold the deadline open
  # for the full reversible window even when the clone was clean.
  def finalize_trash_expiry(session)
    with_db_retry do
      if durable_session_storage_exists?(session.id)
        session.update_column(:trash_after, trash_deadline_for(session))
      else
        session.update_column(:trash_after, nil)
      end
    end
  end

  # The retention window runs from the archive, not from whenever this job got
  # to run. Normally that is a ten-second difference, but a backed-up queue or a
  # retried job would otherwise silently extend retention past the deadline the
  # session was told about (see OrchestratorSystemPromptBuilder#durable_scratch_line).
  def trash_deadline_for(session)
    (session.archived_at || Time.current) + SessionStateMachine::TRASH_RETENTION_PERIOD
  end
end
