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
  include SingletonSweep

  # Only clean clones older than 48 hours to avoid racing with active sessions
  AGE_THRESHOLD = 48.hours

  # Age bar for the disk-pressure path. See the class comment for why lowering it
  # this far and no further is safe.
  PRESSURE_AGE_THRESHOLD = 2.hours

  # Maximum clones to clean per run to avoid long-running jobs
  BATCH_LIMIT = 20

  # Cap for the disk-pressure path. Deliberately not much higher than
  # BATCH_LIMIT: this path runs synchronously on the session launch path, and
  # `cleanup_orphan` tears down Docker Compose resources first, which is bounded
  # at DockerComposeCleanupService::COMPOSE_DOWN_TIMEOUT (120s) *per directory*.
  PRESSURE_BATCH_LIMIT = 20

  # Wall-clock budget for the whole pressure sweep, checked before each removal.
  # Without it, 20 orphans that each need a full compose teardown would block the
  # calling thread for 40 minutes — with the session wedged in `waiting`, holding
  # its GoodJob lock and still looking alive to orphan detection, which is the
  # exact failure mode GIT_CLONE_TIMEOUT_SECONDS and BoundedSubprocess exist to
  # prevent on this code path. The check is at the top of each iteration, so the
  # true bound is this budget plus one directory's teardown.
  RECLAIM_BUDGET_SECONDS = 60

  # The deployments that own the durable `zimmer_data` volume, and so are the
  # only ones allowed to reap inside it. Mirrors
  # StaleCloneCleanupJob::SWEEPS_DEFAULT_DURABLE_ROOT — see #reclaimable_root?.
  SWEEPS_DEFAULT_DURABLE_ROOT = %w[production staging].freeze

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
    return unless reclaimable_root?(clones_base)

    # Reap first: a tombstone is a clone whose delete was interrupted between the
    # rename and the recursive unlink (#412). It is doomed by construction, so
    # there is nothing to weigh — take the bytes back before considering anything
    # a session might still own.
    AtomicCloneRemoval.reap_tombstones(clones_base)

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
    return 0 unless reclaimable_root?(clones_base)

    starting_free = CloneDiskGuard.available_bytes(clones_base)

    # The cheapest bytes on the volume: a tombstone is a clone whose delete was
    # interrupted (#412) and that no session can ever want back, so it is taken
    # before any directory that needs an ownership argument made for it.
    reaped = AtomicCloneRemoval.reap_tombstones(clones_base)
    if reaped > 0 && (free_now = CloneDiskGuard.available_bytes(clones_base)) && free_now >= target_free_bytes
      freed = starting_free ? [ free_now - starting_free, 0 ].max : 0
      Rails.logger.info "[OrphanCloneFilesystemCleanupJob] Reclaimed #{freed} bytes from #{reaped} " \
        "interrupted-delete tombstones; no orphan clones needed removing"
      return freed
    end

    orphans = find_orphan_directories(clones_base, cutoff: PRESSURE_AGE_THRESHOLD.ago)

    if orphans.empty?
      # Still report what the reap freed. This method's contract is "bytes freed",
      # and answering 0 after deleting tombstones would tell both the caller and the
      # operator that nothing was reclaimed.
      freed = bytes_freed_since(starting_free, clones_base)
      Rails.logger.warn "[OrphanCloneFilesystemCleanupJob] Disk pressure on #{clones_base} " \
        "but no orphaned clones are eligible for reclamation " \
        "(#{reaped} interrupted-delete tombstone(s) reaped, #{freed} bytes freed)"
      return freed
    end

    deadline = monotonic_now + RECLAIM_BUDGET_SECONDS
    cleaned = 0

    orphans.first(PRESSURE_BATCH_LIMIT).each do |dir_path|
      if monotonic_now >= deadline
        Rails.logger.warn "[OrphanCloneFilesystemCleanupJob] Reclamation budget of " \
          "#{RECLAIM_BUDGET_SECONDS}s exhausted after #{cleaned} removals; the rest wait for the " \
          "scheduled sweep"
        break
      end

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

    freed = bytes_freed_since(starting_free, clones_base)

    Rails.logger.info "[OrphanCloneFilesystemCleanupJob] Reclaimed #{freed} bytes from " \
      "#{cleaned} orphan clones under disk pressure"

    freed
  end

  private

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Bytes the volume gave back since `starting_free`, measured against the volume
  # rather than summed from the deleted directories. Zero when either probe failed.
  def bytes_freed_since(starting_free, clones_base)
    ending_free = CloneDiskGuard.available_bytes(clones_base)
    return 0 unless starting_free && ending_free

    [ ending_free - starting_free, 0 ].max
  end

  # Whether this deployment is allowed to delete from `clones_base` at all.
  #
  # The hazard is a process whose database does not describe the volume it is
  # looking at: `bin/rails test` runs against `zimmer_test` and `bin/dev` against
  # `zimmer_development`, but both resolve the clones base to `~/.zimmer/clones`
  # — which on a machine that also hosts a real Zimmer is the volume holding live
  # sessions' working directories. Orphan-hood here is a set difference against
  # the *connected* database, so against the wrong one every live clone looks
  # like an orphan. Same fence, same reasoning, as
  # StaleCloneCleanupJob#sweepable_root?.
  #
  # A relocated clones base (AGENT_CLONES_DIR pointed clear of the durable
  # volume) is sweepable anywhere, which is what the tests do and what a
  # developer with a private data dir gets for free.
  def reclaimable_root?(clones_base)
    return true if SWEEPS_DEFAULT_DURABLE_ROOT.include?(Rails.env)
    return true unless inside_default_durable_root?(clones_base)

    Rails.logger.warn "[OrphanCloneFilesystemCleanupJob] Refusing to reap #{clones_base}: it is " \
      "inside the durable volume and #{Rails.env} is not the deployment that owns it"
    false
  end

  # Derived from the *default* location (`~/.zimmer`), not from
  # ClonesDirectory.base. Deriving it from the configured base would make the
  # check degenerate — a path is always inside its own parent — so a relocated
  # base would fence itself and the real durable volume would not be recognized.
  def inside_default_durable_root?(path)
    durable_root = File.join(File.expand_path("~"), ClonesDirectory::DEFAULT_HOME_SUBDIR)
    expanded = File.expand_path(path)

    expanded == durable_root || expanded.start_with?("#{durable_root}#{File::SEPARATOR}")
  end

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
      # A tombstone is not a clone — it is a clone being deleted right now, or one
      # whose delete was interrupted. Either way it belongs to reap_tombstones,
      # not to a sweep that reasons about session ownership and age.
      next if AtomicCloneRemoval.tombstone?(entry)
      next if tracked_paths.include?(entry)
      next if live_paths.include?(File.expand_path(full_path))

      # Stat once and carry the mtime through to the sort: a second stat is a
      # second race window against a directory another reaper may have removed
      # in between.
      mtime = File.mtime(full_path)
      next if mtime > cutoff

      [ full_path, mtime ]
    rescue Errno::ENOENT
      # Removed underneath us by another reaper. Not ours to report on.
      next
    end.sort_by(&:last).map(&:first) # oldest first
  end

  def cleanup_orphan(dir_path)
    # Tear down Docker Compose resources first
    DockerComposeCleanupService.cleanup(dir_path)

    # Rename aside, then delete: an interrupted sweep must not leave a half-tree
    # wearing a clone's name (#412).
    AtomicCloneRemoval.remove(dir_path)
    Rails.logger.info "[OrphanCloneFilesystemCleanupJob] Removed orphan clone: #{File.basename(dir_path)}"
  end
end
