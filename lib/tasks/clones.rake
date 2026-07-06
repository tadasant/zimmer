# frozen_string_literal: true

namespace :clones do
  # Relocate on-disk session clones to the durable clones base directory and
  # update each session's persisted clone-path metadata to match.
  #
  # Designed for the one-time migration when the clones base directory changes
  # (e.g. AGENT_CLONES_DIR is repointed at a new durable volume). It is:
  #
  #   * Idempotent  — a clone already under the destination base is skipped, so
  #     the task is safe to run repeatedly. When source == destination (the
  #     common case, since the default base is already on the durable volume) the
  #     whole task is a no-op.
  #   * Safe while live — it COPIES each clone to the new base and updates the
  #     metadata; it never moves a directory out from under a session. The old
  #     directory is left in place by default (a later orphan/stale sweep, or an
  #     explicit REMOVE_OLD=true run, reclaims it). A live (non-reapable) session
  #     — running, waiting, or needs_input — is never touched destructively even
  #     with REMOVE_OLD=true; only archived/failed sessions' old dirs are removed.
  #
  # Usage:
  #   bin/rails clones:relocate                      # dest = ClonesDirectory.base
  #   DEST=/mnt/durable/clones bin/rails clones:relocate
  #   DRY_RUN=true bin/rails clones:relocate         # report only, no writes
  #   REMOVE_OLD=true bin/rails clones:relocate      # delete old dir for archived/failed sessions
  desc "Relocate session clones to the durable base dir and update metadata (idempotent, live-safe)"
  task relocate: :environment do
    dest_base = (ENV["DEST"].presence && File.expand_path(ENV["DEST"])) || ClonesDirectory.base
    dry_run = ENV["DRY_RUN"] == "true"
    remove_old = ENV["REMOVE_OLD"] == "true"

    FileUtils.mkdir_p(dest_base) unless dry_run

    # Metadata keys that may embed the clone base path and must be rewritten in lockstep.
    path_keys = %w[clone_path working_directory full_clone_path]

    scope = Session.where("metadata->>'clone_path' IS NOT NULL")
    total = scope.count

    relocated = 0
    skipped = 0
    missing = 0
    errors = 0

    log = ->(msg) { puts "[clones:relocate]#{dry_run ? " [DRY_RUN]" : ""} #{msg}" }
    log.call "Destination base: #{dest_base}"
    log.call "Sessions with a clone_path: #{total}"

    scope.find_each do |session|
      meta = session.metadata || {}
      old_clone_path = meta["clone_path"]
      next if old_clone_path.blank?

      old_clone_path = File.expand_path(old_clone_path)
      old_base = File.dirname(old_clone_path)
      basename = File.basename(old_clone_path)
      new_clone_path = File.join(dest_base, basename)

      # Already at destination — nothing to relocate, but make sure metadata is canonical.
      if File.expand_path(old_base) == File.expand_path(dest_base)
        skipped += 1
        next
      end

      unless Dir.exist?(old_clone_path)
        missing += 1
        log.call "session #{session.id}: source clone missing on disk (#{old_clone_path}), skipping copy"
        next
      end

      begin
        if dry_run
          log.call "session #{session.id} (#{session.status}): would copy #{old_clone_path} -> #{new_clone_path} and rewrite #{path_keys.join(', ')}"
          relocated += 1
          next
        end

        # Copy (never move) so a live session's cwd is never pulled out from under it.
        unless Dir.exist?(new_clone_path)
          FileUtils.cp_r(old_clone_path, new_clone_path)
        end

        # Rewrite every path-bearing metadata key in lockstep. Each value is
        # expanded first (so non-canonical stored forms like a trailing slash or
        # "~" still match), then its old-clone-path prefix is rewritten to the new
        # clone path. Anchoring on the full clone path — not just its parent base —
        # means a value that doesn't actually point into this clone is left
        # untouched rather than silently mangled. working_directory (clone_path +
        # subdir) and full_clone_path are handled by the same prefix rewrite.
        new_meta = (session.reload.metadata || {}).dup
        path_keys.each do |key|
          val = new_meta[key]
          next if val.blank?
          expanded = File.expand_path(val)
          next unless expanded == old_clone_path || expanded.start_with?("#{old_clone_path}/")
          new_meta[key] = expanded.sub(/\A#{Regexp.escape(old_clone_path)}/, new_clone_path)
        end
        session.update_column(:metadata, new_meta)

        log.call "session #{session.id} (#{session.status}): relocated -> #{new_clone_path}"
        relocated += 1

        # Only reclaim the old directory once the copy and metadata rewrite have
        # succeeded, and never for a live (non-reapable) session — its clone must
        # survive regardless of age. This matches the never-reap invariant used by
        # the GC (Session::NON_REAPABLE_STATUSES) rather than guarding on `running`
        # alone, which would wrongly delete a needs_input/waiting session's clone.
        old_removable = remove_old &&
          Session::NON_REAPABLE_STATUSES.exclude?(session.status) &&
          Dir.exist?(new_clone_path) &&
          File.expand_path(old_clone_path) != File.expand_path(new_clone_path)
        if old_removable
          FileUtils.rm_rf(old_clone_path)
          log.call "session #{session.id}: removed old clone #{old_clone_path}"
        end
      rescue => e
        errors += 1
        log.call "session #{session.id}: ERROR #{e.class} - #{e.message}"
      end
    end

    log.call "Done. relocated=#{relocated} skipped(already at dest)=#{skipped} missing=#{missing} errors=#{errors}"
  end
end
