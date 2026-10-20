# A one-off memory boost for ONE session (SessionMemoryBoost): a larger per-session
# `memory.max`, carved out of the sessions pool rather than added on top of it, until
# `memory_boost_expires_at` or the session is archived, whichever is first.
#
# The partial index serves SessionMemoryBoost.reconcile!, which asks "which sessions
# hold a boost" once a minute on every worker; the answer is almost always none.
class AddMemoryBoostToSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :sessions, :memory_boost_mb, :integer
    add_column :sessions, :memory_boost_expires_at, :datetime
    add_index :sessions, :memory_boost_expires_at, where: "memory_boost_mb IS NOT NULL",
                                                   name: "index_sessions_on_memory_boost"
  end
end
