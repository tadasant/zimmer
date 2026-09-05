# frozen_string_literal: true

# Periodically cleans up expired artifacts and any remaining clones for trashed sessions.
#
# When a session is archived, DeferredCloneCleanupJob runs after the undo window to:
# - Delete the clone immediately if clean (no unpushed state)
# - Preserve lightweight artifacts and delete the clone if dirty
#
# This job handles the second phase: permanently deleting preserved artifacts
# after the retention period expires (SessionStateMachine::TRASH_RETENTION_PERIOD,
# 4 days). It also cleans up
# any clones that somehow survived (belt-and-suspenders).
#
# It is also where the session's scratch directory and prompt attachments are
# reaped. That state has no remote to be rebuilt from, so deleting it at the end
# of the undo window would make archive irreversible for it while archive stays
# reversible for everything else — see DurableSessionStorage.
#
# Runs every hour via GoodJob cron.
class EmptyTrashJob < ApplicationJob
  include DatabaseRetry
  include DurableSessionStorage
  queue_as :maintenance
  include SingletonSweep

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

  # Whether `session` is still trash, asked of the database right now rather than
  # taken from the batch this run loaded.
  #
  # Two things move under this job. `find_each` batches a thousand rows at a time
  # and each session costs a Docker Compose teardown plus a recursive delete of a
  # whole working tree, so the status that put a session in the batch can be
  # minutes old by the time its turn comes up. And an unarchive stays `archived`
  # for its whole duration, so a session having a new clone built for it right
  # now still matches this job's scope. `Session.reap_protected?` answers both,
  # and unlike the clone, the scratch directory, Claude config and prompt
  # attachments deleted below have no remote to come back from (#808).
  #
  # Fails closed.
  def still_trash?(session)
    if Session.reap_protected?(session.id)
      Rails.logger.warn "[EmptyTrashJob] Skipping session #{session.id}: it is live, or being unarchived, as " \
        "of now, so the retention deadline that selected it no longer applies"
      return false
    end

    status, trash_after = Session.unscoped.where(id: session.id).pick(:status, :trash_after)
    status = Session.status_label(status)

    unless status == "archived"
      Rails.logger.warn "[EmptyTrashJob] Skipping session #{session.id}: it is #{status || "gone"} now, not " \
        "archived, so its retention no longer applies"
      return false
    end

    # The deadline itself, not just the status. An unarchive followed by a
    # re-archive leaves the row `archived` with a FRESH deadline — which passes
    # a status-only check while being exactly the mid-undo-window state this job
    # exists to wait out. Everything below the clone (scratch, the Claude config
    # dir, prompt attachments, the preserved artifacts) has no remote to come
    # back from, so reaping it early is not recoverable.
    return true if trash_after.present? && trash_after <= Time.current

    Rails.logger.warn "[EmptyTrashJob] Skipping session #{session.id}: its trash deadline is now " \
      "#{trash_after&.iso8601 || "unset"}, so the retention that selected it has not expired"
    false
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.error "[EmptyTrashJob] Could not re-check the status of session #{session.id} " \
      "(#{e.class}: #{e.message}); leaving its resources alone"
    false
  end

  def cleanup_session(session)
    return false unless still_trash?(session)

    cleaned_anything = false
    cleanup_details = []

    # Clean up artifacts if they exist
    artifact_service = CloneArtifactService.new
    if artifact_service.cleanup_artifacts(session.id)
      cleaned_anything = true
      cleanup_details << "artifacts deleted"
    end

    # The retention window is over, so the state that archive held on to for a
    # possible unarchive can go. Re-checked immediately beforehand: this is the
    # unrecoverable half of the cleanup, and `cleanup_artifacts` above walks the
    # filesystem.
    removed = still_trash?(session) ? cleanup_durable_session_storage(session.id) : []
    if removed.any?
      cleaned_anything = true
      cleanup_details.concat(removed)
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

      # Through CloneReaper, which asks who owns this directory *after* the
      # teardown above — bounded at 120s — rather than before it (#808).
      if GitCloneService.cleanup_clone(clone_path, reason: "EmptyTrashJob") != :refused
        cleaned_anything = true
        cleanup_details << "clone deleted"
        cleanup_details << "Docker resources removed" if docker_cleaned
      end
    end

    # Only clear the deadline if it is still the one that selected this session.
    # A re-archive landing during the cleanup above (which walks the filesystem)
    # restarts the four-day window, and wiping the fresh deadline would drop the
    # row into StaleCloneCleanupJob's archived-and-untrashed scope to be reaped
    # unpreserved an hour later — the exact outcome the re-read exists to prevent.
    unless still_trash?(session)
      Rails.logger.warn "[EmptyTrashJob] Session #{session.id} stopped being an expired trash candidate " \
        "mid-cleanup; leaving its trash deadline in place"
      return cleaned_anything
    end

    # Clear trash_after and artifacts_path from metadata
    with_db_retry do
      session.remove_metadata!("artifacts_path") if session.metadata&.dig("artifacts_path").present?
      session.update_column(:trash_after, nil)
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
