# frozen_string_literal: true

# Reaps the transcript directories under `~/.claude/projects` whose working
# directory no longer exists.
#
# `CloneReaper` (via `TranscriptDirectoryReaper`) stops the pile growing, from
# the moment this ships. It cannot touch the pile that already exists: those
# directories were orphaned by clone deletions that happened before the hook
# existed, and the cwd that named each one is unrecoverable. Production held
# 6,612 transcript directories (5.6 G) of which ~6,564 — 99.3% — were orphaned
# when zimmer#434 was measured; staging held 5,098 (27 G) and filled its root
# disk to 0 bytes free, which is what put Postgres into a crash-recovery loop.
# This is the sweep that works that backlog off.
#
# Count is not a proxy for bytes
# ------------------------------
# Per-directory size differs by more than an order of magnitude between
# deployments — staging averaged ~5.4 MB/dir, production ~330 KB/dir — so the run
# log reports both, measured against the volume, rather than inviting anyone to
# infer one from the other.
#
# The safety rules, and why they are the ones they are
# ----------------------------------------------------
# The failure mode of a wrong classification is not disk: it is a running
# session's conversation, which exists in `<transcript>/…jsonl` and nowhere else
# on the box, and which `--resume` reads on every continuation. So:
#
#   * **`:unknown` keeps.** TranscriptDirectoryClassifier answers `:orphaned`
#     only for a name it can positively attribute to a clone that is gone, or to
#     an ephemeral (`/tmp`) cwd. `-rails` — the app root inside the container,
#     which is live — is `:unknown`, and so is anything a future cwd invents.
#   * **A live clone claims its subdirectory cwds too.** An agent root with a
#     `subdirectory` is spawned in `<clone>/<subdir>`, so its transcript
#     directory extends the clone's derived name by `-<subdir>`. The classifier
#     spares those; see its header.
#   * **Liveness is read from two places, unioned.** The clone directories on
#     disk, AND the `clone_path` of every reap-protected session
#     (`Session.reap_protected` — live, or mid-unarchive). Either one alone would
#     be a single point of failure in the direction that deletes.
#   * **Abort guards on list integrity.** A clones base that is missing or
#     unreadable makes every clone-derived directory look orphaned at once, which
#     is precisely the shape of a mass deletion. The run stops instead.
#   * **An age bar.** AGE_THRESHOLD (24h) on the transcript directory's own
#     mtime. Nothing in the design needs it — a directory whose clone is gone is
#     orphaned the instant the clone goes — but it is the guard that costs
#     nothing and covers the case nobody thought of, including a `/tmp` cwd a
#     process is writing to right now.
#
# Not scheduled in development, deliberately: outside a deployment
# `~/.claude/projects` is a person's own Claude Code history.
class OrphanTranscriptDirectoryCleanupJob < ApplicationJob
  queue_as :maintenance
  include SingletonSweep

  # Only reap a transcript directory nothing has written to in a day. See the
  # class comment — this bar is redundant by design and kept anyway.
  AGE_THRESHOLD = 24.hours

  # Directories per run. Sized against the backlog it has to clear: production's
  # ~6,564 orphans at four runs a day is under four days, and 500 small recursive
  # deletes is seconds of work, not the tens of minutes
  # OrphanCloneFilesystemCleanupJob's Compose teardowns can cost.
  BATCH_LIMIT = 500

  # The deployments that own the durable volumes, and so are the only ones
  # allowed to reap inside them. Mirrors
  # OrphanCloneFilesystemCleanupJob::SWEEPS_DEFAULT_DURABLE_ROOT — see
  # #sweepable_root?.
  SWEEPS_DEFAULT_DURABLE_ROOT = %w[production staging].freeze

  def perform
    clones_base = ClonesDirectory.base
    return unless sweepable_root?(clones_base)

    live_names = live_clone_names(clones_base)
    return if live_names.nil?

    TranscriptDirectoryReaper.per_working_directory_sources.each do |source|
      sweep(source, clones_base: clones_base, live_names: live_names)
    end
  end

  private

  # One runtime's transcript root.
  def sweep(source, clones_base:, live_names:)
    root = source.per_working_directory_transcript_root
    return if root.blank?
    return unless File.directory?(root)

    classifier = TranscriptDirectoryClassifier.new(
      transcript_source: source, clones_base: clones_base, live_clone_names: live_names
    )

    entries = begin
      Dir.children(root)
    rescue SystemCallError => e
      # Same abort logic as an unreadable clones base: a partial listing is a
      # wrong answer, not a smaller one.
      Rails.logger.error "[OrphanTranscriptDirectoryCleanupJob] Failed to list #{root}: " \
        "#{e.class} - #{e.message}; aborting the sweep"
      return
    end

    counts = Hash.new(0)
    candidates = []

    entries.each do |entry|
      full_path = File.join(root, entry)
      next unless File.directory?(full_path)

      classification = classifier.classify(entry)
      counts[classification] += 1
      next unless classification == :orphaned

      mtime = File.mtime(full_path)
      next if mtime > AGE_THRESHOLD.ago

      candidates << [ full_path, mtime ]
    rescue Errno::ENOENT
      # Removed underneath us. Not ours to report on.
      next
    end

    # Measured against the volume rather than summed per directory: `du` on 500
    # directories is 500 subprocesses, and the number that matters is what the
    # disk gave back. Approximate by construction — anything else writing to the
    # same volume during the sweep moves it — which is exactly the caveat
    # OrphanCloneFilesystemCleanupJob#bytes_freed_since already lives with.
    starting_free = CloneDiskGuard.available_bytes(root)
    removed = remove_oldest_first(candidates)
    freed = bytes_freed_since(starting_free, root)

    Rails.logger.info "[OrphanTranscriptDirectoryCleanupJob] #{root}: " \
      "#{counts[:live]} live, #{counts[:unknown]} unclassified (kept), " \
      "#{counts[:orphaned]} orphaned of which #{candidates.size} past the age bar; " \
      "removed #{removed} (#{freed} bytes reclaimed)" \
      "#{candidates.size > BATCH_LIMIT ? ", #{candidates.size - BATCH_LIMIT} left for the next run" : ""}"
  end

  # @return [Integer] directories removed
  def remove_oldest_first(candidates)
    candidates.sort_by(&:last).first(BATCH_LIMIT).count do |(path, _mtime)|
      TranscriptDirectoryReaper.remove_directory(path)
    end
  end

  # Bytes the volume gave back since `starting_free`. Zero when either probe
  # failed — the same shape as OrphanCloneFilesystemCleanupJob#bytes_freed_since.
  def bytes_freed_since(starting_free, root)
    ending_free = CloneDiskGuard.available_bytes(root)
    return 0 unless starting_free && ending_free

    [ ending_free - starting_free, 0 ].max
  end

  # Basenames of every clone that is still live, from BOTH the filesystem and the
  # database, unioned. nil means "could not be established" — the caller aborts.
  #
  # A clone directory that exists is live for this purpose whatever its session's
  # status: the transcript hook fires when the clone is deleted, so a transcript
  # whose clone is still on disk has simply not reached its turn yet. Tombstones
  # are included rather than filtered, for the same reason — a clone mid-delete
  # is a clone whose `CloneReaper.reap` is about to take the transcript with it.
  #
  # @return [Set<String>, nil]
  def live_clone_names(clones_base)
    unless File.directory?(clones_base)
      Rails.logger.error "[OrphanTranscriptDirectoryCleanupJob] Clones base #{clones_base} is not a " \
        "directory; aborting rather than treating every clone-derived transcript directory as orphaned"
      return nil
    end

    on_disk = begin
      Dir.children(clones_base)
    rescue SystemCallError => e
      Rails.logger.error "[OrphanTranscriptDirectoryCleanupJob] Failed to list #{clones_base}: " \
        "#{e.class} - #{e.message}; aborting the sweep"
      return nil
    end

    # `unscoped` deliberately: this set decides deletions, so a default scope
    # added later for soft-delete or tenancy must not be able to hide a live
    # session's clone from it.
    claimed = Session.unscoped
      .reap_protected
      .where("metadata->>'clone_path' IS NOT NULL")
      .pluck(Arel.sql("metadata->>'clone_path'"))
      .compact_blank
      .map { |path| File.basename(path) }

    (on_disk + claimed).to_set
  rescue ActiveRecord::ActiveRecordError => e
    # Fail closed: a liveness question that could not be answered is answered
    # "everything is live".
    Rails.logger.error "[OrphanTranscriptDirectoryCleanupJob] Could not read live clone paths " \
      "(#{e.class}: #{e.message}); aborting the sweep"
    nil
  end

  # Whether this deployment may reap at all.
  #
  # The hazard is a process whose database and clones base do not describe the
  # box it is looking at: `bin/rails test` runs against `zimmer_test` and
  # `bin/dev` against `zimmer_development`, but `~/.claude/projects` is whatever
  # the host has — on a developer's machine, their own Claude Code history. Same
  # fence, same reasoning, as OrphanCloneFilesystemCleanupJob#reclaimable_root?,
  # and the cron entry backs it up by not scheduling this outside production and
  # staging at all.
  def sweepable_root?(clones_base)
    return true if SWEEPS_DEFAULT_DURABLE_ROOT.include?(Rails.env)
    return true unless inside_default_durable_root?(clones_base)

    Rails.logger.warn "[OrphanTranscriptDirectoryCleanupJob] Refusing to sweep transcript directories " \
      "for #{clones_base}: it is inside the durable volume and #{Rails.env} is not the deployment that " \
      "owns it"
    false
  end

  # Derived from the *default* location (`~/.zimmer`), not from
  # ClonesDirectory.base — deriving it from the configured base would make the
  # check degenerate, since a path is always inside its own parent.
  def inside_default_durable_root?(path)
    durable_root = File.join(File.expand_path("~"), ClonesDirectory::DEFAULT_HOME_SUBDIR)
    expanded = File.expand_path(path)

    expanded == durable_root || expanded.start_with?("#{durable_root}#{File::SEPARATOR}")
  end
end
