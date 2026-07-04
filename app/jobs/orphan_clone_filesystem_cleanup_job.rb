# frozen_string_literal: true

# Safety-net job that scans the filesystem for clone directories that have no
# matching session in the database.
#
# The primary clone cleanup pipeline is DB-driven (DeferredCloneCleanupJob,
# EmptyTrashJob, StaleCloneCleanupJob), but orphan directories can accumulate
# when:
#   - A session is deleted from the DB but its clone directory persists
#   - A clone was created but the session failed before recording the path in metadata
#   - Docker Compose resources were started but not torn down
#
# This job walks the clones directory, checks each against the DB, and removes
# any directory older than the grace period that has no active session.
#
class OrphanCloneFilesystemCleanupJob < ApplicationJob
  queue_as :default

  # Only clean clones older than 48 hours to avoid racing with active sessions
  AGE_THRESHOLD = 48.hours

  # Maximum clones to clean per run to avoid long-running jobs
  BATCH_LIMIT = 20

  def perform
    clones_base = ClonesDirectory.base
    return unless File.directory?(clones_base)

    orphans = find_orphan_directories(clones_base)
    cleaned = 0

    orphans.first(BATCH_LIMIT).each do |dir_path|
      cleanup_orphan(dir_path)
      cleaned += 1
    rescue StandardError => e
      Rails.logger.error "[OrphanCloneFilesystemCleanupJob] Failed to clean #{File.basename(dir_path)}: #{e.class} - #{e.message}"
    end

    if cleaned > 0 || orphans.size > BATCH_LIMIT
      Rails.logger.info "[OrphanCloneFilesystemCleanupJob] Cleaned #{cleaned} orphan clones" \
        "#{orphans.size > BATCH_LIMIT ? " (#{orphans.size - BATCH_LIMIT} remaining)" : ""}"
    end
  end

  private

  def find_orphan_directories(clones_base)
    # Get all clone directory names
    entries = Dir.entries(clones_base).reject { |e| e.start_with?(".") }

    # Get all clone paths tracked by ANY session (orphans are directories with no
    # owning session row at all).
    tracked_paths = Session
      .where("metadata->>'clone_path' IS NOT NULL")
      .pluck(Arel.sql("metadata->>'clone_path'"))
      .compact
      .map { |p| File.basename(p) }
      .to_set

    # Hard, age-independent guard: never touch a clone owned by a live
    # (non-terminal) session, regardless of age. Belt-and-suspenders alongside
    # the tracked_paths check above.
    live_paths = Session.live_clone_paths

    cutoff = AGE_THRESHOLD.ago

    entries.filter_map do |entry|
      full_path = File.join(clones_base, entry)
      next unless File.directory?(full_path)
      next if tracked_paths.include?(entry)
      next if live_paths.include?(File.expand_path(full_path))

      # Check directory age via mtime
      mtime = File.mtime(full_path)
      next if mtime > cutoff

      full_path
    end.sort_by { |p| File.mtime(p) } # oldest first
  end

  def cleanup_orphan(dir_path)
    # Tear down Docker Compose resources first
    DockerComposeCleanupService.cleanup(dir_path)

    # Remove the directory
    FileUtils.rm_rf(dir_path)
    Rails.logger.info "[OrphanCloneFilesystemCleanupJob] Removed orphan clone: #{File.basename(dir_path)}"
  end
end
