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
class EnforceOnDeleteRulesForSessionForeignKeys < ActiveRecord::Migration[8.0]
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
      remove_foreign_key table, :sessions
      add_foreign_key table, :sessions, on_delete: :cascade
    end

    # A parent_session_id pointing at a missing session is already a dead reference.
    # Null those out so the constraint can be added, then let the database keep the
    # column honest from here on.
    execute(<<~SQL.squish)
      UPDATE sessions AS child
      SET parent_session_id = NULL
      WHERE child.parent_session_id IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM sessions AS parent WHERE parent.id = child.parent_session_id
        )
    SQL

    add_foreign_key :sessions, :sessions, column: :parent_session_id, on_delete: :nullify
  end

  def down
    remove_foreign_key :sessions, column: :parent_session_id

    CASCADING_TABLES.each do |table|
      remove_foreign_key table, :sessions
      add_foreign_key table, :sessions
    end
  end
end
