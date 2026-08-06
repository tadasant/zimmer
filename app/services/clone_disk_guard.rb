# frozen_string_literal: true

# Pre-clone disk guard for the clones volume.
#
# Every session's working directory is a git clone under ClonesDirectory.base,
# created on the `waiting → running` launch path. Before this guard existed a
# clone into a full volume died partway with whatever errno git happened to
# surface, leaving a half-written directory behind and — because the volume is
# shared with the scratch, attachment and image trees — degrading every other
# session on the host at the same time. The documented remedy was
# `rm -rf ~/.zimmer/clones/*` by hand.
#
# The guard turns that into two things: an automatic reclamation attempt, and (if
# reclamation is not enough) a clear, actionable failure *before* any bytes are
# written.
#
# Sizing
# ------
# A flat threshold is a poor fit here — a 50 MB repo and a 5 GB monorepo have
# very different needs — so the requirement is derived from the most recently
# written existing clone of the *same repository* when there is one, which is the
# best available proxy for what the next clone of that repo will cost. That
# measurement is bounded three ways, because a sizing routine that is wrong in
# the pessimistic direction blocks every session on the host:
#
#   * MINIMUM_FREE_BYTES is a floor. A repo we have never cloned, or one we
#     cannot measure, still has to clear it.
#   * MAXIMUM_REQUIRED_BYTES is a ceiling. A prior clone that grew pathologically
#     (an agent downloaded a dataset into it, node_modules, build artifacts) must
#     not translate into a requirement no healthy disk can satisfy.
#   * The `du` is run under a wall-clock timeout and falls back to the floor.
#
# Fail-open
# ---------
# If free space cannot be determined at all (df missing, unparsable, timed out),
# the guard permits the clone. A broken measurement must never be the reason a
# session cannot start; the pre-existing failure mode (clone dies on ENOSPC) is
# strictly better than "no session can ever launch".
module CloneDiskGuard
  # Raised when the clones volume cannot accommodate the clone even after
  # pruning. The message is written to be actionable in a session log.
  class InsufficientDiskSpaceError < StandardError; end

  # Absolute floor for free space on the clones volume, regardless of repo size.
  # A clone is only the start of what a session writes: the agent installs
  # dependencies, writes build output, and shares the volume with the scratch and
  # attachment trees.
  MINIMUM_FREE_BYTES = 2 * 1024 * 1024 * 1024 # 2 GiB

  # Ceiling on the derived requirement, so a pathologically large prior clone
  # cannot wedge all future sessions for that repository.
  MAXIMUM_REQUIRED_BYTES = 10 * 1024 * 1024 * 1024 # 10 GiB

  # Headroom multiplier over the measured size of a prior clone of the same repo:
  # one copy for the clone itself, one for what the session writes into it.
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
    required = required_bytes(repository_url, base: base)
    available = available_bytes(base)

    # Fail open: an unmeasurable volume must not block the launch path.
    if available.nil?
      logger.warn("Could not determine free space; allowing clone", path: base)
      return
    end

    return if available >= required

    logger.warn(
      "Insufficient disk space for clone, attempting orphan reclamation",
      path: base,
      available_bytes: available,
      required_bytes: required
    )

    reclaim_space(target_free_bytes: required)

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

  # Free bytes on the filesystem backing `path`, or nil if it cannot be
  # determined. Uses POSIX `df -Pk`, whose output format is specified (one record
  # per filesystem, fields in a fixed order) unlike bare `df`.
  #
  # @param path [String]
  # @return [Integer, nil]
  def available_bytes(path)
    return nil unless File.directory?(path)

    stdout, _stderr, status = BoundedSubprocess.run(
      [ "df", "-Pk", path.to_s ],
      timeout: DF_TIMEOUT_SECONDS
    )
    return nil unless SubprocessStatus.success?(status)

    # Filesystem 1024-blocks Used Available Capacity Mounted-on
    fields = stdout.lines[1]&.split
    return nil if fields.nil? || fields[3].nil?

    Integer(fields[3]) * 1024
  rescue BoundedSubprocess::TimeoutError, ArgumentError, TypeError, Errno::ENOENT => e
    logger.warn("Failed to read free space", path: path.to_s, error: e.message)
    nil
  end

  # Bytes that must be free before cloning `repository_url` into `base`.
  #
  # @return [Integer]
  def required_bytes(repository_url, base: ClonesDirectory.base)
    measured = measure_recent_clone(repository_url, base: base)
    return MINIMUM_FREE_BYTES if measured.nil?

    derived = measured * SIZE_SAFETY_FACTOR
    capped = [ derived, MAXIMUM_REQUIRED_BYTES ].min

    if derived > MAXIMUM_REQUIRED_BYTES
      logger.warn(
        "Derived clone space requirement exceeds cap; using cap",
        measured_bytes: measured,
        derived_bytes: derived,
        cap_bytes: MAXIMUM_REQUIRED_BYTES
      )
    end

    [ MINIMUM_FREE_BYTES, capped ].max
  end

  # Size (in bytes) of the most recently modified existing clone of the same
  # repository, or nil when there is none or it cannot be measured in time.
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
      .map { |entry| File.join(base, entry) }
      .select { |path| File.directory?(path) }
      .max_by { |path| File.mtime(path) }
    return nil if candidate.nil?

    directory_size(candidate)
  rescue SystemCallError => e
    logger.warn("Failed to size prior clone", path: base.to_s, error: e.message)
    nil
  end

  # Apparent disk usage of `path` in bytes via `du -sk`, or nil if it cannot be
  # measured within SIZING_TIMEOUT_SECONDS.
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
  rescue BoundedSubprocess::TimeoutError, ArgumentError, TypeError, Errno::ENOENT => e
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
  # @return [Integer] bytes the sweeper reports freeing (0 when nothing was reclaimable)
  def reclaim_space(target_free_bytes:)
    OrphanCloneFilesystemCleanupJob.reclaim_space(target_free_bytes: target_free_bytes)
  rescue StandardError => e
    # Reclamation is best-effort. A failure here must still produce the clear
    # "out of disk" error below rather than an opaque one from the sweeper.
    logger.error("Orphan reclamation failed", error: e.message)
    0
  end

  def insufficient_space_message(base:, required:, available:, reclaimed:)
    "Not enough disk space to clone into #{base}: " \
      "#{human_bytes(available)} free, #{human_bytes(required)} required " \
      "(automatic pruning of orphaned clones reclaimed #{human_bytes(reclaimed)}). " \
      "Archive sessions whose clones are no longer needed, or grow the volume backing #{base}."
  end

  def human_bytes(bytes)
    return "0 B" if bytes.nil? || bytes <= 0

    units = %w[B KB MB GB TB]
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
