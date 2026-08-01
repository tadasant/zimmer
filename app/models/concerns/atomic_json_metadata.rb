# Atomic, single-statement merges into a session's JSON metadata columns.
#
# The shape these replace — `session.update!(metadata: (session.metadata || {}).merge(...))` —
# rewrites the WHOLE column from a snapshot the caller read earlier. Any key another
# writer set in between is silently erased. `session.reload` before the merge narrows
# the window; it does not close it. For the keys the system steers on, a lost key is a
# correctness bug, not a cosmetic one:
#
#   - `interrupt_terminate_pid` — lose it and a "Send now" terminates nothing.
#   - `pending_follow_up_prompt` — lose it and a user's follow-up never reaches the agent.
#   - `github_pull_request_urls` — lose it and none of the GitHub integration engages.
#
# These helpers push the merge into PostgreSQL (`jsonb - text[]`, then `||`) so the read
# and the write are one statement, and keys this caller never named survive.
#
# **What this does not do**, stated plainly so call sites aren't written against a
# guarantee that isn't here:
#
#   - It does not serialize two writers of the SAME key. Last writer still wins.
#   - It does not protect a key from a caller that still does a whole-column
#     read-modify-write. Atomicity is a property of every writer to the row, not of one
#     key: protecting `interrupt_terminate_pid` means converting the writers that race
#     with it, not just the writer that sets it.
#
# The merge is shallow, matching `Hash#merge` — a nested hash passed here replaces the
# stored one rather than being deep-merged.
#
# Two deliberate differences from `update!`:
#
#   - Model validations do not run. That is what makes these usable on the terminal
#     paths where a stale-catalog validation error would otherwise block a session from
#     recording why it failed.
#   - `after_update_commit` broadcast callbacks do not fire on their own, so this
#     concern re-dispatches the same two broadcasts explicitly, after commit.
#
# One thing a caller must know: unsaved changes to the column being merged are
# DISCARDED. The row is rewritten from what PostgreSQL holds, and the in-memory
# attribute is then overwritten with the result. Pass every change you want kept in
# `updates` — do not assign the column and then merge.
module AtomicJsonMetadata
  extend ActiveSupport::Concern

  # JSON columns this concern is allowed to touch. Interpolated into SQL, so the
  # allowlist is load-bearing, not documentation.
  MERGEABLE_JSON_COLUMNS = %w[metadata custom_metadata].freeze

  # Merge `updates` into `metadata`, dropping `remove` keys, in one UPDATE.
  #
  # `remove` is positional, not a keyword: a method with any keyword parameter makes
  # Ruby read `merge_metadata!("k" => v)` as keywords, which would turn the most common
  # call shape in the codebase into an ArgumentError.
  #
  # @param updates [Hash] keys to set (shallow merge, last writer wins per key)
  # @param remove [Array<String>] keys to drop; removal happens before the merge
  # @return [Hash] the merged column value as the database now holds it
  def merge_metadata!(updates = {}, remove = [])
    atomic_json_merge!(:metadata, updates, remove)
  end

  # Merge `updates` into `custom_metadata`, dropping `remove` keys, in one UPDATE.
  # @see #merge_metadata!
  def merge_custom_metadata!(updates = {}, remove = [])
    atomic_json_merge!(:custom_metadata, updates, remove)
  end

  # Drop keys from `metadata` in one UPDATE, leaving every other key alone.
  # Accepts a splat or an array: `remove_metadata!("a", "b")` or `remove_metadata!(KEYS)`.
  def remove_metadata!(*keys)
    atomic_json_merge!(:metadata, {}, keys.flatten)
  end

  # Drop keys from `custom_metadata` in one UPDATE.
  # @see #remove_metadata!
  def remove_custom_metadata!(*keys)
    atomic_json_merge!(:custom_metadata, {}, keys.flatten)
  end

  private

  def atomic_json_merge!(column, updates, remove)
    name = column.to_s
    raise ArgumentError, "#{name} is not a mergeable JSON column" unless MERGEABLE_JSON_COLUMNS.include?(name)

    updates = (updates || {}).stringify_keys
    remove = Array(remove).map(&:to_s).uniq
    return public_send(column) || {} if updates.empty? && remove.empty?

    # The broadcast baseline is the value as the DATABASE handed it over, not the
    # attribute reader. They are not the same thing: a caller that mutates the stored
    # hash in place before merging — McpStatusPersisting does exactly this, editing
    # `custom_metadata["mcp_servers_status"]` and then passing it back — has already
    # changed what the reader returns, so comparing against it reports "nothing
    # changed" and swallows the broadcast. `attribute_in_database` re-deserializes the
    # value this object was loaded with, which in-place mutation cannot reach.
    before = attribute_in_database(name) || {}

    touched_at = Time.current
    merged = execute_json_merge(name, updates, remove, touched_at)

    write_attribute(column, merged)
    self.updated_at = touched_at
    send(:clear_attribute_change, name)
    send(:clear_attribute_change, "updated_at")

    broadcast_json_merge(column, before, merged)
    merged
  end

  def execute_json_merge(name, updates, remove, touched_at)
    # `metadata` is a `json` column and `custom_metadata` is `jsonb`; neither `-` nor
    # `||` exists for `json`, so the expression works in jsonb and casts back to
    # whichever type the column actually is.
    column_type = self.class.columns_hash[name].sql_type
    # One placeholder per removed key. `ARRAY[]::text[]` is the valid empty case, so no
    # branch is needed — and every key is a bind, not an interpolated SQL fragment.
    removals = remove.map { "?" }.join(", ")

    sql = self.class.sanitize_sql_array([
      <<~SQL.squish,
        UPDATE #{self.class.quoted_table_name}
        SET #{name} = ((COALESCE(#{name}, '{}')::jsonb - ARRAY[#{removals}]::text[]) || ?::jsonb)::#{column_type},
            updated_at = ?
        WHERE id = ?
        RETURNING #{name}
      SQL
      *remove, updates.to_json, touched_at, id
    ])

    row = self.class.with_connection { |connection| connection.exec_query(sql, "#{self.class.name} Atomic JSON Merge") }.first
    raise ActiveRecord::RecordNotFound, "#{self.class.name} id=#{id} no longer exists" if row.nil?

    value = row[name]
    value.is_a?(String) ? JSON.parse(value) : (value || {})
  end

  # A raw UPDATE fires no `after_update_commit`, so re-dispatch every broadcast Session
  # hangs off a JSON-column change. There are three, and missing one is invisible until a
  # card silently stops updating in someone's browser:
  #
  #   1. the session card on the index — `should_broadcast_to_index?` treats ANY
  #      `metadata` / `custom_metadata` change as broadcast-worthy;
  #   2. the metadata partial on the detail page — only when a displayed field changed;
  #   3. the header actions on the detail page (the GitHub PR link) — any
  #      `custom_metadata` change.
  #
  # The before/after pair is passed explicitly because `saved_change_to_*` knows nothing
  # about a write that did not go through the model.
  #
  # If a future `after_update_commit` keys on either column, it belongs here too.
  def broadcast_json_merge(column, before, after)
    return if before == after

    metadata_column = column == :metadata
    display_changed = metadata_column && metadata_display_fields_changed?(before, after)
    mcp_status_changed = !metadata_column &&
      before&.dig("mcp_servers_status") != after&.dig("mcp_servers_status")

    ActiveRecord.after_all_transactions_commit do
      broadcast_update_to_sessions_index
      if metadata_column
        broadcast_metadata_change if display_changed
      else
        broadcast_custom_metadata_change(mcp_status_changed: mcp_status_changed)
      end
    end
  end
end
