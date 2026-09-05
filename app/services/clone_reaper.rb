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
# There is a second way the snapshot lies, and it does not need a slow box at
# all: an unarchive is `archived` for its whole duration. UnarchiveSessionService
# re-clones from the remote, replays the preserved artifacts and runs
# `air prepare` before it transitions the status, so for that window a session
# having a *new* clone built for it is indistinguishable from one whose old clone
# was abandoned — same status, same absent trash deadline, same days-old
# `archived_at`. `Session.reap_protected` is what tells them apart.
#
# So this asks the question again, in the DB, at the moment of deletion, and
# refuses if the answer changed. It is not a replacement for the sweeps' own
# guards — those are what keep the candidate list small and cheap — it is the
# last one, and the gap after it is the microseconds between the `SELECT` and the
# `rename(2)` rather than the minutes a sweep leaves.
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
# back — `GitCloneService#discard_failed_clone`, `ForkSessionService`'s partial
# destination. Those paths delete a directory no session references yet, so the
# guard has nothing to protect there, and it can only do harm: failing closed on
# a momentary database blip would leave a partial tree at the path, and the next
# `git clone` into it dies with "destination path already exists and is not an
# empty directory" — which `transient_clone_error?` does not classify as
# transient, turning a retryable clone failure into a permanent session failure.
# Those paths call `AtomicCloneRemoval.remove` directly, and must keep doing so.
# They also have no transcript to reap: nothing has been spawned in a clone that
# is being rolled back before it was ever handed to a session.
#
# What else goes with the clone
# -----------------------------
# The runtime's transcript directory (`~/.claude/projects/<derived-from-cwd>`),
# via TranscriptDirectoryReaper. It is on a different volume, it is named for a
# path that stops existing the moment the clone does, and so it is only ever
# deletable from here — see zimmer#434 and the reaper's own header.
module CloneReaper
  module_function

  # Delete a clone directory, unless a live session still owns it.
  #
  # @param path [String, Pathname] the clone directory
  # @param reason [String] what asked for the deletion, for the refusal log
  # @param file_system [FileSystemAdapter] injected for the call sites that own one
  # @return [Symbol] `:removed`, `:absent` (nothing at the path), or `:refused`
  def reap(path, reason:, file_system: RealFileSystemAdapter.new)
    return :absent if path.nil? || path.to_s.empty?
    # `exists?`, not `directory?`, matching AtomicCloneRemoval: a clone path can
    # be a plain file or a dangling symlink, and skipping those leaks them while
    # reporting them cleaned.
    return :absent unless file_system.exists?(path)

    owner = live_owner(path)

    if owner
      refuse(owner, path, reason)
      return :refused
    end

    outcome = AtomicCloneRemoval.remove(path, file_system: file_system) ? :removed : :absent

    # The clone's transcript directory lives on a different volume (`claude_home`,
    # not `zimmer_data`) and is named for the cwd the runtime was spawned from, so
    # once this directory is gone nothing left on the box can derive that name
    # (zimmer#434). It has to go here, in the same breath as the clone, or it
    # never goes at all.
    #
    # After the removal, not before: if the removal is refused above we must not
    # have deleted the transcript of a session that still owns its clone.
    TranscriptDirectoryReaper.reap_for_clone(path) if outcome == :removed

    outcome
  end

  # The still-protected session that owns `path`, re-read from the database right
  # now — live, or being unarchived (see `Session.reap_protected`).
  #
  # Matched on the expanded path OR the basename, mirroring
  # StaleCloneCleanupJob's basename guard: clone directory names carry a
  # timestamp and a random suffix, so a basename is a globally unique handle on a
  # clone and survives a stored `clone_path` that cannot be reconciled with the
  # path being swept (a symlinked or relocated clones base).
  #
  # `unscoped` deliberately: this query decides deletions, so a default scope
  # added later for soft-delete or tenancy must not be able to hide a protected
  # row from it.
  #
  # @return [Hash, nil] `{id:, status:, unarchiving:}` for the owner, `{id: nil}`
  #   when the question could not be answered, nil when nothing protected owns it
  def live_owner(path)
    expanded = File.expand_path(path.to_s)
    basename = File.basename(expanded)

    owner = Session.unscoped
      .reap_protected
      .where("metadata->>'clone_path' IS NOT NULL")
      .pluck(:id, :status,
             Arel.sql("metadata->>'clone_path'"),
             Arel.sql("metadata->>'#{Session::UNARCHIVE_IN_FLIGHT_KEY}'"))
      .find do |(_id, _status, owned_path, _unarchiving)|
        owned_path.present? &&
          (File.expand_path(owned_path) == expanded || File.basename(owned_path) == basename)
      end

    return nil if owner.nil?

    { id: owner[0], status: Session.status_label(owner[1]), unarchiving: owner[3].present? }
  rescue ActiveRecord::ActiveRecordError, SystemCallError, ArgumentError => e
    # Fail closed. ArgumentError is in the list because File.expand_path raises it
    # for an unresolvable `~user` prefix, and a path we cannot even canonicalize
    # is not one to delete on the strength of an ownership query we never ran.
    Rails.logger.error "[CloneReaper] Could not establish who owns #{path} (#{e.class}: #{e.message}); " \
      "refusing to delete it"
    { id: nil, status: nil, unarchiving: false }
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

    Rails.logger.error "[CloneReaper] Refused to delete #{path} (#{reason}): session #{owner[:id]} " \
      "#{owner_description(owner)} and still owns it. The reaper's view of that session was stale, " \
      "so the clone was left in place (zimmer#808)."

    record_refusal(owner, path, reason)
  end

  # Why the owner is protected, in the words the reader needs: "archived" alone
  # would read as a contradiction on the unarchive path.
  def owner_description(owner)
    return "is being unarchived right now (status #{owner[:status]})" if owner[:unarchiving]

    "is #{owner[:status]}"
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
        "(#{File.basename(path.to_s)}) while the session #{owner_description(owner)}. It was refused and " \
        "the clone was left in place."
    )
  rescue StandardError => e
    Rails.logger.error "[CloneReaper] Failed to record the refusal for session #{owner[:id]}: " \
      "#{e.class} - #{e.message}"
  end

  # Only `.reap` is a door. The rest are its internals, and saying so structurally
  # is what keeps "the one door" a fact rather than an aspiration.
  private_class_method :refuse, :record_refusal, :owner_description
end
