# Where a session came from — its *genesis* — as a first-class column.
#
# Genesis is the classification axis for spot vs priority scheduling. It lives in
# a column rather than in `metadata` for two reasons:
#
#   1. `sessions.metadata` is `json`, not `jsonb`, so it cannot be indexed for the
#      list-view filter this feature adds.
#   2. Several restart/recovery paths clear named metadata key sets
#      (SIGTERM_RETRY_METADATA_KEYS, STALE_RETRY_METADATA_KEYS,
#      SETUP_ARTIFACT_KEYS). A session's origin must survive a restart — it does
#      not change just because the process died.
#
# Existing rows are backfilled from the evidence that was already being recorded:
# `metadata->>'source'` for the two web paths that set it, the trigger's condition
# types for trigger-born sessions, and the lineage edge for everything spawned by
# another session. Rows no rule matches land on "unknown", which classifies as
# priority — an unclassifiable session is never throttled.
class AddGenesisToSessions < ActiveRecord::Migration[8.0]
  def up
    add_column :sessions, :genesis, :string
    add_index :sessions, :genesis

    backfill_from_metadata_source
    backfill_from_triggers
    backfill_from_lineage
    backfill_remainder
  end

  def down
    remove_column :sessions, :genesis
  end

  private

  # The dashboard quick prompt and the chat bubble are the two paths that have
  # always stamped `metadata["source"]`. Both are a human typing into the web app.
  def backfill_from_metadata_source
    execute <<~SQL.squish
      UPDATE sessions
      SET genesis = 'web_ui'
      WHERE genesis IS NULL
        AND metadata::jsonb->>'source' IN ('quick_prompt', 'chat_bubble')
    SQL
  end

  # Trigger-born sessions recorded `metadata["trigger_id"]` but never which
  # condition type fired. Recover it by joining back through the trigger's
  # conditions. A trigger with several condition types is resolved by the
  # priority order below — the human-facing ones win, so a mixed trigger is
  # never silently demoted to spot.
  def backfill_from_triggers
    # Ordered most-human-facing first, and each pass only fills rows still NULL, so
    # a trigger carrying several condition types keeps the highest-precedence one.
    SessionGenesis::CONDITION_TYPE_PRECEDENCE.each do |condition_type|
      genesis = SessionGenesis::CONDITION_TYPE_KINDS.fetch(condition_type)

      execute <<~SQL.squish
        UPDATE sessions
        SET genesis = #{connection.quote(genesis)}
        WHERE sessions.genesis IS NULL
          AND (metadata::jsonb->>'trigger_id') ~ '^[0-9]+$'
          AND EXISTS (
            SELECT 1 FROM trigger_conditions tc
            WHERE tc.trigger_id = (metadata::jsonb->>'trigger_id')::bigint
              AND tc.condition_type = #{connection.quote(condition_type)}
          )
      SQL
    end
  end

  # A spawned session inherits its parent's genesis. Iterate so a chain of
  # spawns resolves from the root down; MAX_DEPTH in SessionHierarchy is 8, so
  # ten passes covers every reachable lineage with room to spare.
  def backfill_from_lineage
    10.times do
      updated = execute(<<~SQL.squish).cmd_tuples
        UPDATE sessions AS child
        SET genesis = parent.genesis
        FROM sessions AS parent
        WHERE child.genesis IS NULL
          AND parent.genesis IS NOT NULL
          AND (
            child.parent_session_id = parent.id
            OR (child.metadata::jsonb->>'forked_from_session_id') ~ '^[0-9]+$'
               AND (child.metadata::jsonb->>'forked_from_session_id')::bigint = parent.id
          )
      SQL

      break if updated.to_i.zero?
    end
  end

  # Everything left is genuinely unclassifiable from the record: the new-session
  # form and the REST API never stamped anything, and their rows are now
  # indistinguishable. "unknown" classifies as priority, so the backfill's
  # failure mode is "runs anyway", not "silently throttled".
  def backfill_remainder
    execute <<~SQL.squish
      UPDATE sessions SET genesis = 'unknown' WHERE genesis IS NULL
    SQL
  end
end
