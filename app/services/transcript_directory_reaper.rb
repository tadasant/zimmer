# frozen_string_literal: true

# Deletes the runtime transcript directories a clone left behind.
#
# Why they are left behind at all
# -------------------------------
# Claude Code writes its transcript and `tool-results/` to
# `~/.claude/projects/<derived-from-cwd>/`, which is a DIFFERENT volume from the
# clone (`claude_home` vs `zimmer_data`). Delete the clone and the cwd that named
# the transcript directory stops being derivable from anything — the directory is
# still there, still several hundred kilobytes, and nothing on the box can say
# whose it was. Production held 6,612 of them (5.6 G, 99.3% orphaned) when
# zimmer#434 was measured.
#
# So the transcript goes when the clone goes, from inside CloneReaper — the one
# door a reaper deletes a clone through — which is what stops the backlog growing
# while OrphanTranscriptDirectoryCleanupJob works through the one that exists.
#
# Two working directories per clone, not one
# ------------------------------------------
# An agent root with a `subdirectory` runs with cwd `<clone>/<subdir>`, so the
# clone can own more than one transcript directory: its own derived name, and one
# per subdirectory cwd beneath it. All of them go. That is the same prefix rule
# TranscriptDirectoryClassifier uses to SPARE a live session's subdirectory
# transcript, applied in the other direction.
#
# Best-effort, always
# -------------------
# Every failure here is swallowed and logged. The clone is already gone by the
# time this runs; raising would turn a leaked few hundred kilobytes — which the
# sweeper reclaims on its own schedule — into a failed archive or a failed sweep.
#
# Real IO, not the caller's adapter
# ---------------------------------
# CloneReaper threads a `file_system:` adapter through to AtomicCloneRemoval and
# this does not take it. That is deliberate rather than an oversight: the adapter
# names the CLONES volume, and every path here is on a different one
# (`claude_home`). A caller holding a mock adapter for its own clone tree has no
# opinion about `~/.claude/projects`, and honoring one would mean the transcript
# a real session wrote goes unreaped whenever the caller happened to inject.
module TranscriptDirectoryReaper
  module_function

  # Remove every transcript directory derived from a cwd at or beneath
  # `clone_path`, across every runtime that lays transcripts out per working
  # directory.
  #
  # @param clone_path [String, Pathname] the clone directory that was deleted
  # @return [Integer] how many transcript directories were removed
  def reap_for_clone(clone_path)
    return 0 unless within_clones_base?(clone_path)

    removed = 0

    per_working_directory_sources.each do |source|
      root = source.per_working_directory_transcript_root
      next if root.blank? || !File.directory?(root)

      # Derived once, outside the loop: the name is constant across entries and
      # the root it is matched against holds thousands of them.
      name = TranscriptDirectoryClassifier.derived_name(
        transcript_source: source, working_directory: File.expand_path(clone_path.to_s)
      )
      next if name.blank?

      children(root).each do |entry|
        next unless TranscriptDirectoryClassifier.covers?(name, entry)

        removed += 1 if remove_directory(File.join(root, entry))
      end
    end

    if removed > 0
      Rails.logger.info "[TranscriptDirectoryReaper] Removed #{removed} transcript " \
        "director#{removed == 1 ? "y" : "ies"} for #{File.basename(clone_path.to_s)}"
    end

    removed
  rescue StandardError => e
    Rails.logger.error "[TranscriptDirectoryReaper] Failed to reap transcript directories for " \
      "#{clone_path}: #{e.class} - #{e.message}"
    removed || 0
  end

  # The registered runtime sources that keep one transcript directory per working
  # directory under an enumerable root. Everything else answers nil to
  # `per_working_directory_transcript_root` and is skipped — see the comment on
  # that method for why nil is a refusal rather than a gap.
  #
  # @return [Array<TranscriptSource>]
  def per_working_directory_sources
    RuntimeRegistry::BUNDLES.values
      .filter_map(&:transcript_source_class)
      .uniq
      .map(&:new)
      .select { |source| source.per_working_directory_transcript_root.present? }
  end

  # Whether `clone_path` is a direct child of the clones base.
  #
  # A blast-radius fence, not a correctness check. This module turns one path
  # into a name-prefix match over a directory holding thousands of entries, so a
  # caller that handed it `/` or the clones base itself would sweep the lot. Only
  # a clone directory is ever a legitimate argument, and a clone is always a
  # direct child of the base (GitCloneService#generate_clone_path), so anything
  # else declines rather than guesses.
  #
  # The cost of a false negative is a leaked transcript directory the sweeper
  # picks up later; the cost of a false positive is a live session's transcript.
  def within_clones_base?(clone_path)
    return false if clone_path.nil? || clone_path.to_s.empty?

    expanded = File.expand_path(clone_path.to_s)
    return true if File.dirname(expanded) == File.expand_path(ClonesDirectory.base)

    Rails.logger.warn "[TranscriptDirectoryReaper] Declining to derive transcript directories from " \
      "#{expanded}: it is not a direct child of #{ClonesDirectory.base}"
    false
  rescue ArgumentError => e
    # File.expand_path raises for an unresolvable `~user` prefix. A path we cannot
    # canonicalize is not one to match names against.
    Rails.logger.warn "[TranscriptDirectoryReaper] Could not canonicalize #{clone_path}: #{e.message}"
    false
  end

  def children(root)
    Dir.children(root)
  rescue SystemCallError => e
    Rails.logger.error "[TranscriptDirectoryReaper] Failed to list #{root}: #{e.class} - #{e.message}"
    []
  end

  # Recursively remove one transcript directory.
  #
  # Public because OrphanTranscriptDirectoryCleanupJob deletes the same kind of
  # directory for the same reason and must not grow a second copy of the
  # "`rm_rf` swallows its errors" handling below.
  #
  # @param path [String] a transcript directory
  # @return [Boolean] whether the directory is gone afterwards
  def remove_directory(path)
    FileUtils.rm_rf(path)

    # `rm_rf` is `rm_r(force: true)`: it swallows every error and returns
    # normally, so "removed" has to be checked against the disk rather than taken
    # from the call — the same reason AtomicCloneRemoval.reap_tombstones checks.
    if File.exist?(path) || File.symlink?(path)
      Rails.logger.warn "[TranscriptDirectoryReaper] #{path} survived its removal"
      return false
    end

    true
  rescue StandardError => e
    Rails.logger.error "[TranscriptDirectoryReaper] Failed to remove #{path}: #{e.class} - #{e.message}"
    false
  end

  private_class_method :children
end
