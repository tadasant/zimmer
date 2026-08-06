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
# Two entry points, one set of safety rules
# -----------------------------------------
#   * #perform — the hourly scheduled sweep. Patient: AGE_THRESHOLD (48h),
#     BATCH_LIMIT (20).
#   * .reclaim_space — called by CloneDiskGuard when a clone is about to fail for
#     want of disk. Urgent: PRESSURE_AGE_THRESHOLD (2h), PRESSURE_BATCH_LIMIT
#     (100), and it stops as soon as the volume has enough free space.
#
# The urgent path lowers *only* the age bar and the batch cap. Every other guard
# is shared, because the failure mode of a pruner that is wrong — deleting a live
# session's working directory — is far worse than the disk pressure it relieves:
#
#   * A directory tracked by ANY session row's `clone_path` metadata is never
#     touched, whatever that session's status. Only directories with no owning
#     row at all are candidates.
#   * A directory owned by a live (non-terminal) session is never touched, as a
#     second, age-independent check (Session.live_clone_paths).
#   * The age bar never goes below PRESSURE_AGE_THRESHOLD, which exists to cover
#     the startup race where a clone directory exists but its owning session has
#     not yet persisted `clone_path`. That window is bounded by the clone itself
#     (GIT_CLONE_TIMEOUT_SECONDS, 300s, plus bounded retries — under ten minutes
#     in the worst case), so two hours is more than an order of magnitude of
#     headroom, and is still more conservative than the equivalent sweep in
#     StaleCloneCleanupJob (ORPHAN_AGE_THRESHOLD, 1 hour).
#
class OrphanCloneFilesystemCleanupJob < ApplicationJob
  queue_as :default

  # Only clean clones older than 48 hours to avoid racing with active sessions
  AGE_THRESHOLD = 48.hours

  # Age bar for the disk-pressure path. See the class comment for why lowering it
  # this far and no further is safe.
  PRESSURE_AGE_THRESHOLD = 2.hours

  # Maximum clones to clean per run to avoid long-running jobs
  BATCH_LIMIT = 20

  # Higher cap for the disk-pressure path: this one runs synchronously on the
  # session launch path and stops early once the volume has room, so the cap is
  # only a backstop against an unbounded sweep.
  PRESSURE_BATCH_LIMIT = 100

  # Reclaim disk space on the clones volume by removing orphaned clones, stopping
  # as soon as `target_free_bytes` is available.
  #
  # Takes no directory argument on purpose. The caller supplies a *requirement*,
  # never a target to delete from: this job resolves ClonesDirectory.base itself,
  # so no caller — present or future, correct or confused — can point recursive
  # deletion at a directory that is not the clones root.
  #
  # @param target_free_bytes [Integer] free bytes the caller needs
  # @return [Integer] bytes freed (0 when nothing was reclaimable)
  def self.reclaim_space(target_free_bytes:)
    new.reclaim_space(target_free_bytes: target_free_bytes)
  end

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

  # Instance form of .reclaim_space. Returns the number of bytes freed, measured
  # against the volume rather than summed from the deleted directories, so the
  # figure reported to the caller is the one that actually matters.
  def reclaim_space(target_free_bytes:)
    clones_base = ClonesDirectory.base
    return 0 unless File.directory?(clones_base)

    starting_free = CloneDiskGuard.available_bytes(clones_base)
    orphans = find_orphan_directories(clones_base, cutoff: PRESSURE_AGE_THRESHOLD.ago)

    if orphans.empty?
      Rails.logger.warn "[OrphanCloneFilesystemCleanupJob] Disk pressure on #{clones_base} " \
        "but no orphaned clones are eligible for reclamation"
      return 0
    end

    cleaned = 0
    orphans.first(PRESSURE_BATCH_LIMIT).each do |dir_path|
      begin
        cleanup_orphan(dir_path)
        cleaned += 1
      rescue StandardError => e
        Rails.logger.error "[OrphanCloneFilesystemCleanupJob] Failed to clean #{File.basename(dir_path)}: #{e.class} - #{e.message}"
        next
      end

      current_free = CloneDiskGuard.available_bytes(clones_base)
      break if current_free && current_free >= target_free_bytes
    end

    ending_free = CloneDiskGuard.available_bytes(clones_base)
    freed = if starting_free && ending_free
      [ ending_free - starting_free, 0 ].max
    else
      0
    end

    Rails.logger.info "[OrphanCloneFilesystemCleanupJob] Reclaimed #{freed} bytes from " \
      "#{cleaned} orphan clones under disk pressure"

    freed
  end

  private

  def find_orphan_directories(clones_base, cutoff: AGE_THRESHOLD.ago)
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
