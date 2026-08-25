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
# And a second orphan sweep over the four roots whose per-session directories are
# named for the session id — scratch, the Claude config dir, and the two
# prompt-attachment trees. Every
# other reaper in the pipeline starts from a Session query, so a hard-deleted row
# takes with it the only handle on its bytes; this sweep is the one that can still
# find them (see #sweep_orphaned_session_directories).
#
class StaleCloneCleanupJob < ApplicationJob
  include DatabaseRetry
  include DurableSessionStorage
  queue_as :default
  include SingletonSweep

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

  # Directory names the per-session orphan sweep is willing to consider. A session
  # id is always a positive integer, so this pattern is what makes "the directory
  # name IS the primary key" a safe assumption. What it keeps out: the
  # `temp_<uuid>` attachment directories (pre-session uploads that no session id
  # can vouch for yet — deleting one would eat an upload the user is still
  # composing with), and the `test-worker-<pid>` trees a suite run leaves in the
  # attachment roots when it runs against a shared volume.
  #
  # Capped at 18 digits so a candidate always fits in the bigint primary key: a
  # longer run of digits would make Postgres raise on the lookup below rather
  # than answer it, and a directory whose ownership cannot be established is a
  # directory this sweep leaves alone.
  SESSION_ID_DIR = /\A[1-9]\d{0,17}\z/

  # Blast-radius cap: the most directories one run will remove from any single
  # per-session root. Over-limit orphans are logged and picked up next hour, so a
  # sweep that is wrong about what it owns is wrong 200 directories at a time
  # instead of all at once.
  ORPHAN_SWEEP_LIMIT = 200

  # The deployments that own the durable `zimmer_data` volume, and so are the
  # only ones allowed to reap per-session directories inside it. See
  # #sweepable_root?.
  SWEEPS_DEFAULT_DURABLE_ROOT = %w[production staging].freeze

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

    orphan_dir_result = sweep_orphaned_session_directories
    cleaned_count += orphan_dir_result[:cleaned]
    error_count += orphan_dir_result[:errors]

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
    # Unlike the trash path, this job only sees sessions that are genuinely
    # abandoned — archived over an hour ago with no trash deadline, or failed
    # for a day — so there is no restore to preserve it for.
    if scratch_dir_exists?(session.id)
      SessionScratchDirectory.cleanup_for(session.id)
      Rails.logger.info "[StaleCloneCleanupJob] Cleaned stale scratch dir for session #{session.id}"
      cleaned_anything = true
    end

    # Same reasoning for the session's own CLAUDE_CONFIG_DIR, which holds its
    # mcpOAuth tokens and the CLI's conversation state.
    if claude_config_dir_exists?(session.id)
      ClaudeSessionConfigDirectory.cleanup_for(session.id)
      Rails.logger.info "[StaleCloneCleanupJob] Cleaned stale Claude config dir for session #{session.id}"
      cleaned_anything = true
    end

    # Reclaim durable prompt-attachment storage (files + images) on the same
    # lifecycle. It now lives on the shared ~/.zimmer volume (see
    # FileStorageService.storage_root), so it is no longer wiped by container
    # recreation and must be reaped explicitly or it accumulates forever.
    if prompt_attachments_exist?(session.id)
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

    # Directories left by a clone delete that was interrupted between the rename
    # and the recursive unlink (#412). They are counted and logged by
    # AtomicCloneRemoval rather than folded into this sweep's totals: they are not
    # orphaned clones, and the age and ownership guards below do not apply to them
    # — a tombstone is doomed the moment it is created.
    AtomicCloneRemoval.reap_tombstones(clones_base)

    Dir.children(clones_base).each do |entry|
      full_path = File.join(clones_base, entry)
      next unless File.directory?(full_path)
      # Not a clone: a delete in flight, or one interrupted since the reap above.
      # Either way it is never this sweep's to reason about.
      next if AtomicCloneRemoval.tombstone?(entry)

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

  # Filesystem-level sweep over the roots whose per-session directories are named
  # for the session id: scratch, the Claude config dir, and the two
  # prompt-attachment trees.
  #
  # Why this has to exist at all: every other reaper that touches these roots
  # (EmptyTrashJob, DeferredCloneCleanupJob, the DB-driven scopes above) starts
  # from a Session query and cleans up by id. Deleting the row therefore destroys
  # the only handle on those bytes — no query can find a directory whose owner no
  # longer exists — and they stay on the durable volume forever (#340). The clones
  # base has had a sweep for exactly this since forever; these four are siblings
  # of it, deliberately outside its scan (see SessionScratchDirectory), so they
  # need their own.
  #
  # The safety argument, since this deletes directories on the live data volume
  # from a computed set difference:
  #
  #   * Only `\d+` names are considered (SESSION_ID_DIR) — a directory name that
  #     is not a session id is never a candidate, whatever else it may be.
  #   * The DB question asked is the narrow one — "which of THESE ids exist?" —
  #     not "list every id". A row is only ever swept when Postgres explicitly
  #     said that primary key is gone.
  #   * The id set is read AFTER the directory listing, so a session created in
  #     between is in the set; the reverse ordering (which could miss it) is
  #     impossible.
  #   * ORPHAN_AGE_THRESHOLD covers the startup race: a directory younger than an
  #     hour is left alone no matter what the DB says, so a scratch dir created
  #     before its row committed survives.
  #   * A completely empty sessions table aborts the sweep. That is only the
  #     crudest version of "the database does not know about this volume" — a
  #     restore from a stale snapshot still has rows and passes — but it is the
  #     one shape where "no row owns this" is a lie about every directory at
  #     once, and ORPHAN_SWEEP_LIMIT is what bounds the subtler versions.
  #   * Only the deployment that owns the durable volume sweeps it — see
  #     #sweepable_root?, which is what keeps `bin/dev` and `bin/rails test` on
  #     a machine that shares that volume from reaping live sessions.
  #   * Every removal is logged with its path and mtime BEFORE the bytes go.
  def sweep_orphaned_session_directories
    cleaned = 0
    errors = 0

    unless any_sessions_exist?
      Rails.logger.warn "[StaleCloneCleanupJob] Skipping per-session orphan sweep: the sessions table is empty, " \
        "so every directory would look orphaned"
      return { cleaned: cleaned, errors: errors }
    end

    session_directory_roots.each do |label, root|
      next unless sweepable_root?(label, root)

      result = sweep_session_directory_root(label, root)
      cleaned += result[:cleaned]
      errors += result[:errors]
    end

    { cleaned: cleaned, errors: errors }
  end

  # The roots swept above.
  #
  # Resolved through the same single-source-of-truth readers the writers use, so
  # a sweep can never scan a base the writers stopped using. FileStorageService
  # and ImageStorageService are read through `base_dir` (not `storage_root`)
  # because `base_dir` is what `session_dir` is built from, so this is the tree
  # the uploads actually landed in.
  def session_directory_roots
    [
      [ "scratch", SessionScratchDirectory.base ],
      # The per-session CLAUDE_CONFIG_DIR has exactly the property this sweep
      # exists for: a hard-deleted row destroys the only handle on it, and it
      # sits on the durable volume. `rm_rf` on it is safe — it does not follow
      # the `projects/` symlink inside.
      [ "Claude config", ClaudeSessionConfigDirectory.base ],
      [ "prompt files", FileStorageService.base_dir ],
      [ "prompt images", ImageStorageService.base_dir ]
    ]
  end

  # Whether this process is allowed to sweep a given root.
  #
  # The hazard is a process whose database does not describe the volume it is
  # looking at. The default roots resolve under `~/.zimmer` — the same durable
  # volume a production Zimmer keeps live sessions on — while the database is
  # whatever the local environment points at. `bin/rails test` against
  # `zimmer_test`, or `bin/dev` against `zimmer_development` (which runs this
  # very job on an hourly cron, in-process), would then compute every live
  # session's scratch directory as an orphan and delete it. Scratch and prompt
  # attachments have no remote to be re-fetched from, so that is unrecoverable.
  #
  # The rule is therefore about the path, not the environment name: only the
  # deployments that own the durable volume (production, staging) may sweep a
  # root that lives inside it. Anywhere else a root is swept only when it has
  # been relocated clear of that volume — which is what the tests for this sweep
  # do, and what a developer with a private data dir gets for free.
  def sweepable_root?(label, root)
    return false if root.blank? || !File.directory?(root)
    return true if SWEEPS_DEFAULT_DURABLE_ROOT.include?(Rails.env)
    return true unless inside_default_durable_root?(root)

    Rails.logger.debug "[StaleCloneCleanupJob] Skipping #{label} orphan sweep: #{root} is inside the durable " \
      "volume and #{Rails.env} is not the deployment that owns it"
    false
  end

  # Whether a path sits at or under the durable root that backs the clones base
  # (`~/.zimmer` by default, or the parent of AGENT_CLONES_DIR).
  def inside_default_durable_root?(path)
    durable_root = File.expand_path(File.dirname(ClonesDirectory.base))
    expanded = File.expand_path(path)

    expanded == durable_root || expanded.start_with?("#{durable_root}#{File::SEPARATOR}")
  end

  def sweep_session_directory_root(label, root)
    cleaned = 0
    errors = 0
    over_limit = 0

    begin
      candidates = Dir.children(root).select { |entry| entry.match?(SESSION_ID_DIR) }
    rescue => e
      Rails.logger.error "[StaleCloneCleanupJob] Failed to list #{label} root #{root}: #{e.class} - #{e.message}"
      return { cleaned: cleaned, errors: 1 }
    end

    return { cleaned: cleaned, errors: errors } if candidates.empty?

    # Asked after the listing, and only about the ids on disk: a bounded primary
    # key lookup, and a superset in time of what the listing saw. Sliced so a
    # volume with a large backlog of directories cannot build an unbounded IN.
    # `unscoped` deliberately: this query decides deletions, so it must see every
    # row the table has. A default scope added later for soft-delete or tenancy
    # would otherwise hide live rows from it and make their directories look
    # orphaned — while the empty-table guard above, which is already unscoped,
    # kept passing.
    live_ids = candidates
      .each_slice(1_000)
      .flat_map { |slice| Session.unscoped.where(id: slice).pluck(:id) }
      .map(&:to_s)
      .to_set
    cutoff = ORPHAN_AGE_THRESHOLD.ago

    candidates.each do |entry|
      next if live_ids.include?(entry)

      path = File.join(root, entry)
      next unless File.directory?(path)

      begin
        mtime = File.mtime(path)
        next if mtime > cutoff

        if cleaned >= ORPHAN_SWEEP_LIMIT
          over_limit += 1
          next
        end

        Rails.logger.info "[StaleCloneCleanupJob] Sweeping orphaned #{label} dir for deleted session #{entry}: " \
          "#{path} (mtime: #{mtime.iso8601})"
        FileUtils.rm_rf(path)
        cleaned += 1
      rescue => e
        errors += 1
        Rails.logger.error "[StaleCloneCleanupJob] Failed to sweep orphaned #{label} dir #{path}: #{e.class} - #{e.message}"
      end
    end

    if over_limit > 0
      Rails.logger.warn "[StaleCloneCleanupJob] Orphan sweep hit the #{ORPHAN_SWEEP_LIMIT}-directory cap for " \
        "#{label}: #{over_limit} left for the next run"
    end

    if cleaned > 0
      Rails.logger.info "[StaleCloneCleanupJob] Orphan sweep: removed #{cleaned} #{label} directories"
    end

    { cleaned: cleaned, errors: errors }
  end

  def any_sessions_exist?
    Session.unscoped.exists?
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
