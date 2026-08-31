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
  BROKEN = "json_typeof(metadata->'clone_path') = 'object'"

  def up
    checkpoint!(repaired: stats.fetch("repaired", 0), skipped: stats.fetch("skipped", 0))

    sweep(Session.where(BROKEN), batch_size: 200) do |batch|
      repaired = batch.count { |session| repair(session) }

      checkpoint!(
        repaired: stats.fetch("repaired", 0) + repaired,
        skipped: stats.fetch("skipped", 0) + (batch.size - repaired)
      )
    end
  end

  private

  # `update_column`, not `update!`: this is a data repair on rows that may be
  # years old, and Session validates `agent_root` and `catalog_skills` against
  # the artifact catalog. A session whose agent root has since been retired is
  # still a session whose metadata needs fixing, and failing the whole task on
  # one of those would be absurd.
  def repair(session)
    nested = session.metadata["clone_path"]
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
