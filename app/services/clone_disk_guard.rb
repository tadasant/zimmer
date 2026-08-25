# frozen_string_literal: true

# Pre-clone disk guard for the clones volume.
#
# Every session's working directory is a git clone under ClonesDirectory.base,
# created on the `waiting → running` launch path. Unguarded, a clone into a full
# volume dies partway with whatever errno git happens to surface, leaves a
# half-written directory behind and — because the volume is shared with the
# scratch, attachment and image trees — degrades every other session on the host
# at the same time. The manual remedy for that state is `rm -rf
# ~/.zimmer/clones/*`, which deletes live sessions' uncommitted work.
#
# The guard turns that into two things: an automatic reclamation attempt, and (if
# reclamation is not enough) a clear, actionable failure *before* any bytes are
# written.
#
# Sizing
# ------
# A flat threshold is a poor fit here — a 50 MB repo and a 5 GB monorepo have
# very different needs — so the requirement is derived from the `.git` directory
# of the most recently written existing clone of the *same repository* when there
# is one. `.git` specifically, not the whole tree: the tree also holds whatever
# the previous session installed (node_modules, vendor/bundle, build output),
# none of which `git clone --single-branch` will re-download, so sizing the tree
# would inflate the requirement by an unbounded amount that has nothing to do
# with the clone.
#
# That measurement is bounded four ways, because a sizing routine that is wrong
# in the pessimistic direction blocks every session on the host:
#
#   * MINIMUM_FREE_BYTES is a floor. A repo we have never cloned, or one we
#     cannot measure, still has to clear it. Overridable via ENV so a small host
#     has a lever that is not a redeploy.
#   * MAXIMUM_REQUIRED_BYTES is an absolute ceiling.
#   * MAX_VOLUME_FRACTION is a relative ceiling: the requirement never exceeds
#     this share of the volume's total size. Without it the 2 GiB floor alone
#     turns a 3 GiB disk that was cloning small repos perfectly well into one
#     where nothing can launch.
#   * The `du` runs under a wall-clock timeout and falls back to the floor.
#
# Fail-open
# ---------
# If free space cannot be determined at all (df missing, unparsable, timed out),
# the guard permits the clone. A broken measurement must never be the reason a
# session cannot start; a clone that dies on ENOSPC is strictly better than "no
# session can ever launch".
module CloneDiskGuard
  # Raised when the clones volume cannot accommodate the clone even after
  # pruning. The message is written to be actionable in a session log.
  class InsufficientDiskSpaceError < StandardError; end

  # Floor for free space on the clones volume, regardless of repo size. A clone
  # is only the start of what a session writes: the agent installs dependencies,
  # writes build output, and shares the volume with the scratch and attachment
  # trees. Overridable so a small host can be relieved without a redeploy.
  MINIMUM_FREE_BYTES = Integer(ENV.fetch("CLONE_MINIMUM_FREE_BYTES", (2 * 1024**3).to_s))

  # Absolute ceiling on the derived requirement, so a pathologically large prior
  # clone cannot wedge all future sessions for that repository.
  MAXIMUM_REQUIRED_BYTES = 10 * 1024**3 # 10 GiB

  # Relative ceiling: the requirement never exceeds this share of the volume's
  # total size, so the floor cannot exceed what a small disk could ever offer.
  MAX_VOLUME_FRACTION = 0.25

  # Headroom multiplier over the measured `.git` size of a prior clone of the
  # same repo: one copy for the object store, one for the checked-out tree.
  SIZE_SAFETY_FACTOR = 2

  # Wall-clock cap for the `du` that sizes a prior clone. Exceeding it falls back
  # to MINIMUM_FREE_BYTES rather than delaying the launch path further.
  SIZING_TIMEOUT_SECONDS = Integer(ENV.fetch("CLONE_SIZING_TIMEOUT_SECONDS", "5"))

  # Wall-clock cap for `df`. Short: this runs on the launch path.
  DF_TIMEOUT_SECONDS = 10

  module_function

  # Ensure the clones volume can accommodate a clone of `repository_url`.
  #
  # Runs orphan pruning under pressure before giving up, so the common case of
  # "the disk filled with abandoned clones" self-heals instead of paging a human.
  #
  # @param repository_url [String] the repo about to be cloned (used for sizing)
  # @param base [String] the directory the clone will be written into
  # @raise [InsufficientDiskSpaceError] when space is short after pruning
  # @return [void]
  def ensure_space!(repository_url:, base: ClonesDirectory.base)
    stats = volume_stats(base)

    # Fail open: an unmeasurable volume must not block the launch path.
    if stats.nil?
      logger.warn("Could not determine free space; allowing clone", path: base)
      return
    end

    available = stats[:available]

    # Sizing costs a `du` over a prior clone. Skip it entirely when the volume
    # has more room than any requirement could ask for — which is the state of a
    # healthy host, i.e. almost every launch.
    return if available >= MAXIMUM_REQUIRED_BYTES

    required = required_bytes(repository_url, base: base, total: stats[:total])
    return if available >= required

    logger.warn(
      "Insufficient disk space for clone, attempting orphan reclamation",
      path: base,
      available_bytes: available,
      required_bytes: required
    )

    reclaim_space(target_free_bytes: required, base: base)

    # Measure what was freed on *this* volume rather than trusting the sweeper's
    # own figure, so the number in the error message is about the disk the clone
    # is going to.
    available_after = available_bytes(base) || available
    reclaimed = [ available_after - available, 0 ].max

    if available_after >= required
      logger.info(
        "Reclaimed enough space for clone",
        path: base,
        freed_bytes: reclaimed,
        available_bytes: available_after
      )
      return
    end

    raise InsufficientDiskSpaceError, insufficient_space_message(
      base: base,
      required: required,
      available: available_after,
      reclaimed: reclaimed
    )
  end

  # Total and free bytes on the filesystem backing `path`, or nil if they cannot
  # be determined. Uses POSIX `df -Pk`, whose output format is specified (one
  # record per filesystem, fields in a fixed order) unlike bare `df`.
  #
  # @param path [String]
  # @return [Hash{Symbol=>Integer}, nil] `{total:, available:}`
  def volume_stats(path)
    return nil unless File.directory?(path)

    stdout, _stderr, status = BoundedSubprocess.run(
      [ "df", "-Pk", path.to_s ],
      timeout: DF_TIMEOUT_SECONDS
    )
    return nil unless SubprocessStatus.success?(status)

    # Filesystem 1024-blocks Used Available Capacity Mounted-on
    fields = stdout.lines[1]&.split
    return nil if fields.nil? || fields[1].nil? || fields[3].nil?

    { total: Integer(fields[1]) * 1024, available: Integer(fields[3]) * 1024 }
  rescue BoundedSubprocess::TimeoutError, SystemCallError, IOError, ArgumentError, TypeError => e
    logger.warn("Failed to read free space", path: path.to_s, error: e.message)
    nil
  end

  # Free bytes on the filesystem backing `path`, or nil if it cannot be
  # determined.
  #
  # @param path [String]
  # @return [Integer, nil]
  def available_bytes(path)
    volume_stats(path)&.fetch(:available)
  end

  # Bytes that must be free before cloning `repository_url` into `base`.
  #
  # @param total [Integer, nil] total size of the volume, for the relative cap
  # @return [Integer]
  def required_bytes(repository_url, base: ClonesDirectory.base, total: nil)
    measured = measure_recent_clone(repository_url, base: base)

    derived = measured ? measured * SIZE_SAFETY_FACTOR : 0
    required = [ MINIMUM_FREE_BYTES, derived ].max

    capped = [ required, MAXIMUM_REQUIRED_BYTES ].min
    capped = [ capped, (total * MAX_VOLUME_FRACTION).to_i ].min if total

    if capped < required
      logger.warn(
        "Clone space requirement clamped",
        measured_bytes: measured,
        requested_bytes: required,
        applied_bytes: capped,
        volume_total_bytes: total
      )
    end

    capped
  end

  # Size (in bytes) of the `.git` directory of the most recently modified
  # existing clone of the same repository, or nil when there is none or it cannot
  # be measured in time.
  #
  # `.git` rather than the whole tree: the tree also holds whatever the previous
  # session installed, which the next `git clone --single-branch` will not
  # re-download, so sizing it would inflate the requirement without bound.
  #
  # Clone directory names are `{repo-name}-{branch}-{timestamp}-{random}` (see
  # GitCloneService#generate_clone_path), so the repo name is a prefix match.
  #
  # @return [Integer, nil]
  def measure_recent_clone(repository_url, base: ClonesDirectory.base)
    return nil if repository_url.blank?
    return nil unless File.directory?(base)

    repo_name = File.basename(repository_url.to_s.chomp("/"), ".git")
    return nil if repo_name.blank?

    candidate = Dir.children(base)
      .select { |entry| entry.start_with?("#{repo_name}-") }
      # A tombstone is a clone mid-delete (AtomicCloneRemoval, #412). Sizing one
      # would measure a tree that is disappearing under `du`.
      .reject { |entry| AtomicCloneRemoval.tombstone?(entry) }
      .map { |entry| File.join(base, entry) }
      .select { |path| File.directory?(File.join(path, ".git")) }
      .max_by { |path| File.mtime(path) }
    return nil if candidate.nil?

    directory_size(File.join(candidate, ".git"))
  rescue SystemCallError => e
    logger.warn("Failed to size prior clone", path: base.to_s, error: e.message)
    nil
  end

  # Allocated disk usage of `path` in bytes via `du -sk` (allocated, not
  # apparent — blocks are what the volume actually gives up), or nil if it cannot
  # be measured within SIZING_TIMEOUT_SECONDS.
  #
  # @return [Integer, nil]
  def directory_size(path)
    stdout, _stderr, status = BoundedSubprocess.run(
      [ "du", "-sk", "--", path.to_s ],
      timeout: SIZING_TIMEOUT_SECONDS
    )
    return nil unless SubprocessStatus.success?(status)

    kilobytes = stdout.split.first
    return nil if kilobytes.nil?

    Integer(kilobytes) * 1024
  rescue BoundedSubprocess::TimeoutError, SystemCallError, IOError, ArgumentError, TypeError => e
    logger.warn("Failed to size directory", path: path.to_s, error: e.message)
    nil
  end

  # Ask the orphan sweeper to reclaim space under pressure. Deliberately delegates
  # to OrphanCloneFilesystemCleanupJob rather than deleting anything here: that job
  # owns the "which directories are safe to delete" question, and a second answer
  # to it is exactly how a pruner ends up eating a live session's working
  # directory. It also owns *where* — it resolves ClonesDirectory.base itself and
  # takes no path from us, so a guard invoked with some other `base` can still
  # never aim recursive deletion at it.
  #
  # The flip side of the sweeper owning `where` is that it can only ever relieve
  # the clones volume. A caller guarding some other volume (GitCloneService
  # accepts an explicit clone_path) would otherwise have real clones deleted to
  # relieve pressure on a disk that deletion cannot touch — destructive and
  # useless at once — so reclamation is skipped unless the two are the same
  # device.
  #
  # @return [void]
  def reclaim_space(target_free_bytes:, base:)
    return unless same_device?(base, ClonesDirectory.base)

    OrphanCloneFilesystemCleanupJob.reclaim_space(target_free_bytes: target_free_bytes)
  rescue StandardError => e
    # Reclamation is best-effort. A failure here must still produce the clear
    # "out of disk" error below rather than an opaque one from the sweeper.
    logger.error("Orphan reclamation failed", error: e.message)
  end

  def same_device?(one, other)
    File.stat(one.to_s).dev == File.stat(other.to_s).dev
  rescue SystemCallError => e
    logger.warn("Could not compare volumes; skipping reclamation", error: e.message)
    false
  end

  def insufficient_space_message(base:, required:, available:, reclaimed:)
    "Not enough disk space to clone into #{base}: " \
      "#{human_bytes(available)} free, #{human_bytes(required)} required " \
      "(automatic pruning of orphaned clones reclaimed #{human_bytes(reclaimed)}). " \
      "Archive sessions whose clones are no longer needed, or grow the volume backing #{base}."
  end

  def human_bytes(bytes)
    return "0 B" if bytes.nil? || bytes <= 0

    # Binary units, because every constant here is a power of 1024 and an error
    # message that says "GB" for 2 GiB is a message a reader has to second-guess.
    units = %w[B KiB MiB GiB TiB]
    index = 0
    value = bytes.to_f
    while value >= 1024 && index < units.length - 1
      value /= 1024
      index += 1
    end

    format("%.1f %s", value, units[index])
  end

  def logger
    @logger ||= StructuredLogger.new({ service: "CloneDiskGuard" })
  end
end
