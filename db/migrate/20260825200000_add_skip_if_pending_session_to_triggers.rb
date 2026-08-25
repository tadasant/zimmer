# frozen_string_literal: true

# `skip_if_pending_session` — the trigger setting that stops a trigger stacking
# up sessions that all carry the same intent.
#
# Three halves, all idempotent:
#
#   1. The column. Default false, so every existing trigger keeps behaving
#      exactly as it did: this is opt-in, not a policy change applied to the
#      fleet behind the operator's back.
#   2. An expression index on `metadata->>'trigger_id'`, which is how a session
#      records the trigger that spawned it. The new gate reads it on every fire,
#      and the trigger page has always scanned it unindexed.
#   3. Turn the setting ON for the `quota_available` wake trigger, which is the
#      one this exists for. That trigger fires on every pool recovery, and the
#      session it spawns is itself parked by the exhaustion it exists to answer —
#      so recovery after recovery it stacked up siblings with an identical prompt
#      (102 sessions, ten of them in a row in one afternoon). Matched on the
#      condition rather than the trigger name so a renamed row is still found.
#
# Raw SQL rather than the models, so this keeps meaning the same thing if Trigger
# or Session change shape later.
class AddSkipIfPendingSessionToTriggers < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    unless column_exists?(:triggers, :skip_if_pending_session)
      add_column :triggers, :skip_if_pending_session, :boolean, default: false, null: false
    end

    add_index :sessions,
      "((metadata ->> 'trigger_id'::text))",
      name: "index_sessions_on_trigger_id",
      where: "((metadata ->> 'trigger_id'::text) IS NOT NULL)",
      algorithm: :concurrently,
      if_not_exists: true

    execute(<<~SQL.squish)
      UPDATE triggers SET skip_if_pending_session = true, updated_at = NOW()
      WHERE skip_if_pending_session = false
        AND id IN (
          SELECT trigger_id FROM trigger_conditions
          WHERE condition_type = 'system_event'
            AND configuration @> '{"event_name":"quota_available"}'::jsonb
        )
    SQL
  end

  def down
    remove_index :sessions, name: "index_sessions_on_trigger_id", algorithm: :concurrently, if_exists: true
    remove_column :triggers, :skip_if_pending_session, if_exists: true
  end
end
