# frozen_string_literal: true

# Periodically cleans up expired artifacts and any remaining clones for trashed sessions.
#
# When a session is archived, DeferredCloneCleanupJob runs after the undo window to:
# - Delete the clone immediately if clean (no unpushed state)
# - Preserve lightweight artifacts and delete the clone if dirty
#
# This job handles the second phase: permanently deleting preserved artifacts
# after the retention period expires (default: 14 days). It also cleans up
# any clones that somehow survived (belt-and-suspenders).
#
# Runs every hour via GoodJob cron.
class EmptyTrashJob < ApplicationJob
  include DatabaseRetry
  queue_as :default

  def perform
    expired_sessions = Session.where(status: :archived)
                              .where.not(trash_after: nil)
                              .where("trash_after <= ?", Time.current)

    cleaned_count = 0

    expired_sessions.find_each do |session|
      cleaned = cleanup_session(session)
      cleaned_count += 1 if cleaned
    rescue => e
      Rails.logger.error "[EmptyTrashJob] Failed to clean up session #{session.id}: #{e.class} - #{e.message}"
      # Continue with other sessions
    end

    Rails.logger.info "[EmptyTrashJob] Cleaned up #{cleaned_count} expired trashed session(s)" if cleaned_count > 0
  end

  private

  def cleanup_session(session)
    cleaned_anything = false
    cleanup_details = []

    # Clean up artifacts if they exist
    artifact_service = CloneArtifactService.new
    if artifact_service.cleanup_artifacts(session.id)
      cleaned_anything = true
      cleanup_details << "artifacts deleted"
    end

    # Also clean up clone if it somehow still exists (belt-and-suspenders)
    clone_path = session.metadata&.dig("clone_path")
    if clone_path && File.directory?(clone_path)
      docker_cleaned = begin
        DockerComposeCleanupService.cleanup(clone_path)
      rescue => e
        Rails.logger.error "[EmptyTrashJob] Docker cleanup raised for session #{session.id}: #{e.class} - #{e.message}"
        false
      end

      GitCloneService.cleanup_clone(clone_path)
      cleaned_anything = true
      cleanup_details << "clone deleted"
      cleanup_details << "Docker resources removed" if docker_cleaned
    end

    # Clear trash_after and artifacts_path from metadata
    with_db_retry do
      if session.metadata&.dig("artifacts_path").present?
        new_metadata = session.metadata.except("artifacts_path")
        session.update_columns(trash_after: nil, metadata: new_metadata)
      else
        session.update_column(:trash_after, nil)
      end
    end

    if cleaned_anything
      with_db_retry do
        session.logs.create!(
          content: "Permanent cleanup: #{cleanup_details.join(', ')} (retention expired)",
          level: "info"
        )
      end
    else
      Rails.logger.info "[EmptyTrashJob] Session #{session.id} has nothing to clean up"
      # Still return false since nothing was actually cleaned
    end

    cleaned_anything
  end
end
