# frozen_string_literal: true

# The one door through which a *reaper* may delete a clone directory.
#
# Why a door, when every reaper already checks ownership
# ------------------------------------------------------
# They all check it, and they all check it too early. Each sweep opens by
# building a snapshot — a plucked list of candidate ids, a `Session.live_clone_paths`
# set, a basename→owner map — and then spends the rest of the run deleting from
# it. Between the snapshot and the `rm` sits everything the run does in between:
# `git bundle create` over a whole working tree, a Docker Compose teardown
# bounded at 120s *per directory*, an `rm -rf` of several gigabytes, and one
# `SELECT sessions.* WHERE id = $1` per candidate. On a healthy box that gap is
# milliseconds. On 2026-09-02 it was minutes — the queue was 144 jobs deep with
# the oldest waiting 1h20m and the slow-query log was full of second-long primary
# key lookups — and a snapshot that says "archived" is a claim about the past,
# not about the instant the bytes go.
#
# A session that is unarchived, resumed, or restarted inside that gap is live by
# the time its turn comes up, and every guard that would have saved it was
# evaluated before it woke. Its clone is deleted out from under a running agent:
# the process keeps writing into a directory that no longer exists, Zimmer's own
# scaffolding (`.mcp.json`, `.claude/`, the stderr log) gets re-created at the
# path by whatever touches it next, and what is left looks exactly like the
# half-tree `AtomicCloneRemoval` was written to prevent — minus the uncommitted
# work (zimmer#808, zimmer#811).
#
# So this asks the question again, in the DB, at the moment of deletion, and
# refuses if the answer changed. It is not a replacement for the sweeps' own
# guards — those are what keep the candidate list small and cheap — it is the
# last one, the only one with no gap after it.
#
# Fail-closed
# -----------
# A question we cannot answer is answered "live". Leaking a stale clone costs
# disk that the next sweep reclaims; deleting a live one costs work that does not
# exist anywhere else.
#
# What this is NOT for
# --------------------
# Disposing of a clone directory the caller itself just created and is rolling
# back — `GitCloneService`'s failed-clone cleanup, `ForkSessionService`'s partial
# destination. Those paths delete a directory no session references yet, so the
# lookup below finds no owner and permits them; but they are also the paths whose
# callers treat "the path is clear" as a precondition, and a guard that can only
# ever turn a no-op into a refusal there is a guard with nothing to protect. They
# go on calling `AtomicCloneRemoval.remove` directly.
module CloneReaper
  # What `.reap` did.
  #
  #   :removed  — the clone was deleted
  #   :absent   — there was nothing at the path
  #   :refused  — a live session still owns it (or ownership could not be read)
  OUTCOMES = %i[removed absent refused].freeze

  module_function

  # Delete a clone directory, unless a live session still owns it.
  #
  # @param path [String, Pathname] the clone directory
  # @param reason [String] what asked for the deletion, for the refusal log
  # @param file_system [FileSystemAdapter] injected for the call sites that own one
  # @return [Symbol] one of OUTCOMES
  def reap(path, reason:, file_system: RealFileSystemAdapter.new)
    return :absent if path.nil? || path.to_s.empty?
    return :absent unless file_system.directory?(path)

    owner = live_owner(path)

    if owner
      refuse(owner, path, reason)
      return :refused
    end

    AtomicCloneRemoval.remove(path, file_system: file_system) ? :removed : :absent
  end

  # The live session that still owns `path`, re-read from the database right now.
  #
  # Matched on the expanded path OR the basename, mirroring
  # StaleCloneCleanupJob's basename guard: clone directory names carry a
  # timestamp and a random suffix, so a basename is a globally unique handle on a
  # clone and survives a stored `clone_path` that cannot be reconciled with the
  # path being swept (a symlinked or relocated clones base).
  #
  # @return [Hash, nil] `{id:, status:}` for the owner, `{id: nil}` when the
  #   question could not be answered, nil when nothing live owns the path
  def live_owner(path)
    expanded = File.expand_path(path.to_s)
    basename = File.basename(expanded)

    owner = Session.unscoped
      .where(status: Session::NON_REAPABLE_STATUSES)
      .where("metadata->>'clone_path' IS NOT NULL")
      .pluck(:id, :status, Arel.sql("metadata->>'clone_path'"))
      .find do |(_id, _status, owned_path)|
        owned_path.present? &&
          (File.expand_path(owned_path) == expanded || File.basename(owned_path) == basename)
      end

    return nil if owner.nil?

    { id: owner[0], status: Session.status_label(owner[1]) }
  rescue ActiveRecord::ActiveRecordError, SystemCallError => e
    # Fail closed. `unscoped` deliberately, above: this query decides deletions,
    # so a default scope added later for soft-delete or tenancy must not be able
    # to hide a live row from it.
    Rails.logger.error "[CloneReaper] Could not establish who owns #{path} (#{e.class}: #{e.message}); " \
      "refusing to delete it"
    { id: nil, status: nil }
  end

  # A refusal means a reaper's snapshot went stale and this guard caught it —
  # i.e. zimmer#808 fired and was defused. `.error`, deliberately: it is rare, it
  # is never routine, and the whole point of the incident it comes from is that
  # nothing told anyone. It reaches VictoriaLogs and the `zimmer_backend_log_errors`
  # alert.
  def refuse(owner, path, reason)
    if owner[:id].nil?
      Rails.logger.error "[CloneReaper] Refused to delete #{path} (#{reason}): ownership could not be " \
        "determined, and an unanswerable question is answered 'live'"
      return
    end

    Rails.logger.error "[CloneReaper] Refused to delete #{path} (#{reason}): session #{owner[:id]} is " \
      "#{owner[:status]} and still owns it. The reaper's view of that session was stale — it is live now, " \
      "so the clone was left in place (zimmer#808)."

    record_refusal(owner, path, reason)
  end

  # Durable, attributable, and on the one surface a person reading Zimmer sees.
  # Best-effort: the `.error` above has already fired, and a failure to write
  # this must never turn a refusal into a deletion.
  def record_refusal(owner, path, reason)
    session = Session.find_by(id: owner[:id])
    return unless session

    session.logs.create!(
      level: "warning",
      content: "A cleanup sweep (#{reason}) was about to delete this session's clone directory " \
        "(#{File.basename(path.to_s)}) while the session is #{owner[:status]}. It was refused and the " \
        "clone was left in place."
    )
  rescue StandardError => e
    Rails.logger.error "[CloneReaper] Failed to record the refusal for session #{owner[:id]}: " \
      "#{e.class} - #{e.message}"
  end
end
