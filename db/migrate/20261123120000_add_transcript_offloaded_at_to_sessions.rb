# frozen_string_literal: true

# Marks a session whose transcript has been moved out of `session_transcript_chunks`
# into TranscriptOffloadStore by TranscriptRetentionJob. The row keeps
# `transcript_byte_size`, `transcript_line_count` and `transcript_digest`, so every
# reader that asks "how big is it" or "is it unchanged" still answers from the row;
# this column is what tells `Session#transcript` to read the bytes from the store
# instead of from the chunk table.
#
# The partial index is the retention job's candidate scan: archived sessions that
# still hold chunks, oldest archive first. It shrinks as the job drains the backlog
# rather than growing with the corpus. The second counts what has been offloaded,
# for database_size_health, without a scan of `sessions`.
class AddTranscriptOffloadedAtToSessions < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :sessions, :transcript_offloaded_at, :datetime

    add_index :sessions, [ :archived_at, :id ],
      name: "index_sessions_on_transcript_offload_candidates",
      where: "transcript_offloaded_at IS NULL AND transcript_byte_size > 0 AND archived_at IS NOT NULL",
      algorithm: :concurrently

    add_index :sessions, :id,
      name: "index_sessions_on_id_where_transcript_offloaded",
      where: "transcript_offloaded_at IS NOT NULL",
      algorithm: :concurrently
  end
end
