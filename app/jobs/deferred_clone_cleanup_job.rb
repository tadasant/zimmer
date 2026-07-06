# frozen_string_literal: true

# Job to clean up a session's git clone after the undo window expires.
#
# When a session is archived, this job runs after a delay (default: 10 seconds)
# to allow the user to click "Undo" within the 5-second window.
#
# Before deleting the clone, the job checks for unpushed state (uncommitted changes
# or unpushed commits). If found, lightweight artifacts are preserved for 14 days
# so they can be restored on unarchive. Clean clones are deleted immediately with
# no retention period.
#
# The job checks that:
# 1. The session is still archived (not undone)
# 2. The archived_at timestamp matches what was set when we scheduled the job
#    (to prevent deleting a clone from a re-archived session that shouldn't be cleaned yet)
#
class DeferredCloneCleanupJob < ApplicationJob
  include DatabaseRetry
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

    # Reclaim the durable per-session scratch directory. It holds only
    # reconstructable cross-step state, so it is deleted outright (not preserved
    # like clone artifacts). Runs whenever we've committed to reaping this
    # archived session, regardless of which clone-cleanup path is taken below.
    SessionScratchDirectory.cleanup_for(session_id)

    # Perform the actual cleanup
    clone_path = session.metadata&.dig("clone_path")

    unless clone_path && File.directory?(clone_path)
      Rails.logger.info "[DeferredCloneCleanupJob] Session #{session_id} has no clone to clean up"
      # Clear trash_after since there's nothing to preserve
      session.update_column(:trash_after, nil)
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
          new_metadata = (session.reload.metadata || {}).merge("artifacts_path" => create_result.artifacts_path)
          session.update_columns(
            trash_after: SessionStateMachine::TRASH_RETENTION_PERIOD.from_now,
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
      # No artifacts needed — clear trash_after since there's nothing to retain
      with_db_retry do
        session.update_column(:trash_after, nil)
      end
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
end
