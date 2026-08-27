# frozen_string_literal: true

# `idempotency_key` — the client-supplied token that makes "create a session" a
# safe thing to retry.
#
# A create whose response is lost (the reverse proxy gives up and returns its own
# 504 page after the row has already committed) is indistinguishable, to the
# caller, from a create that never landed. Retrying is the obvious move and it
# produces a second session for the same unit of work — a second clone, a second
# agent holding a quota slot, two PRs for one task. The key is what lets the
# server recognise the retry and hand back the session it already made.
#
# The uniqueness is enforced in the database, not only in the model: the two
# racing requests here are two HTTP requests, potentially on two Puma workers, so
# a Ruby-side `exists?` check cannot see the row the other one is mid-INSERT on.
# The partial index (WHERE NOT NULL) keeps the overwhelming majority of sessions
# — everything created before this, and every caller that passes no key — out of
# the index entirely, and lets any number of them coexist with a NULL key.
class AddIdempotencyKeyToSessions < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    unless column_exists?(:sessions, :idempotency_key)
      add_column :sessions, :idempotency_key, :string
    end

    # A concurrent build that fails (lock timeout, deadlock) leaves the index
    # behind marked INVALID — present enough for `if_not_exists` to skip, and
    # useless as a uniqueness constraint. That is worse than no index here: the
    # whole point is that the database refuses the duplicate. Drop an invalid one
    # so a rerun rebuilds it; a valid one is left untouched.
    drop_invalid_index!("index_sessions_on_idempotency_key")

    add_index :sessions, :idempotency_key,
      name: "index_sessions_on_idempotency_key",
      unique: true,
      where: "idempotency_key IS NOT NULL",
      algorithm: :concurrently,
      if_not_exists: true
  end

  def down
    remove_index :sessions, name: "index_sessions_on_idempotency_key", algorithm: :concurrently, if_exists: true
    remove_column :sessions, :idempotency_key, if_exists: true
  end

  private

  def drop_invalid_index!(name)
    invalid = select_value(<<~SQL.squish)
      SELECT 1 FROM pg_class c
      JOIN pg_index i ON i.indexrelid = c.oid
      WHERE c.relname = #{quote(name)} AND NOT i.indisvalid
      LIMIT 1
    SQL
    return if invalid.blank?

    say "Dropping INVALID index #{name} left by a failed concurrent build"
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{quote_table_name(name)}")
  end
end
