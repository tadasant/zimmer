# frozen_string_literal: true

# Make every foreign key into `sessions` declare what happens when the session row
# goes away.
#
# Six child tables — elicitations, enqueued_messages, logs, mcp_oauth_pending_flows,
# notifications, subagent_transcripts — referenced sessions with no ON DELETE rule,
# so the "children go away with their session" invariant lived only in ActiveRecord's
# `dependent: :destroy`. Anything that deletes a session row without running those
# callbacks (`Session.delete_all`, `session.delete`, a raw `DELETE FROM sessions`)
# hit PG::ForeignKeyViolation instead. ON DELETE CASCADE encodes the same intent one
# layer down, where it holds for every writer.
#
# sessions.parent_session_id carried no foreign key at all, so a row-level delete of
# a parent left its children pointing at a session that no longer exists. Its two
# siblings — sessions.blocked_by_session_id and sessions.category_id — already pair
# ON DELETE SET NULL with `dependent: :nullify`; parent_session_id now matches.
#
# Postgres cannot ALTER an existing constraint's ON DELETE action, so each key is
# dropped and re-added. Adding it in one shot would rescan the whole child table
# while holding SHARE ROW EXCLUSIVE on both it and `sessions` — that blocks writes to
# `logs`, which every running agent appends to. Instead each key is added NOT VALID
# (instant, no scan) and validated in a second statement, which takes only SHARE
# UPDATE EXCLUSIVE and lets writes through. That requires running outside a
# transaction.
#
# NOT reversible in full: `up` nulls out any parent_session_id that already points at
# a missing session, because such a pointer cannot be honored by the constraint.
# `down` restores the constraints, not those values.
class EnforceOnDeleteRulesForSessionForeignKeys < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  # Tables whose rows are meaningless without their session (Session declares
  # `dependent: :destroy` for each): the database deletes them along with it.
  CASCADING_TABLES = %i[
    elicitations
    enqueued_messages
    logs
    mcp_oauth_pending_flows
    notifications
    subagent_transcripts
  ].freeze

  def up
    CASCADING_TABLES.each do |table|
      replace_session_foreign_key(table, on_delete: :cascade)
    end

    orphaned = execute(<<~SQL.squish).cmd_tuples
      UPDATE sessions AS child
      SET parent_session_id = NULL
      WHERE child.parent_session_id IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM sessions AS parent WHERE parent.id = child.parent_session_id
        )
    SQL
    say "nulled #{orphaned} dangling parent_session_id pointer(s)"

    unless foreign_key_exists?(:sessions, :sessions, column: :parent_session_id)
      add_foreign_key :sessions, :sessions, column: :parent_session_id, on_delete: :nullify, validate: false
      validate_foreign_key :sessions, column: :parent_session_id
    end
  end

  def down
    remove_foreign_key :sessions, column: :parent_session_id if foreign_key_exists?(:sessions, :sessions, column: :parent_session_id)

    CASCADING_TABLES.each do |table|
      replace_session_foreign_key(table, on_delete: nil)
    end
  end

  private

  # Each step is guarded so a re-run after a partial failure picks up where it left
  # off — without a wrapping transaction there is nothing to roll the earlier tables
  # back.
  def replace_session_foreign_key(table, on_delete:)
    remove_foreign_key table, :sessions if foreign_key_exists?(table, :sessions)
    add_foreign_key table, :sessions, on_delete: on_delete, validate: false
    validate_foreign_key table, :sessions
  end
end
