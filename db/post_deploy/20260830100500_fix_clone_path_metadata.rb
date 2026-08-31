# frozen_string_literal: true

# Repairs sessions whose `metadata["clone_path"]` is a Hash instead of a String.
#
# An old bug in the clone path writer stored the whole result hash under the
# `clone_path` key instead of the path it contains, so those sessions carry
# `{"clone_path" => "/…", "working_directory" => "/…"}` where every reader
# expects a string. The fix landed long ago; the rows it wrote did not.
#
# THE POINT OF THIS FILE: the repair used to be `rake data:fix_clone_path_metadata`
# — an operational step that could only be taken from a shell on the production
# box, which is a shell this deployment deliberately does not offer. So it never
# ran there. As a post-deploy task it ships with the deploy and runs itself, and
# whether it ran is a row in `post_deploy_task_runs` rather than somebody's
# recollection.
#
# Idempotent: the predicate matches only the broken shape, so a repaired row
# drops out of the relation and a second run finds nothing. Sliced, because the
# sessions table is large and the count of broken rows in production is not known
# ahead of time — an unsliced version that turned out to match a lot of rows
# would hold a worker thread for as long as it took.
class FixClonePathMetadata < PostDeployTask
  # `metadata` is `json`, not `jsonb`, so this is `json_typeof`. A NULL metadata
  # or a missing key yields NULL, which is not 'object', so both are skipped.
  #
  # Unindexed, deliberately: an index built for a repair that runs once is a
  # bigger thing to leave behind than the scan it saves. `sweep` only checks the
  # budget between batches, so the last query — the one that proves nothing is
  # left — is a scan of `sessions`. That is seconds on a table of this size, and
  # it happens once per environment, ever.
  BROKEN = "json_typeof(metadata->'clone_path') = 'object'"

  def up
    checkpoint!(repaired: stats.fetch("repaired", 0))

    sweep(Session.where(BROKEN), batch_size: 200) do |batch|
      checkpoint!(repaired: stats.fetch("repaired", 0) + batch.count { |session| repair(session) })
    end
  end

  private

  # `update_column`, not `update!`, for two reasons.
  #
  # Validations: `validates :agent_runtime, inclusion:` reads the LIVE
  # RuntimeRegistry, and the catalog validations read the live catalog. A session
  # old enough to carry the broken shape is exactly the one most likely to name a
  # runtime or a skill that has since been retired — and failing the whole repair
  # on one of those would be absurd.
  #
  # Callbacks: Session broadcasts on `after_update_commit`. A bulk repair has no
  # business pushing a Turbo update per row for sessions nobody is looking at.
  def repair(session)
    nested = session.metadata["clone_path"]
    # Belt and braces. The predicate that selected this row already guarantees
    # the value is a JSON object, so this cannot fire from the sweep above — it
    # is here so the method is safe to call on a row from anywhere else.
    return false unless nested.is_a?(Hash)

    metadata = session.metadata.dup
    path = nested["clone_path"] || nested[:clone_path]
    working_directory = nested["working_directory"] || nested[:working_directory]

    # Deleted rather than set to nil when the nested hash held no path: the
    # readers all treat a missing key and a nil the same way, and a key that is
    # present-but-nil is one more shape for the next reader to handle.
    if path.present?
      metadata["clone_path"] = path
    else
      metadata.delete("clone_path")
    end

    # Only filled in when it is missing. A `working_directory` written correctly
    # since the bug is the better value, and this repair has no business
    # overwriting it with what the stale nested hash happened to carry.
    metadata["working_directory"] = working_directory if working_directory.present? && metadata["working_directory"].blank?

    session.update_column(:metadata, metadata)
    logger.info("[FixClonePathMetadata] session #{session.id}: clone_path #{path.inspect}")
    true
  end
end
