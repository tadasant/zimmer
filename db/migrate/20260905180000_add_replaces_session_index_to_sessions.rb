# frozen_string_literal: true

# Index the replacement edge so "who replaced this session?" is an indexed
# lookup rather than a scan (https://github.com/tadasant/zimmer/issues/801).
#
# `custom_metadata["replaces_session"]` is written by whoever spawns a
# replacement, on the replacement itself. `Session#claim_system_recovery_turn!`
# now asks the opposite question — given a session an automated sweep wants to
# resume, is there a session that replaced it — once per recovery claim. Partial,
# because the key is absent on all but a handful of rows, and expression-shaped so
# it matches `Session.replacing_session`'s predicate exactly.
#
# `index_sessions_on_router_session_id` is the same shape over the same column.
class AddReplacesSessionIndexToSessions < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_index :sessions,
      "(custom_metadata->>'replaces_session')",
      name: "index_sessions_on_replaces_session",
      where: "(custom_metadata->>'replaces_session') IS NOT NULL",
      algorithm: :concurrently
  end
end
