# frozen_string_literal: true

# Where a *re-clone* for an existing session should land.
#
# The whole point: keep the working directory stable for the life of a
# conversation
# ----------------------------------------------------------------------------
# Claude Code names its transcript directory after the cwd it was spawned from
# (`~/.claude/projects/<PathSanitizer.sanitize(working_directory)>`, see
# ClaudeTranscriptSource). Zimmer resumes a conversation by re-materializing the
# stored transcript at `<transcript_directory>/<session_id>.jsonl` and handing
# the runtime `--resume`. So the cwd a session is resumed in *is* the identity of
# its transcript directory.
#
# Clone directory names carry a timestamp and a random suffix
# (`{repo}-{branch}-{timestamp}-{random}`, GitCloneService#generate_clone_path),
# so every re-clone used to land somewhere new — and the whole JSONL was written
# out again under a new slug while the previous copy stayed behind at full size.
# One production conversation was measured in 23 clone directories, 18 MB each
# (zimmer#576). Reusing the path the session already occupied collapses that to
# one directory for the conversation's whole life.
#
# Why a re-clone happens at all, and why reusing the path is safe
# ---------------------------------------------------------------
# There is exactly one reason a session gets a fresh clone mid-conversation: the
# directory it was using is **gone from disk** — reaped by StaleCloneCleanupJob /
# EmptyTrashJob / DeferredCloneCleanupJob through CloneReaper, or emptied out of
# the trash while the session was archived. Nothing re-clones because a tree is
# dirty or a branch moved: AgentSessionJob reuses a clone that still exists
# exactly as it finds it, dirty tree and all, and UnarchiveSessionService takes
# its quick path whenever the clone and working directory are both still there.
#
# That is what makes the path free to reuse. There is no tree at it to inherit —
# no uncommitted work, no moved branch, no stale checkout — because the reason we
# are here is that there is no tree at all. `git clone` needs an absent or empty
# destination, and #for_recreate hands back a path only when it is absent.
#
# A session whose branch moved re-clones from `session.branch` exactly as before;
# only the *name* of the directory still spells the branch it was first cut for,
# which is cosmetic. A session whose agent-root subdirectory moved in the catalog
# (#921) still adopts the new subdirectory, so its cwd — and therefore its
# transcript directory — legitimately moves with it.
module SessionClonePath
  module_function

  # The path a re-clone for this session should land at.
  #
  # @param session [Session] the session whose clone is being recreated
  # @param file_system [FileSystemAdapter] adapter for the existence check
  # @return [String, nil] the previous clone path when it is free to reuse, or
  #   nil to let GitCloneService generate a fresh one
  def for_recreate(session, file_system: RealFileSystemAdapter.new)
    previous = session&.metadata&.dig("clone_path")
    return nil unless previous.is_a?(String) && previous.present?
    return nil unless direct_child_of_clones_base?(previous)

    # `git clone` refuses a non-empty destination, and create_clone's rollback
    # would then delete whatever is standing there. Only ever hand back a path
    # with nothing at it — which is also the only case a re-clone is reached
    # through.
    return nil if file_system.exists?(previous)

    # Verbatim, not expanded: the existing transcript directory was named by
    # sanitizing this exact string, so reusing it byte-for-byte is what makes the
    # slug come out the same.
    previous
  rescue StandardError => e
    Rails.logger.warn "[SessionClonePath] Could not reuse the previous clone path for " \
      "session #{session&.id}: #{e.class} - #{e.message}"
    nil
  end

  # A clone is always a direct child of the clones base
  # (GitCloneService#generate_clone_path). Anything else on a session's
  # `clone_path` is a row this module has no business steering a `git clone` at —
  # a relative path, a relocated clones base it cannot reconcile, a leftover from
  # a different AGENT_CLONES_DIR.
  def direct_child_of_clones_base?(path)
    File.dirname(File.expand_path(path)) == File.expand_path(ClonesDirectory.base)
  rescue ArgumentError
    false
  end
end
