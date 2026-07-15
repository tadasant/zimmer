# frozen_string_literal: true

# Safety-net job for clones and artifacts that slipped through the trash system.
#
# Normally, DeferredCloneCleanupJob handles clone deletion after the undo window
# and EmptyTrashJob handles artifact cleanup after the retention period expires.
# This job catches edge cases where trash_after was never set (e.g., set_trash_expiry
# failed) or legacy archived sessions from before the trash system was introduced.
#
# Also cleans up clones from failed sessions that have been abandoned. Failed sessions
# never enter the trash pipeline (only archived sessions do), so without this job
# their clones accumulate indefinitely on disk.
#
# Sessions with a non-nil trash_after are SKIPPED — they belong to EmptyTrashJob.
#
# Additionally performs a filesystem-level orphan sweep: lists all directories in
# the clones directory and deletes any not referenced by an active session's
# clone_path metadata. This catches directories whose session metadata was cleared
# before the directory was deleted.
#
class StaleCloneCleanupJob < ApplicationJob
  include DatabaseRetry
  queue_as :default

  # Grace period before considering an archived clone "stale" and eligible for cleanup
  # This should be much longer than the undo window + deferred cleanup delay
  # to avoid racing with DeferredCloneCleanupJob
  STALE_THRESHOLD = 1.hour

  # Grace period before cleaning failed session clones. Longer than the archived
  # threshold because users may resume failed sessions. 24 hours gives ample time
  # to investigate and retry before the clone is reclaimed.
  FAILED_SESSION_STALE_THRESHOLD = 24.hours

  # Minimum age before an unreferenced directory is considered orphaned.
  # Prevents racing with session startup (clone created but metadata not yet persisted).
  ORPHAN_AGE_THRESHOLD = 1.hour

  def perform
    cleaned_count = 0
    error_count = 0

    stale_clone_candidate_scopes.each do |scope|
      # Materialize candidate ids with an unordered pluck rather than find_each.
      # find_each imposes an implicit ORDER BY id ASC for cursor batching, and the
      # planner satisfies that order with a free primary-key scan — filtering the
      # entire sessions table instead of using the partial indexes that back these
      # scopes. The unordered pluck lets the planner pick the partial index, turning
      # a multi-second full scan into a sub-millisecond index scan. Candidate counts
      # here are tiny (stale clones), so loading the ids up front is cheap.
      scope.pluck(:id).each do |session_id|
        session = Session.find_by(id: session_id)
        next unless session

        begin
          if cleanup_session_clone(session)
            cleaned_count += 1
          end
        rescue => e
          error_count += 1
          Rails.logger.error "[StaleCloneCleanupJob] Failed to clean clone for session #{session_id}: #{e.class} - #{e.message}"
        end
      end
    end

    orphan_result = sweep_orphaned_clones
    cleaned_count += orphan_result[:cleaned]
    error_count += orphan_result[:errors]

    if cleaned_count > 0 || error_count > 0
      Rails.logger.info "[StaleCloneCleanupJob] Completed: cleaned #{cleaned_count} clones, #{error_count} errors"
    end
  end

  private

  def stale_clone_candidate_scopes
    [
      archived_sessions_with_stale_clones,
      legacy_archived_sessions_with_stale_clones,
      failed_sessions_with_stale_clones
    ]
  end

  def archived_sessions_with_stale_clones
    Session
      .where(status: :archived)
      .where(trash_after: nil)
      .where("metadata->>'clone_path' IS NOT NULL")
      .where("archived_at < ?", STALE_THRESHOLD.ago)
  end

  def legacy_archived_sessions_with_stale_clones
    Session
      .where(status: :archived)
      .where(trash_after: nil)
      .where(archived_at: nil)
      .where("updated_at < ?", STALE_THRESHOLD.ago)
      .where("metadata->>'clone_path' IS NOT NULL")
  end

  # Failed sessions have no dedicated timestamp, so use updated_at as a proxy.
  # A failed session untouched for 24+ hours is considered abandoned.
  def failed_sessions_with_stale_clones
    Session
      .where(status: :failed)
      .where("updated_at < ?", FAILED_SESSION_STALE_THRESHOLD.ago)
      .where("metadata->>'clone_path' IS NOT NULL")
  end

  # Returns true if any resources were actually cleaned up on disk.
  def cleanup_session_clone(session)
    cleaned_anything = false

    clone_path = session.metadata&.dig("clone_path")
    if clone_path.present? && File.directory?(clone_path)
      GitCloneService.cleanup_clone(clone_path)
      Rails.logger.info "[StaleCloneCleanupJob] Cleaned stale clone for session #{session.id}: #{clone_path}"
      cleaned_anything = true
    end

    # Reclaim the durable per-session scratch directory alongside the clone.
    # It holds only reconstructable cross-step state, so delete it outright.
    if Dir.exist?(SessionScratchDirectory.path_for(session.id))
      SessionScratchDirectory.cleanup_for(session.id)
      Rails.logger.info "[StaleCloneCleanupJob] Cleaned stale scratch dir for session #{session.id}"
      cleaned_anything = true
    end

    # Reclaim durable prompt-attachment storage (files + images) on the same
    # lifecycle. It now lives on the shared ~/.zimmer volume (see
    # FileStorageService.storage_root), so it is no longer wiped by container
    # recreation and must be reaped explicitly or it accumulates forever.
    if attachments_exist?(session.id)
      FileStorageService.cleanup_for(session.id)
      ImageStorageService.cleanup_for(session.id)
      Rails.logger.info "[StaleCloneCleanupJob] Cleaned stale prompt attachments for session #{session.id}"
      cleaned_anything = true
    end

    artifact_service = CloneArtifactService.new
    if artifact_service.cleanup_artifacts(session.id)
      Rails.logger.info "[StaleCloneCleanupJob] Cleaned stale artifacts for session #{session.id}"
      cleaned_anything = true
    end

    return false unless cleaned_anything

    with_db_retry do
      session.logs.create!(
        content: "Stale resources cleaned up by periodic job",
        level: "info"
      )
    end

    true
  end

  # Whether any durable prompt-attachment storage exists for the session.
  def attachments_exist?(session_id)
    Dir.exist?(FileStorageService.new(session_id: session_id).session_dir) ||
      Dir.exist?(ImageStorageService.new(session_id: session_id).session_dir)
  rescue ArgumentError
    false
  end

  # Filesystem-level sweep: finds clone directories not referenced by any active
  # session and removes them. This catches orphaned directories whose session
  # metadata was cleared before the directory was deleted.
  def sweep_orphaned_clones
    cleaned = 0
    errors = 0
    skipped_referenced = 0

    clones_base = clones_directory
    unless clones_base && File.directory?(clones_base)
      return { cleaned: cleaned, errors: errors, skipped_referenced: skipped_referenced }
    end

    active_clone_paths = active_session_clone_paths
    # Hard, age-independent guard: clones of live (non-terminal) sessions are
    # NEVER swept, no matter how old. A session can idle in needs_input for weeks
    # and still be resumed expecting its filesystem intact.
    live_clone_paths = Session.live_clone_paths
    # Normalization-immune catch-all, keyed by globally-unique basename
    # (timestamp + random suffix). The orphan sweep exists to remove directories
    # that NO session owns, so a directory ANY session still references — in any
    # status — must never be swept here; stale clones of terminal sessions are
    # reclaimed by the dedicated DB-driven scopes above (which apply the correct
    # grace window and write a durable per-session log). Guarding on basename for
    # every referencing session (not just live ones, and not just by path) closes
    # the gap where a stored clone_path can't be reconciled with the scan path by
    # File.expand_path — e.g. a symlinked clones base or a path stored under a
    # different/relocated base. A basename match reliably identifies the same
    # clone because clone names are globally unique.
    referenced_owners = referenced_clone_owners_by_basename
    cutoff = ORPHAN_AGE_THRESHOLD.ago

    Dir.children(clones_base).each do |entry|
      full_path = File.join(clones_base, entry)
      next unless File.directory?(full_path)

      normalized = File.expand_path(full_path)
      next if live_clone_paths.include?(normalized)
      next if active_clone_paths.include?(normalized)

      # Final, normalization-immune guard. Reaching this point means the path
      # checks above missed a directory that a session still references (its
      # stored clone_path could not be reconciled with the scan path). Deleting
      # it would orphan a session from its working tree, so skip it AND record
      # the near-miss durably: the per-session DB log survives deploys, unlike
      # this job's stdout, so a recurring canonicalization/relocation bug stays
      # visible on the session itself instead of silently destroying its clone.
      if (owner_id = referenced_owners[entry])
        skipped_referenced += 1
        flag_referenced_clone_skip(owner_id, full_path)
        next
      end

      begin
        mtime = File.mtime(full_path)
        next if mtime > cutoff

        GitCloneService.cleanup_clone(full_path)
        Rails.logger.info "[StaleCloneCleanupJob] Swept orphaned clone directory: #{full_path} (mtime: #{mtime.iso8601})"
        cleaned += 1
      rescue => e
        errors += 1
        Rails.logger.error "[StaleCloneCleanupJob] Failed to sweep orphaned clone #{full_path}: #{e.class} - #{e.message}"
      end
    end

    if cleaned > 0
      Rails.logger.info "[StaleCloneCleanupJob] Orphan sweep: removed #{cleaned} directories"
    end

    { cleaned: cleaned, errors: errors, skipped_referenced: skipped_referenced }
  end

  # Maps every session-referenced clone directory's basename to its owning
  # session id (across ALL statuses). Basenames are globally unique (timestamp +
  # random suffix), so this is an unambiguous, path-normalization-immune lookup
  # for "is this directory still owned by a session?".
  def referenced_clone_owners_by_basename
    Session
      .where("metadata->>'clone_path' IS NOT NULL")
      .pluck(:id, Arel.sql("metadata->>'clone_path'"))
      .each_with_object({}) do |(id, path), map|
        next if path.blank?
        # First writer wins; a basename collision is effectively impossible, so
        # the chosen id is deterministic enough for the durable flag below.
        map[File.basename(path)] ||= id
      end
  end

  # Records a durable, attributable warning when the orphan sweep was about to
  # delete a directory still referenced by a session. This is a guard-gap
  # tripwire: under normal operation the path guards catch referenced clones and
  # this never fires.
  def flag_referenced_clone_skip(owner_id, full_path)
    Rails.logger.warn "[StaleCloneCleanupJob] Orphan sweep skipped #{full_path}: still referenced by session #{owner_id} " \
      "(stored clone_path could not be reconciled with the scan path by File.expand_path; matched by basename)"

    session = Session.find_by(id: owner_id)
    return unless session

    with_db_retry do
      session.logs.create!(
        level: "warning",
        content: "Orphan sweep skipped deleting this session's clone directory (#{File.basename(full_path)}); " \
          "its stored clone_path did not match the scan path and was only caught by the unique-basename guard. " \
          "Investigate clone_path canonicalization."
      )
    end
  rescue => e
    # Never let the durable-flag write break the sweep; the stdout WARN above
    # still fired.
    Rails.logger.error "[StaleCloneCleanupJob] Failed to record referenced-clone skip for session #{owner_id}: #{e.class} - #{e.message}"
  end

  # All clone_path values from sessions that might still need their clone.
  # Includes failed sessions (which have a 24-hour grace period before cleanup)
  # and archived sessions still in the trash pipeline (managed by EmptyTrashJob).
  def active_session_clone_paths
    actively_used = Session
      .where(status: [ :waiting, :running, :needs_input, :failed ])
      .where("metadata->>'clone_path' IS NOT NULL")

    in_trash_pipeline = Session
      .where(status: :archived)
      .where.not(trash_after: nil)
      .where("metadata->>'clone_path' IS NOT NULL")

    actively_used.or(in_trash_pipeline)
      .pluck(Arel.sql("metadata->>'clone_path'"))
      .compact
      .map { |p| File.expand_path(p) }
      .to_set
  end

  # Settable for testing — allows tests to inject a temp directory
  class_attribute :clones_directory_override, default: nil

  def clones_directory
    return self.class.clones_directory_override if self.class.clones_directory_override

    # Single source of truth shared with every clone writer and reaper.
    # The orphan sweep guards on File.directory? before using this, so returning
    # a not-yet-created path is harmless.
    ClonesDirectory.base
  end
end
