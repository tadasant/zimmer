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
#   * **An age bar.** AGE_THRESHOLD (24h), against the newest mtime in the
#     directory rather than the directory's own — see #newest_mtime for why those
#     differ. For the clone-derived class the bar is redundant by design and kept
#     anyway; for the `/tmp` class it is the ONLY liveness check there is, since
#     nothing on the box can say whether a `/tmp` cwd still exists, so it has to
#     be the real age of the transcript.
#
# Not scheduled in development, deliberately: outside a deployment
# `~/.claude/projects` is a person's own Claude Code history.
class OrphanTranscriptDirectoryCleanupJob < ApplicationJob
  queue_as :maintenance
  include SingletonSweep

  # Only reap a transcript directory nothing has written to in a day. See the
  # class comment for what this bar does and does not carry.
  AGE_THRESHOLD = 24.hours

  # Directories per run, at four runs a day. Deliberately far higher than
  # OrphanCloneFilesystemCleanupJob::BATCH_LIMIT (20): there is no Docker Compose
  # teardown here and no wall-clock hazard — a thousand small recursive deletes
  # is seconds of work, not the tens of minutes that job's per-directory
  # COMPOSE_DOWN_TIMEOUT can cost. Sized to work a backlog in the tens of
  # thousands off over days rather than months; the arithmetic is deliberately
  # not pinned to a measurement, which moves.
  BATCH_LIMIT = 1_000

  # The deployments that own the durable volumes, and so are the only ones
  # allowed to reap inside them. Mirrors
  # OrphanCloneFilesystemCleanupJob::SWEEPS_DEFAULT_DURABLE_ROOT — see
  # #sweepable_root?.
  SWEEPS_DEFAULT_DURABLE_ROOT = %w[production staging].freeze

  def perform
    clones_base = ClonesDirectory.base
    return unless sweepable_clones_base?(clones_base)

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
    return unless sweepable_transcript_root?(root)
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

      mtime = newest_mtime(full_path)
      next if mtime > AGE_THRESHOLD.ago

      candidates << [ full_path, mtime ]
    rescue Errno::ENOENT
      # Removed underneath us. Not ours to report on.
      next
    end

    # Measured against the volume rather than summed per directory: `du` on a
    # thousand directories is a thousand subprocesses, and the number that matters is what the
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

  # The most recent mtime anything in `path` carries — the directory's own, and
  # its direct children's.
  #
  # The directory's mtime alone is not the age of the transcript. POSIX bumps a
  # directory's mtime when entries are created or removed in it, NOT when an
  # existing file is appended to — and Claude Code appends to one
  # `<session_id>.jsonl` for the life of a session, while `tool-results/` writes
  # land in that child. So a directory's own mtime effectively freezes at session
  # start, and reading it alone would call a transcript being written right now
  # a day old.
  #
  # Direct children are enough to fix that: the `.jsonl` files are here, and
  # `tool-results/`'s own mtime moves when files land in it. One readdir and a
  # handful of stats per candidate.
  def newest_mtime(path)
    children = Dir.children(path).map { |entry| File.mtime(File.join(path, entry)) }
    [ File.mtime(path), *children ].max
  rescue Errno::ENOENT
    raise
  rescue SystemCallError
    # Unreadable. Answer "now", which excludes it from the sweep — an age we
    # cannot establish is not one to delete on.
    Time.current
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
  # whose clone is still on disk has simply not reached its turn yet.
  #
  # Tombstones are not filtered out, but nothing rests on that. A tombstone is
  # `<clone>.deleting-<hex>`, which derives to `…-<clone>-deleting-<hex>` — and
  # `covers?` asks whether a live NAME prefixes an ENTRY, so a tombstone can
  # never cover the `…-<clone>` entry it came from. It confers no protection, and
  # none is wanted: a clone mid-delete is one whose `CloneReaper.reap` is taking
  # the transcript with it anyway.
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

  # Whether the set difference this sweep computes describes the box it is
  # looking at.
  #
  # The hazard is a process whose database does not describe the volume it reads
  # liveness from: `bin/rails test` runs against `zimmer_test` and `bin/dev`
  # against `zimmer_development`, but both resolve the clones base to
  # `~/.zimmer/clones` — which on a machine that also hosts a real Zimmer holds
  # live sessions' working directories, so against the wrong database every live
  # clone reads as dead. Same fence, same reasoning, as
  # OrphanCloneFilesystemCleanupJob#reclaimable_root?.
  def sweepable_clones_base?(clones_base)
    return true if deployment_owns_its_volumes?
    return true unless inside_default_durable_root?(clones_base)

    Rails.logger.warn "[OrphanTranscriptDirectoryCleanupJob] Refusing to sweep transcript directories " \
      "for #{clones_base}: it is inside the durable volume and #{Rails.env} is not the deployment that " \
      "owns it"
    false
  end

  # Whether the volume this sweep DELETES from belongs to the deployment.
  #
  # A separate question from the one above, and the reason it is asked separately
  # is that the two volumes move independently: `AGENT_CLONES_DIR` relocates the
  # clones base and nothing relocates `~/.claude/projects`. Fencing only on the
  # clones base would therefore *permit* the sweep in exactly the configuration a
  # developer runs — a relocated clones base — and let it delete out of a
  # person's own Claude Code history, which is what lives at that path outside a
  # deployment. The cron entry already declines to schedule this in development;
  # this is the guard for a manual `perform`.
  def sweepable_transcript_root?(root)
    return true if deployment_owns_its_volumes?
    return true unless inside_real_home?(root)

    Rails.logger.warn "[OrphanTranscriptDirectoryCleanupJob] Refusing to sweep #{root}: it is inside " \
      "this user's home directory and #{Rails.env} is not a deployment, so it is a person's own " \
      "Claude Code history rather than a deployment's transcript volume"
    false
  end

  def deployment_owns_its_volumes?
    SWEEPS_DEFAULT_DURABLE_ROOT.include?(Rails.env)
  end

  # Derived from the *default* location (`~/.zimmer`), not from
  # ClonesDirectory.base — deriving it from the configured base would make the
  # check degenerate, since a path is always inside its own parent.
  def inside_default_durable_root?(path)
    inside?(path, File.join(File.expand_path("~"), ClonesDirectory::DEFAULT_HOME_SUBDIR))
  end

  def inside_real_home?(path)
    inside?(path, File.expand_path("~"))
  end

  def inside?(path, root)
    expanded = File.expand_path(path)

    expanded == root || expanded.start_with?("#{root}#{File::SEPARATOR}")
  end
end
