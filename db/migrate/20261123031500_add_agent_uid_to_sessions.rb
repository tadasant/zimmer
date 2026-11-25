# frozen_string_literal: true

# The unix uid a session's agent processes run as when per-session uids are on
# (ZIMMER_SESSION_UID=1, see SessionUid). NULL means the session has never been
# spawned under a uid of its own, which is every session while the flag is off.
#
# Unique among non-NULL values so two live sessions can never be handed the same
# uid — the uid is the whole boundary, and a shared one is no boundary at all.
# EmptyTrashJob clears it once the session's files are gone, which is what makes a
# uid safe to hand out again.
#
# Outside a transaction so the index builds concurrently: `sessions` takes a write
# on every heartbeat, and the old containers keep serving while this runs. Each step
# is guarded so a run interrupted halfway can be re-run.
class AddAgentUidToSessions < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_column :sessions, :agent_uid, :integer unless column_exists?(:sessions, :agent_uid)

    return if index_exists?(:sessions, :agent_uid, name: "index_sessions_on_agent_uid")

    add_index :sessions, :agent_uid,
      unique: true,
      where: "agent_uid IS NOT NULL",
      algorithm: :concurrently,
      name: "index_sessions_on_agent_uid"
  end

  def down
    remove_index :sessions, name: "index_sessions_on_agent_uid", algorithm: :concurrently, if_exists: true
    remove_column :sessions, :agent_uid, if_exists: true
  end
end
